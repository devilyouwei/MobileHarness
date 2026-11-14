import Foundation
import FunctionContracts
import ModelKit
import ModelKitDefaults
import ModelKitOpenAI
import StorageCore
import UI

@MainActor
public enum SettingsProviderAdapter {
    nonisolated public static func discoverModels(_ configuration: ProviderDiscoveryConfiguration) async throws
        -> [String]
    {
        do {
            return try await OpenAIChatConfiguration.models(
                baseURL: OpenAIChatConfiguration.endpoint(configuration.url), apiKey: configuration.key)
        } catch is CancellationError { throw CancellationError() } catch OpenAIChatError.httpStatus(let status) {
            throw ProviderDiscoveryError.httpStatus(status)
        } catch is CapabilityError { throw ProviderDiscoveryError.invalidConfiguration } catch {
            throw ProviderDiscoveryError.unavailable
        }
    }
    public static var initial: CloudSettingsDraft {
        .init(
            enabled: false, url: OpenAIChatConfiguration.defaultBaseURL, key: "",
            model: OpenAIChatConfiguration.defaultModel)
    }
    public static func runtime(
        language: any ModelLanguageProviding,
        beginChange: @escaping @MainActor () async -> Void, endChange: @escaping @MainActor () -> Void
    ) -> ProviderSettingsRuntime {
        let value = initial
        return ProviderSettingsRuntime(
            initial: .init(enabled: value.enabled, url: value.url, key: value.key, model: value.model),
            prepare: { value in
                let configuration: OpenAIChatConfiguration?
                do {
                    if let value, value.enabled {
                        configuration = try OpenAIChatConfiguration(
                            baseURL: OpenAIChatConfiguration.endpoint(value.url),
                            apiKey: value.key,
                            model: value.model.isEmpty ? OpenAIChatConfiguration.defaultModel : value.model,
                            thinking: .minimum)
                    } else {
                        configuration = nil
                    }
                } catch { throw ProviderSettingsError.invalidConfiguration }
                return {
                    do {
                        if #available(iOS 27, macOS 27, *) {
                            try await language.configure(configuration)
                        } else {
                            throw ProviderSettingsError.application
                        }
                    } catch is CancellationError { throw CancellationError() } catch {
                        throw ProviderSettingsError.application
                    }
                }
            }, beginChange: beginChange, endChange: endChange)
    }
    public static func operations(
        restore: @escaping @MainActor () async throws -> CloudSettingsDraft,
        discover: @escaping @MainActor (CloudSettingsDraft) async throws -> [String],
        save: @escaping @MainActor (CloudSettingsDraft) async throws -> Void
    ) -> SettingsProviderOperations {
        SettingsProviderOperations(
            initial: initial, restore: restore, discover: discover, save: save,
            errorMessage: errorMessage)
    }
    public static func errorMessage(_ error: any Error) -> String? {
        if let query = error as? any ProviderRequestFailure {
            switch query.failureCode {
            case "provider.configuration": return "Invalid configuration. Check the URL, API key, and selected model."
            case "provider.models": return "The service returned an invalid or oversized model list."
            case "provider.persistence": return "Could not read or save settings. Restart the app and try again."
            case "provider.rollback": return "Could not apply or restore settings. Restart the app and check them."
            case "provider.busy": return "Settings are busy. Try again."
            case "provider.selection", "provider.keychain":
                return "Could not save settings. Check the model and keychain access."
            case "provider.application": return "Could not apply model settings. Check settings and try again."
            case "provider.cancelled": return "Operation cancelled"
            case "provider.decisionRequired": return "Download D3 in Agent Brains before selecting the local model."
            case "provider.capacity": return "Too many model requests. Try again."
            case "provider.request", "provider.expired": return "The model lookup expired. Try again."
            default: break
            }
        }
        let status: Int
        if case OpenAIChatError.httpStatus(let value) = error {
            status = value
        } else if let query = error as? any ProviderRequestFailure,
            let code = query.failureCode, code.hasPrefix("provider.http."),
            let value = Int(code.dropFirst("provider.http.".count)), (100...599).contains(value)
        {
            status = value
        } else {
            return nil
        }
        return status == 401 || status == 403
            ? "The API key is invalid or lacks access."
            : "Check the service URL and try again."

    }
}

/// Session/revision-fenced native UI endpoint. Private credentials never enter call payloads.
@MainActor public final class ProviderPresentationAdapter: ProviderPresentationRegistering {
    public typealias Operation = ProviderPresentationOperation
    private struct Entry {
        let operation: Operation
        let revision: UInt64
    }
    private var entries: [String: Entry] = [:]
    private let state: any SettingsPresenting
    private let sessionID: String
    private let settings: ProviderSettingsRequests
    public init(
        state: any SettingsPresenting, sessionID: String, settings: ProviderSettingsRequests
    ) {
        self.state = state
        self.sessionID = sessionID
        self.settings = settings
    }
    public func register(_ id: String, operation: Operation) throws {
        guard entries.count < 32 else { throw ProviderDiscoveryError.capacityExceeded }
        entries[id] = Entry(operation: operation, revision: state.revision)
    }
    public func discard(_ id: String) { entries[id] = nil }
    public func present(_ id: String, failureCode: String?, invocation: any FunctionInput) async throws {
        try state.requirePresentation()
        guard invocation.context.sessionID == sessionID, let entry = entries[id] else {
            throw ResourcePresentationError.staleGeneration
        }
        // A replaced draft/page suppresses projection while the admitted native transaction still completes.
        guard entry.revision == state.revision else { return }
        if let failureCode {
            let message =
                SettingsProviderAdapter.errorMessage(ProviderPresentationFailure(failureCode: failureCode))
                ?? "Could not reach the service. Check the URL, API key, and network."
            _ = state.presentFailure(message, revision: entry.revision)
            return
        }
        switch entry.operation {
        case .restore:
            let value = try settings.result(id, sessionID: sessionID)
            try state.requirePresentation()
            _ = state.presentRestored(
                CloudSettingsDraft(
                    enabled: value.enabled, url: value.url, key: value.key,
                    model: value.model.isEmpty ? SettingsProviderAdapter.initial.model : value.model,
                    providers: value.providers.map {
                        .init(enabled: false, url: $0.url, key: $0.key, model: $0.model, name: $0.name, id: $0.id)
                    }, writerProviderID: value.writerProviderID, writerModel: value.writerModel,
                    writerThinking: value.writerThinking,
                    decisionProviderID: value.decisionProviderID, decisionModel: value.decisionModel,
                    decisionUsesLocal: value.decisionUsesLocal == true),
                revision: entry.revision)
        case .save:
            _ = try settings.result(id, sessionID: sessionID)
            try state.requirePresentation()
            _ = state.presentNotice("Model settings saved", revision: entry.revision)
        }
    }
}

private struct ProviderPresentationFailure: ProviderRequestFailure { let failureCode: String? }

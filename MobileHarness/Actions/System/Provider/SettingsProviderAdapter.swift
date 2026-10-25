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
                            model: value.model.isEmpty ? OpenAIChatConfiguration.defaultModel : value.model)
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
            case "provider.configuration": return "配置无效，请检查 HTTP/HTTPS URL、Key 和模型选择"
            case "provider.models": return "服务返回的模型列表无效或数量过多，请检查服务配置"
            case "provider.persistence": return "本地配置读取或保存失败，可能已被修改，请重新启动后重试"
            case "provider.rollback": return "配置应用和回滚失败，请重新启动后检查配置"
            case "provider.busy": return "配置正在读取或保存，请稍后重试"
            case "provider.selection", "provider.keychain": return "无法保存配置，请检查模型选择或设备钥匙串访问"
            case "provider.application": return "模型配置应用失败，请检查配置后重试"
            case "provider.cancelled": return "操作已取消"
            case "provider.capacity": return "模型查询请求过多，请稍后重试"
            case "provider.request", "provider.expired": return "模型查询请求已失效，请重新查询"
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
            ? "Key 无效或没有访问权限，请检查后重试"
            : "服务返回错误（\(status)），请检查 URL 后重试"

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
    private let discovery: ProviderDiscoveryRequests
    public init(
        state: any SettingsPresenting, sessionID: String, settings: ProviderSettingsRequests,
        discovery: ProviderDiscoveryRequests
    ) {
        self.state = state
        self.sessionID = sessionID
        self.settings = settings
        self.discovery = discovery
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
                ?? "无法连接服务，请检查 HTTP/HTTPS URL、Key 和网络后重试"
            _ = state.presentFailure(message, revision: entry.revision)
            return
        }
        switch entry.operation {
        case .discovery:
            let models = try await discovery.result(id, sessionID: sessionID)
            try state.requirePresentation()
            _ = state.presentModels(
                models,
                notice: models.isEmpty ? "此服务没有返回可识别的聊天模型" : "请选择用于对话的模型",
                revision: entry.revision)
        case .restore:
            let value = try settings.result(id, sessionID: sessionID)
            try state.requirePresentation()
            _ = state.presentRestored(
                CloudSettingsDraft(
                    enabled: value.enabled, url: value.url, key: value.key,
                    model: value.model.isEmpty ? SettingsProviderAdapter.initial.model : value.model,
                    providers: value.providers.map {
                        .init(enabled: false, url: $0.url, key: $0.key, model: $0.model, name: $0.name)
                    }),
                revision: entry.revision)
        case .save:
            let value = try settings.result(id, sessionID: sessionID)
            try state.requirePresentation()
            _ = state.presentNotice(value.enabled ? "已保存，云端模型立即生效" : "已切换为本地模型", revision: entry.revision)
        }
    }
}

private struct ProviderPresentationFailure: ProviderRequestFailure { let failureCode: String? }

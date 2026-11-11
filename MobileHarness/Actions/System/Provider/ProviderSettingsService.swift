import Foundation
import FunctionContracts
import StorageCore
import StorageFiles

public enum ProviderSettingsError: LocalizedError, Sendable, ActionExecutionFailureProviding {
    case invalidSelection, invalidConfiguration, persistence, busy, application, cancelled, decisionRequired
    case keychain(Int32)
    case rollback(primary: String, secondary: String)
    public var executionFailureCode: ActionExecutionFailureCode {
        let value: String
        switch self {
        case .invalidSelection: value = "provider.selection"
        case .invalidConfiguration: value = "provider.configuration"
        case .persistence: value = "provider.persistence"
        case .busy: value = "provider.busy"
        case .application: value = "provider.application"
        case .cancelled: value = "provider.cancelled"
        case .decisionRequired: value = "provider.decisionRequired"
        case .keychain: value = "provider.keychain"
        case .rollback: value = "provider.rollback"
        }
        return .init(rawValue: value)
    }
    public var errorDescription: String? {
        switch self {
        case .rollback(let primary, let secondary):
            return "\(executionFailureCode.rawValue): \(primary.prefix(64)); rollback: \(secondary.prefix(64))"
        case .keychain(let status): return "provider.keychain: \(status)"
        default: return executionFailureCode.rawValue
        }
    }
    static func safe(_ error: any Error) -> ProviderSettingsError {
        if let error = error as? ProviderSettingsError { return error }
        if error is CancellationError { return .cancelled }
        if error is DocumentStorageError || error is CocoaError || error is DecodingError { return .persistence }
        return .application
    }
}
public protocol ProviderSettingsPersistence: Sendable {
    func load() async throws -> ProviderSettings?
    func save(_ value: ProviderSettings?) async throws
}
@MainActor
public struct ProviderSettingsRuntime {
    public let initial: ProviderSettings
    public let prepare: (ProviderSettings?) throws -> @MainActor () async throws -> Void
    public let beginChange: @MainActor () async -> Void
    public let endChange: @MainActor () -> Void
    public init(
        initial: ProviderSettings,
        prepare: @escaping (ProviderSettings?) throws -> @MainActor () async throws -> Void,
        beginChange: @escaping @MainActor () async -> Void, endChange: @escaping @MainActor () -> Void
    ) {
        self.initial = initial
        self.prepare = prepare
        self.beginChange = beginChange
        self.endChange = endChange
    }
}
/// Business transaction; native and lifecycle operations are injected, without UI types.
@MainActor
public final class ProviderSettingsService {
    public func decisionConfiguration() async throws -> ProviderSettings {
        let value = try await decisionSnapshot()
        return try Self.decisionConfiguration(value)
    }
    public func decisionSnapshot() async throws -> ProviderSettings {
        if restored { return resolved(saved) }
        return try await restore()
    }
    public static func decisionConfiguration(_ value: ProviderSettings) throws -> ProviderSettings {
        guard let selected = value.decisionProviderID,
            let provider = value.providers.first(where: { $0.id == selected }),
            !value.decisionModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ProviderSettingsError.invalidSelection }
        return ProviderSettings(
            enabled: true, url: provider.url, key: provider.key, model: value.decisionModel,
            name: provider.name, id: provider.id)
    }
    public func writerConfiguration() async throws -> ProviderSettings {
        let value = try await restore()
        guard let selected = value.writerProviderID else {
            return ProviderSettings(enabled: false, url: "", key: "", model: "")
        }
        guard let provider = value.providers.first(where: { $0.id == selected }),
            !value.writerModel.isEmpty
        else { throw ProviderSettingsError.invalidSelection }
        return ProviderSettings(
            enabled: true, url: provider.url, key: provider.key, model: value.writerModel, name: provider.name,
            id: provider.id, writerThinking: value.writerThinking)
    }
    private let store: any ProviderSettingsPersistence
    private let runtime: ProviderSettingsRuntime
    private let legacyDecision: @Sendable () async throws -> Bool
    private let isDecisionInstalled: @Sendable () async throws -> Bool
    private var inheritedDecision = false
    private var saved: ProviderSettings?
    private var restored = false
    private var changing = false
    private var restoration: Task<ProviderSettings, any Error>?
    private var waiters = 0
    public init(
        store: any ProviderSettingsPersistence, runtime: ProviderSettingsRuntime,
        legacyDecision: @escaping @Sendable () async throws -> Bool = { false },
        isDecisionInstalled: @escaping @Sendable () async throws -> Bool = { false }
    ) {
        self.store = store
        self.runtime = runtime
        self.legacyDecision = legacyDecision
        self.isDecisionInstalled = isDecisionInstalled
    }
    public func summary() throws -> String {
        guard restored else { throw ProviderSettingsError.busy }
        let value = saved ?? runtime.initial
        return String(
            decoding: try JSONSerialization.data(
                withJSONObject: ["cloudEnabled": value.enabled, "selectedCloudModel": value.model],
                options: [.sortedKeys]), as: UTF8.self)
    }
    public func restore() async throws -> ProviderSettings {
        guard !changing, waiters < 32 else { throw ProviderSettingsError.busy }
        if restored { return resolved(saved) }
        waiters += 1
        defer { waiters -= 1 }
        if let restoration { return try await restoration.value }
        let task = Task { try await self.restoreSaved() }
        restoration = task
        defer { restoration = nil }
        return try await task.value
    }
    private func restoreSaved() async throws -> ProviderSettings {
        do {
            let value = try await store.load()
            if value?.decisionUsesLocal == nil { inheritedDecision = try await legacyDecision() }
            try await runtime.prepare(value)()
            saved = value
            restored = true
            return resolved(value)
        } catch { throw ProviderSettingsError.safe(error) }
    }
    private func resolved(_ raw: ProviderSettings?) -> ProviderSettings {
        var value = raw ?? runtime.initial
        if value.decisionUsesLocal == nil { value.decisionUsesLocal = inheritedDecision }
        return value
    }
    public func save(_ value: ProviderSettings) async throws -> ProviderSettings {
        guard !changing, restoration == nil else { throw ProviderSettingsError.busy }
        changing = true
        defer { changing = false }
        do {
            try Task.checkCancellation()
            let previous = saved
            let current = resolved(previous)
            var value = value
            value.decisionUsesLocal = value.decisionUsesLocal ?? current.decisionUsesLocal
            if value.decisionUsesLocal == true, current.decisionUsesLocal != true,
                try await !isDecisionInstalled()
            {
                throw ProviderSettingsError.decisionRequired
            }
            if value.enabled, value.model.isEmpty { throw ProviderSettingsError.invalidSelection }
            let assistantChanged =
                !restored || value.enabled != current.enabled
                || (value.enabled
                    && (value.url != current.url || value.key != current.key || value.model != current.model))
            if !assistantChanged {
                try await store.save(value)
                saved = value
                return value
            }
            let apply = try runtime.prepare(value)
            await runtime.beginChange()
            defer { runtime.endChange() }
            try await store.save(value)
            do { try await apply() } catch {
                let primary = ProviderSettingsError.safe(error)
                let store = self.store
                // An independently owned rollback must finish before releasing the barrier.
                let rollback = Task { try await store.save(previous) }
                do { try await rollback.value } catch {
                    throw ProviderSettingsError.rollback(
                        primary: primary.errorDescription ?? primary.executionFailureCode.rawValue,
                        secondary: ProviderSettingsError.safe(error).errorDescription ?? "provider.persistence")
                }
                throw primary
            }
            saved = value
            restored = true
            return value
        } catch { throw ProviderSettingsError.safe(error) }
    }
}

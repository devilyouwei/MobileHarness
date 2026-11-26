import Foundation
import FunctionContracts
import StorageCore
import StorageFiles

public enum ProviderSettingsError: LocalizedError, Sendable, ActionExecutionFailureProviding {
    case invalidSelection, invalidConfiguration, persistence, busy, application, cancelled, decisionRequired
    case languageRequired, appleUnavailable
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
        case .appleUnavailable: value = "provider.appleUnavailable"
        case .languageRequired: value = "provider.languageRequired"
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
        guard value.decisionUsesLocal != true, let selected = value.decisionProviderID,
            let provider = value.providers.first(where: { $0.id == selected }),
            !value.decisionModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ProviderSettingsError.invalidSelection }
        return ProviderSettings(
            enabled: true, url: provider.url, key: provider.key, model: value.decisionModel,
            name: provider.name, id: provider.id)
    }
    public func writerConfiguration() async throws -> ProviderSettings {
        let value = try await restore()
        return try Self.writerConfiguration(value)
    }
    static func writerConfiguration(_ value: ProviderSettings) throws -> ProviderSettings {
        if value.writerUsesLocal {
            return ProviderSettings(
                enabled: false, url: "", key: "", model: "", writerLocalModelID: value.resolvedWriterLocalModelID)
        }
        guard let selected = value.writerProviderID else { throw ProviderSettingsError.invalidSelection }
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
    private let localModels: @Sendable () async throws -> [LocalModelFact]
    private let beginModelChange: @MainActor @Sendable (ModelSettingsChange) async throws -> Void
    private let endModelChange: @MainActor @Sendable () -> Void
    private var inheritedDecision = false
    private var saved: ProviderSettings?
    private var restored = false
    private var changing = false
    private var restoration: Task<ProviderSettings, any Error>?
    private var waiters = 0
    public init(
        store: any ProviderSettingsPersistence, runtime: ProviderSettingsRuntime,
        legacyDecision: @escaping @Sendable () async throws -> Bool = { false },
        localModels: @escaping @Sendable () async throws -> [LocalModelFact] = { [] },
        beginModelChange: @escaping @MainActor @Sendable (ModelSettingsChange) async throws -> Void = { _ in },
        endModelChange: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.store = store
        self.runtime = runtime
        self.legacyDecision = legacyDecision
        self.localModels = localModels
        self.beginModelChange = beginModelChange
        self.endModelChange = endModelChange
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
    private func requireLocalModel(_ id: String, role: LocalModelFact.Role, models: [LocalModelFact]) throws {
        guard let model = models.first(where: { $0.id == id }), model.roles.contains(role) else {
            throw ProviderSettingsError.invalidSelection
        }
        guard !model.available else { return }
        guard model.needsDownload else {
            throw model.artifactID == nil ? ProviderSettingsError.appleUnavailable : .invalidSelection
        }
        throw role == .decision ? ProviderSettingsError.decisionRequired : .languageRequired
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
            value.decisionLocalModelID = value.decisionLocalModelID ?? current.decisionLocalModelID
            if value.decisionUsesLocal == true {
                value.decisionProviderID = nil
                value.decisionModel = ""
            }
            var changes: [(String, LocalModelFact.Role)] = []
            let localID = value.resolvedDecisionLocalModelID
            if value.decisionUsesLocal == true,
                current.decisionUsesLocal != true || localID != current.resolvedDecisionLocalModelID
            {
                changes.append((localID, .decision))
            }
            if !value.enabled, current.enabled || value.assistantLocalModelID != current.assistantLocalModelID {
                changes.append((value.assistantLocalModelID, .assistant))
            }
            if value.writerUsesLocal,
                !current.writerUsesLocal || value.resolvedWriterLocalModelID != current.resolvedWriterLocalModelID
            {
                changes.append((value.resolvedWriterLocalModelID, .writer))
            }
            if !changes.isEmpty {
                let models = try await localModels()
                for (id, role) in changes { try requireLocalModel(id, role: role, models: models) }
            }
            if value.writerUsesLocal && value.writerProviderID != nil { throw ProviderSettingsError.invalidSelection }
            if value.enabled, value.model.isEmpty { throw ProviderSettingsError.invalidSelection }
            let assistantChanged =
                !restored || value.enabled != current.enabled
                || (!value.enabled && value.assistantLocalModelID != current.assistantLocalModelID)
                || (value.enabled
                    && (value.url != current.url || value.key != current.key || value.model != current.model))
            let impact = Self.modelChange(from: current, to: value, assistantChanged: assistantChanged)
            if !impact.roles.isEmpty { try await beginModelChange(impact) }
            defer { if !impact.roles.isEmpty { endModelChange() } }
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

    static func modelChange(from current: ProviderSettings, to value: ProviderSettings, assistantChanged: Bool)
        -> ModelSettingsChange
    {
        var impact = ModelSettingsChange()
        if assistantChanged {
            impact.roles.insert(.assistant)
            if !value.enabled { impact.modelIDs.insert(value.assistantLocalModelID) }
        }
        func provider(_ id: String?, in settings: ProviderSettings) -> ProviderSettings? {
            settings.providers.first { $0.id == id }
        }
        if current.writerUsesLocal != value.writerUsesLocal
            || current.resolvedWriterLocalModelID != value.resolvedWriterLocalModelID
            || current.writerProviderID != value.writerProviderID || current.writerModel != value.writerModel
            || current.writerThinking != value.writerThinking
            || provider(current.writerProviderID, in: current) != provider(value.writerProviderID, in: value)
        {
            impact.roles.insert(.writer)
            if current.writerUsesLocal { impact.modelIDs.insert(current.resolvedWriterLocalModelID) }
            if value.writerUsesLocal { impact.modelIDs.insert(value.resolvedWriterLocalModelID) }
        }
        if current.decisionUsesLocal != value.decisionUsesLocal
            || current.resolvedDecisionLocalModelID != value.resolvedDecisionLocalModelID
            || current.decisionProviderID != value.decisionProviderID || current.decisionModel != value.decisionModel
            || provider(current.decisionProviderID, in: current) != provider(value.decisionProviderID, in: value)
        {
            impact.roles.insert(.decision)
            if current.decisionUsesLocal == true { impact.modelIDs.insert(current.resolvedDecisionLocalModelID) }
            if value.decisionUsesLocal == true { impact.modelIDs.insert(value.resolvedDecisionLocalModelID) }
        }
        return impact
    }
}

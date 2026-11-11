import Foundation
import Observation

public struct CloudSettingsDraft: Sendable, Equatable {
    public var id: String
    public var decisionProviderID: String?
    public var decisionModel: String
    public var decisionUsesLocal: Bool
    public var writerProviderID: String?
    public var writerModel: String
    public var writerThinking: Bool
    public var providers: [CloudSettingsDraft] = []
    public var name: String
    public var enabled: Bool
    public var url: String
    public var key: String
    public var model: String
    public init(
        enabled: Bool, url: String, key: String, model: String, providers: [CloudSettingsDraft] = [], name: String = "",
        id: String? = nil, writerProviderID: String? = nil, writerModel: String = "", writerThinking: Bool = false,
        decisionProviderID: String? = nil, decisionModel: String = "", decisionUsesLocal: Bool = false
    ) {
        self.id = id ?? url
        self.decisionProviderID = decisionProviderID
        self.decisionModel = decisionModel
        self.decisionUsesLocal = decisionUsesLocal
        self.writerProviderID = writerProviderID
        self.writerModel = writerModel
        self.writerThinking = writerThinking
        self.name = name.isEmpty ? (URL(string: url)?.host ?? "Provider") : name
        self.providers = providers
        self.enabled = enabled
        self.url = url
        self.key = key
        self.model = model
    }
}

public enum AgentBrain: String, CaseIterable, Identifiable, Sendable {
    case assistant, writer, decision
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public struct AgentBrainDraft: Equatable, Sendable {
    public var providerID: String?
    public var model: String
    public var usesLocal: Bool
    public var writerThinking: Bool
}

public enum BrainSettingsChange: Sendable {
    case providers([CloudSettingsDraft])
    case brain(AgentBrain, AgentBrainDraft)
}

/// Local modal draft. Dismissal discards this value without changing the selected provider.
public struct ProviderEditorDraft: Identifiable {
    public let id = UUID()
    public let originalURL: String?
    public let providerID: String?
    public var name: String
    public var url: String
    public var key: String
    public var model: String
    public init(provider: CloudSettingsDraft?, existing: [CloudSettingsDraft]) {
        providerID = provider?.id
        originalURL = provider?.url
        var number = 1
        while existing.contains(where: { $0.name == "Provider \(number)" }) { number += 1 }
        name = provider?.name ?? "Provider \(number)"
        url = provider?.url ?? ""
        key = provider?.key ?? ""
        model = provider?.model ?? ""
    }
    public func validated(existing: [CloudSettingsDraft]) throws -> CloudSettingsDraft {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = trimmedURL.isEmpty ? "https://api.openai.com/v1" : trimmedURL
        guard !name.isEmpty, name.utf8.count <= 128 else { throw ProviderEditorError.name }
        guard url.utf8.count <= 2048, let parsed = URL(string: url),
            ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
            parsed.host != nil, parsed.user == nil, parsed.password == nil
        else { throw ProviderEditorError.url }
        guard !existing.contains(where: { $0.url == url && $0.url != originalURL }) else {
            throw ProviderEditorError.duplicate
        }
        guard originalURL != nil || existing.count < 32 else { throw ProviderEditorError.capacity }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.utf8.count <= 4096 else { throw ProviderEditorError.key }
        return .init(enabled: false, url: url, key: key, model: model, name: name, id: providerID ?? UUID().uuidString)
    }
}
public enum ProviderEditorError: LocalizedError {
    case name, url, duplicate, capacity, key, missingKey
    public var errorDescription: String? {
        switch self {
        case .name: return "请输入名称（最多 128 字节）"
        case .url: return "请输入有效的 HTTP 或 HTTPS 服务 URL"
        case .duplicate: return "此 URL 已存在，请编辑已有 Provider"
        case .capacity: return "最多可保存 32 个 Provider"
        case .key: return "API Key 过长"
        case .missingKey: return "请输入 API key"
        }
    }
}

@MainActor
public protocol SettingsOperating: AnyObject {
    var presentsResults: Bool { get }
    func restore() async throws -> CloudSettingsDraft
    func discover(_ draft: CloudSettingsDraft) async throws -> [String]
    func save(_ draft: CloudSettingsDraft) async throws
}

@MainActor
public protocol SettingsControlling: AnyObject {
    var needsWelcome: Bool { get }
    func saveWelcomeProvider(url: String, key: String) async -> Bool
    func restore() async throws
    func loadModels(providerID: String)
    func refreshModels()
    func save() async -> Bool
    func save(_ change: BrainSettingsChange) async -> Bool
    func cancelDiscovery()
}

/// Editable form values only. Execution and lifetime are supplied through SettingsControlling.
@MainActor
@Observable
public final class SettingsState {
    @ObservationIgnored var presentationAdmission: UIPresentationAdmission?
    public var isPresentationAvailable: Bool { presentationAdmission.map { $0.started && !$0.stopped } ?? true }

    public var providers: [CloudSettingsDraft] = []
    public var modelCatalogs: [String: [String]] = [:]
    public var loadingProviderIDs: Set<String> = []
    public var modelErrors: [String: String] = [:]
    public internal(set) var isEnabled: Bool
    public internal(set) var url: String { didSet { if oldValue != url { revision += 1 } } }
    public internal(set) var key: String { didSet { if oldValue != key { revision += 1 } } }
    public internal(set) var selectedModel: String
    public internal(set) var isLoading = false
    public internal(set) var isSaving = false
    public internal(set) var error: String?
    public internal(set) var notice: String?
    public private(set) var revision: UInt64 = 0
    public var decisionProviderID: String? { didSet { if oldValue != decisionProviderID { revision += 1 } } }
    public var decisionModel = "" { didSet { if oldValue != decisionModel { revision += 1 } } }
    public var decisionUsesLocal = false { didSet { if oldValue != decisionUsesLocal { revision += 1 } } }
    public var writerProviderID: String? { didSet { if oldValue != writerProviderID { revision += 1 } } }
    public var writerModel = "" { didSet { if oldValue != writerModel { revision += 1 } } }
    public var writerThinking = false { didSet { if oldValue != writerThinking { revision += 1 } } }
    public init(initial: CloudSettingsDraft) {
        decisionProviderID = initial.decisionProviderID
        decisionModel = initial.decisionModel
        decisionUsesLocal = initial.decisionUsesLocal
        writerProviderID = initial.writerProviderID
        writerModel = initial.writerModel
        writerThinking = initial.writerThinking
        providers = initial.providers
        isEnabled = initial.enabled
        url = initial.url
        key = initial.key
        selectedModel = initial.model
    }
    public var assistantProviderID: String? {
        isEnabled ? providers.first(where: { $0.url == url })?.id : nil
    }
    public func brainDraft(_ brain: AgentBrain) -> AgentBrainDraft {
        switch brain {
        case .assistant:
            .init(
                providerID: assistantProviderID, model: isEnabled ? selectedModel : "", usesLocal: !isEnabled,
                writerThinking: false)
        case .writer:
            .init(providerID: writerProviderID, model: writerModel, usesLocal: false, writerThinking: writerThinking)
        case .decision:
            .init(
                providerID: decisionProviderID, model: decisionModel, usesLocal: decisionUsesLocal,
                writerThinking: false)
        }
    }
    public func selectAssistantProvider(_ id: String?) {
        guard let provider = providers.first(where: { $0.id == id }) else {
            isEnabled = false
            url = ""
            key = ""
            selectedModel = ""
            return
        }
        isEnabled = true
        url = provider.url
        key = provider.key
        selectedModel = ""
        invalidateRevision()
    }
    public func selectDecisionProvider(_ id: String?) {
        decisionProviderID = id
        decisionModel = ""
    }
    public func selectWriterProvider(_ id: String?) {
        writerProviderID = id
        writerModel = ""
    }
    public func upsertProvider(_ provider: CloudSettingsDraft) {
        let assistantID = assistantProviderID
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
        if assistantID == provider.id {
            url = provider.url
            key = provider.key
        }
        modelCatalogs[provider.id] = nil
        modelErrors[provider.id] = nil
        invalidateRevision()
    }
    public func removeProvider(_ id: String) {
        if assistantProviderID == id { selectAssistantProvider(nil) }
        if decisionProviderID == id { selectDecisionProvider(nil) }
        if writerProviderID == id { selectWriterProvider(nil) }
        providers.removeAll { $0.id == id }
        modelCatalogs[id] = nil
        modelErrors[id] = nil
        invalidateRevision()
    }
    public var canLoad: Bool { !isLoading && !isSaving }
    public var canSave: Bool {
        !isSaving && (!isEnabled || !selectedModel.isEmpty)
            && (decisionProviderID == nil
                || (!decisionModel.isEmpty && providers.contains { $0.id == decisionProviderID }))
            && (writerProviderID == nil || (!writerModel.isEmpty && providers.contains { $0.id == writerProviderID }))
    }
    @discardableResult
    public func presentFailure(_ message: String, revision: UInt64) -> Bool {
        guard presentationAdmission?.acceptsRetained() ?? true else { return false }
        guard revision == self.revision else { return false }
        error = message
        isLoading = false
        return true
    }
    @discardableResult
    public func presentRestored(_ value: CloudSettingsDraft, revision: UInt64) -> Bool {
        guard presentationAdmission?.acceptsRetained() ?? true else { return false }
        guard revision == self.revision else { return false }
        decisionProviderID = value.decisionProviderID
        decisionModel = value.decisionModel
        decisionUsesLocal = value.decisionUsesLocal
        writerProviderID = value.writerProviderID
        writerModel = value.writerModel
        writerThinking = value.writerThinking
        providers = value.providers
        isEnabled = value.enabled
        url = value.url
        key = value.key
        selectedModel = value.model
        error = nil
        return true
    }
    @discardableResult
    public func presentNotice(_ message: String, revision: UInt64) -> Bool {
        guard presentationAdmission?.acceptsRetained() ?? true else { return false }
        guard revision == self.revision else { return false }
        notice = message
        error = nil
        return true
    }
    public func invalidateRevision() {
        guard presentationAdmission?.acceptsRetained() ?? true else { return }
        revision += 1
    }

    @discardableResult
    public func present(_ update: SettingsUpdate) -> Bool {
        guard presentationAdmission?.acceptsRetained() ?? true else { return false }
        apply(update)
        return true
    }
    func apply(_ update: SettingsUpdate) {
        switch update {
        case .isEnabled(let value): isEnabled = value
        case .url(let value): url = value
        case .key(let value): key = value
        case .selectedModel(let value): selectedModel = value
        case .isLoading(let value): isLoading = value
        case .isSaving(let value): isSaving = value
        case .error(let value): error = value
        case .notice(let value): notice = value
        }
    }
}

extension SettingsOperating { public var presentsResults: Bool { false } }
public protocol SettingsFailurePresenting: Error { var wasPresented: Bool { get } }

public enum SettingsUpdate {
    case isEnabled(Bool)
    case url(String)
    case key(String)
    case selectedModel(String)
    case isLoading(Bool)
    case isSaving(Bool)
    case error(String?)
    case notice(String?)
}

@MainActor
public protocol SettingsPresenting: UIPresentationAccess {
    var providers: [CloudSettingsDraft] { get set }
    var modelCatalogs: [String: [String]] { get set }
    var loadingProviderIDs: Set<String> { get set }
    var modelErrors: [String: String] { get set }
    var decisionProviderID: String? { get set }
    var decisionModel: String { get set }
    var decisionUsesLocal: Bool { get set }
    var writerProviderID: String? { get set }
    var writerModel: String { get set }
    var writerThinking: Bool { get set }
    var isEnabled: Bool { get }
    var url: String { get }
    var key: String { get }
    var selectedModel: String { get }
    var isLoading: Bool { get }
    var isSaving: Bool { get }
    var error: String? { get }
    var notice: String? { get }
    var revision: UInt64 { get }
    var canLoad: Bool { get }
    var canSave: Bool { get }
    @discardableResult
    func present(_ update: SettingsUpdate) -> Bool
    func presentFailure(_ message: String, revision: UInt64) -> Bool
    func presentRestored(_ value: CloudSettingsDraft, revision: UInt64) -> Bool
    func presentNotice(_ message: String, revision: UInt64) -> Bool
    func invalidateRevision()
}

extension SettingsState: SettingsPresenting {}

/// Form-facing operations are injected transports, never storage or provider application.
@MainActor
public struct SettingsProviderOperations {
    public let initial: CloudSettingsDraft
    public let restore: () async throws -> CloudSettingsDraft
    public let discover: (CloudSettingsDraft) async throws -> [String]
    public let save: (CloudSettingsDraft) async throws -> Void
    public let errorMessage: (any Error) -> String?
    public init(
        initial: CloudSettingsDraft,
        restore: @escaping () async throws -> CloudSettingsDraft,
        discover: @escaping (CloudSettingsDraft) async throws -> [String],
        save: @escaping (CloudSettingsDraft) async throws -> Void,
        errorMessage: @escaping (any Error) -> String?
    ) {
        self.initial = initial
        self.restore = restore
        self.discover = discover
        self.save = save
        self.errorMessage = errorMessage
    }
}

public protocol ProviderRequestFailure: Error {
    var failureCode: String? { get }
}

@MainActor
public final class UISettingsContainer {
    public func stateSnapshot() async throws -> UIStateSnapshot {
        try Task.checkCancellation()
        return UIStateSnapshot(
            path: "ui.settings",
            business: [
                "enabled": .flag(state.isEnabled),
                "problem": state.error == nil ? .unknown : .text("settingsOperationFailed"),
                "loading": .flag(state.isLoading), "saving": .flag(state.isSaving),
            ], runtime: ["available": .flag(state.isPresentationAvailable)],
            meanings: [
                "business.enabled":
                    "Cloud-provider switch in the current editable settings draft; not saved configuration or module readiness",
                "business.loading": "Provider/model discovery currently shown by the settings workflow",
                "business.saving": "Settings save in progress; not proof the draft is persisted",
            ])
    }

    public let requests = UIRequests<SettingsInput, SettingsReply>()

    public let state: SettingsState
    public var presentation: any SettingsPresenting { state }
    init(initial: CloudSettingsDraft, admission: UIPresentationAdmission) {
        state = SettingsState(initial: initial)
        state.presentationAdmission = admission
    }
    func clearSensitiveDraft() {
        state.key = ""
        state.providers = []
        state.modelCatalogs = [:]
        state.modelErrors = [:]
        state.loadingProviderIDs = []
        state.isLoading = false
        state.isSaving = false
        state.invalidateRevision()
    }
}

public enum SettingsInput: Sendable {
    case restore
    case discover(CloudSettingsDraft)
    case save(CloudSettingsDraft)
}
public enum SettingsReply: Sendable {
    case draft(CloudSettingsDraft)
    case models([String])
    case completed
}

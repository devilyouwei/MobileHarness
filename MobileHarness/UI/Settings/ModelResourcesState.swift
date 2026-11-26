import Foundation
import Observation

public enum ModelResourceActivity: Sendable { case queued, downloading, installing, deleting }

public struct ModelResourceItem: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let status: String
    public let revision: String
    public let installedBytes: Int64
    public let license: String
    public let bytes: Int64
    public let progress: Double
    public let installed: Bool
    public let active: Bool
    public let activity: ModelResourceActivity?
    public let failure: String?
    public init(
        id: String, name: String, status: String, bytes: Int64, progress: Double, installed: Bool, active: Bool,
        failure: String?, revision: String = "", installedBytes: Int64 = 0, license: String = "",
        activity: ModelResourceActivity? = nil
    ) {
        self.revision = revision
        self.installedBytes = installedBytes
        self.license = license
        self.id = id
        self.name = name
        self.status = status
        self.bytes = bytes
        self.progress = progress.isFinite ? max(0, min(1, progress)) : 0
        self.installed = installed
        self.active = active
        self.activity = activity
        self.failure = failure
    }
}
public enum ModelResourceGroup: String, Sendable, CaseIterable {
    case recognition, synthesis, language, vision, decision
    public var title: String {
        switch self {
        case .recognition: "Speech Recognition"
        case .synthesis: "Speech Synthesis"
        case .language: "Language model"
        case .vision: "Vision Recognition"
        case .decision: "Decision"
        }
    }
    public var modelIDs: Set<String> {
        switch self {
        case .recognition: ["nemotron", "silero", "deepfilternet3", "zipformer-kws", "smart-turn"]
        case .synthesis: ["moss-tts-nano", "kokoro-82m"]
        case .language: []
        case .vision: ["yolo26n-pose"]
        case .decision: []
        }
    }
    public var installationMessage: String {
        switch self {
        case .recognition: "Download Nemotron first."
        case .synthesis: "Download the selected speech synthesis model first."
        case .language: "Download this model in Agent Models first."
        case .vision: "Download and install the YOLO pose model first."
        case .decision: "Download the selected Decision model before using it."
        }
    }
}
public struct ModelResourceSourceDraft: Codable, Sendable {
    public var endpoint: String
    public var allowsCellular: Bool
    public var useSpeechEnhancement: Bool
    public var useKeywordInterrupt: Bool
    public var useCustomRecognition: Bool
    public var useCustomSynthesis: Bool
    public var vadOnsetWindows: Int
    public var vadThreshold: Double
    public var keywordThreshold: Double
    public var useLocalDecision: Bool
    public var speechModels: [String: String]?
    public var synthesisVoice: String?
    private enum CodingKeys: String, CodingKey {
        case endpoint, allowsCellular, useCustomRecognition, useCustomSynthesis, useLocalDecision, vadOnsetWindows,
            vadThreshold, useSpeechEnhancement, useKeywordInterrupt, speechModels, synthesisVoice, keywordThreshold
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        synthesisVoice = try values.decodeIfPresent(String.self, forKey: .synthesisVoice)
        speechModels = try values.decodeIfPresent([String: String].self, forKey: .speechModels)
        useSpeechEnhancement = try values.decodeIfPresent(Bool.self, forKey: .useSpeechEnhancement) ?? false
        useKeywordInterrupt = try values.decodeIfPresent(Bool.self, forKey: .useKeywordInterrupt) ?? false
        vadOnsetWindows = try values.decodeIfPresent(Int.self, forKey: .vadOnsetWindows) ?? 8
        vadThreshold = try values.decodeIfPresent(Double.self, forKey: .vadThreshold) ?? 0.65
        keywordThreshold = try values.decodeIfPresent(Double.self, forKey: .keywordThreshold) ?? 0.25
        endpoint = try values.decode(String.self, forKey: .endpoint)
        allowsCellular = try values.decode(Bool.self, forKey: .allowsCellular)
        useCustomRecognition = try values.decode(Bool.self, forKey: .useCustomRecognition)
        useCustomSynthesis = try values.decode(Bool.self, forKey: .useCustomSynthesis)
        useLocalDecision = try values.decodeIfPresent(Bool.self, forKey: .useLocalDecision) ?? false
    }
    public init(
        endpoint: String = "https://huggingface.co", allowsCellular: Bool = true,
        useCustomRecognition: Bool = false, useCustomSynthesis: Bool = false, useLocalDecision: Bool = false,
        vadOnsetWindows: Int = 8, vadThreshold: Double = 0.65, useSpeechEnhancement: Bool = false,
        useKeywordInterrupt: Bool = false, speechModels: [String: String]? = nil, synthesisVoice: String? = nil,
        keywordThreshold: Double = 0.25
    ) {
        self.useSpeechEnhancement = useSpeechEnhancement
        self.useKeywordInterrupt = useKeywordInterrupt
        self.speechModels = speechModels
        self.synthesisVoice = synthesisVoice
        self.vadOnsetWindows = vadOnsetWindows
        self.vadThreshold = vadThreshold
        self.keywordThreshold = keywordThreshold
        self.endpoint = endpoint
        self.allowsCellular = allowsCellular
        self.useCustomRecognition = useCustomRecognition
        self.useCustomSynthesis = useCustomSynthesis
        self.useLocalDecision = useLocalDecision
    }

}
public struct LocalModelOption: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let artifactID: String?
    public let roles: Set<AgentBrain>
    public let nativeDecision: Bool
    public let available: Bool
    public let unavailableReason: String?
    public let needsDownload: Bool

    public init(
        id: String, name: String, artifactID: String?, roles: Set<AgentBrain>, nativeDecision: Bool,
        available: Bool, unavailableReason: String? = nil, needsDownload: Bool = false
    ) {
        self.id = id
        self.name = name
        self.artifactID = artifactID
        self.roles = roles
        self.nativeDecision = nativeDecision
        self.available = available
        self.unavailableReason = unavailableReason
        self.needsDownload = needsDownload
    }
}

public enum SpeechCapability: String, CaseIterable, Sendable {
    case voiceActivity, endpointConfirmation, enhancement, keywordSpotting, recognition, synthesis

    public var title: String {
        switch self {
        case .voiceActivity: "Voice activity detection"
        case .enhancement: "Noise suppression"
        case .keywordSpotting: "Keyword spotting"
        case .endpointConfirmation: "End-of-turn confirmation"
        case .recognition: "Speech Recognition"
        case .synthesis: "Speech Synthesis"
        }
    }
}

public struct SpeechModelChoice: Identifiable, Sendable {
    public let capability: SpeechCapability
    public let id: String
    public let title: String
    public let artifactID: String?
    public let voicesByLanguage: [String: [String]]?

    public init(
        capability: SpeechCapability, id: String, title: String, artifactID: String?,
        voicesByLanguage: [String: [String]]? = nil
    ) {
        self.capability = capability
        self.id = id
        self.title = title
        self.artifactID = artifactID
        self.voicesByLanguage = voicesByLanguage
    }
}

/// Passive presentation snapshot; eligibility is supplied by the business layer.
public struct ModelResourceViewSnapshot: Sendable {
    public let items: [ModelResourceItem]
    public let installedGroups: Set<ModelResourceGroup>
    public let languageModels: [LocalModelOption]
    public let speechOptions: [SpeechModelChoice]
    public init(
        items: [ModelResourceItem], installedGroups: Set<ModelResourceGroup> = [],
        speechOptions: [SpeechModelChoice] = [], languageModels: [LocalModelOption] = []
    ) {
        self.items = items
        self.installedGroups = installedGroups
        self.languageModels = languageModels
        self.speechOptions = speechOptions
    }
}
public enum ModelResourceOperation: Sendable { case download, remove, cancel }

@MainActor
public protocol ModelResourcesControlling: AnyObject {
    func restore() async
    func editDownloadSource(_ endpoint: String)
    func refresh() async
    func saveSource() async
    func saveDownloadSource() async -> Bool
    func selectSpeechModel(_ modelID: String, for capability: SpeechCapability) async
    func selectSynthesisVoice(_ voice: String) async
    func setSpeechEnhancement(enabled: Bool) async
    func setKeywordInterrupt(enabled: Bool) async
    func setSpeechDetection(windows: Int, threshold: Double) async
    func setKeywordThreshold(_ threshold: Double) async
    func setCustomModel(_ group: ModelResourceGroup, enabled: Bool) async
    func perform(_ id: String, operation: ModelResourceOperation) async
}

@MainActor
@Observable
public final class ModelResourcesState {
    @ObservationIgnored var presentationAdmission: UIPresentationAdmission?
    public var isPresentationAvailable: Bool { presentationAdmission.map { $0.started && !$0.stopped } ?? true }

    public private(set) var decisionStatus = "No decision recorded"
    public internal(set) var source = ModelResourceSourceDraft()
    public internal(set) var items: [ModelResourceItem] = []
    public internal(set) var installedGroups: Set<ModelResourceGroup> = []
    public private(set) var languageModels: [LocalModelOption] = []
    public private(set) var speechOptions: [SpeechModelChoice] = []
    public func speechOptions(for capability: SpeechCapability) -> [SpeechModelChoice] {
        speechOptions.filter { $0.capability == capability }
    }
    public func localModels(for role: AgentBrain) -> [LocalModelOption] {
        languageModels.filter { $0.roles.contains(role) }
    }
    func modelIDs(for group: ModelResourceGroup) -> Set<String> {
        switch group {
        case .language: Set(languageModels.filter { !$0.nativeDecision }.compactMap(\.artifactID))
        case .decision: Set(languageModels.filter(\.nativeDecision).compactMap(\.artifactID))
        default: group.modelIDs
        }
    }
    public internal(set) var error: String? { didSet { refreshErrorGeneration = nil } }
    private var refreshErrorGeneration: UInt64?
    public internal(set) var saving = false
    public internal(set) var installationNotice: String?
    public internal(set) var hasRestored = false
    public internal(set) var pending: [String: ModelResourceOperation] = [:]
    public internal(set) var admitted: Set<String> = []
    public internal(set) var cancelling: Set<String> = []
    public private(set) var refreshGeneration: UInt64 = 0
    @discardableResult
    public func beginRefresh() -> UInt64 {
        guard presentationAdmission?.acceptsRetained() ?? true else { return 0 }
        refreshGeneration &+= 1
        if refreshGeneration == 0 { refreshGeneration = 1 }
        return refreshGeneration
    }
    public func applySnapshot(_ snapshot: ModelResourceViewSnapshot, generation: UInt64) -> Bool {
        guard presentationAdmission?.acceptsRetained() ?? true else { return false }
        guard generation == refreshGeneration, generation > 0 else { return false }
        items = snapshot.items
        installedGroups = snapshot.installedGroups
        languageModels = snapshot.languageModels
        speechOptions = snapshot.speechOptions
        if refreshErrorGeneration != nil { error = nil }
        return true
    }
    public func applyRefreshFailure(_ message: String, generation: UInt64) -> Bool {
        guard presentationAdmission?.acceptsRetained() ?? true else { return false }
        guard generation == refreshGeneration, generation > 0 else { return false }
        error = message
        refreshErrorGeneration = generation
        return true
    }
    public init() {}
    public func presentInstallationNotice(_ message: String) {
        guard presentationAdmission?.acceptsRetained() ?? true else { return }
        installationNotice = message
        error = nil
    }
    public func presentOperationFailure(_ message: String) {
        guard presentationAdmission?.acceptsRetained() ?? true else { return }
        error = message
    }

    public func isDownloading(_ item: ModelResourceItem) -> Bool {
        pending[item.id] == .download || admitted.contains(item.id) || (item.active && item.activity != .deleting)
    }
    public func isBusy(_ item: ModelResourceItem) -> Bool {
        pending[item.id] != nil || admitted.contains(item.id) || cancelling.contains(item.id) || item.active
    }
    public func isCancelling(_ id: String) -> Bool { cancelling.contains(id) }
    public func status(_ item: ModelResourceItem) -> String {
        if cancelling.contains(item.id) { return "Cancelling…" }
        if pending[item.id] == .remove { return "Deleting…" }
        if pending[item.id] == .download && !item.active { return "Starting download…" }
        if admitted.contains(item.id) && !item.active { return "Downloading. Waiting for an update…" }
        return item.status
    }

    @discardableResult
    public func present(_ update: ModelResourcesUpdate) -> Bool {
        guard presentationAdmission?.acceptsRetained() ?? true else { return false }
        apply(update)
        return true
    }
    func apply(_ update: ModelResourcesUpdate) {
        switch update {
        case .sourceEndpoint(let value): source.endpoint = value
        case .sourceAllowsCellular(let value): source.allowsCellular = value
        case .sourceUseSpeechEnhancement(let value): source.useSpeechEnhancement = value
        case .sourceUseKeywordInterrupt(let value): source.useKeywordInterrupt = value
        case .sourceSpeechModels(let value): source.speechModels = value
        case .sourceSynthesisVoice(let value): source.synthesisVoice = value
        case .sourceUseCustomRecognition(let value): source.useCustomRecognition = value
        case .sourceUseCustomSynthesis(let value): source.useCustomSynthesis = value
        case .speechDetection(let windows, let threshold):
            source.vadOnsetWindows = windows
            source.vadThreshold = threshold
        case .keywordThreshold(let value): source.keywordThreshold = value
        case .decisionStatus(let value): decisionStatus = value
        case .source(let value): source = value
        case .items(let value): items = value
        case .installedGroups(let value): installedGroups = value
        case .error(let value): error = value
        case .saving(let value): saving = value
        case .installationNotice(let value): installationNotice = value
        case .hasRestored(let value): hasRestored = value
        case .pending(let value): pending = value
        case .admitted(let value): admitted = value
        case .cancelling(let value): cancelling = value
        }
    }
}

public enum ModelResourcesUpdate {
    case sourceEndpoint(String)
    case sourceAllowsCellular(Bool)
    case sourceUseCustomRecognition(Bool)
    case sourceUseCustomSynthesis(Bool)
    case sourceUseSpeechEnhancement(Bool)
    case sourceUseKeywordInterrupt(Bool)
    case sourceSpeechModels([String: String]?)
    case sourceSynthesisVoice(String?)
    case speechDetection(windows: Int, threshold: Double)
    case keywordThreshold(Double)
    case decisionStatus(String)
    case source(ModelResourceSourceDraft)
    case items([ModelResourceItem])
    case installedGroups(Set<ModelResourceGroup>)
    case error(String?)
    case saving(Bool)
    case installationNotice(String?)
    case hasRestored(Bool)
    case pending([String: ModelResourceOperation])
    case admitted(Set<String>)
    case cancelling(Set<String>)
}

@MainActor
public protocol ModelResourcesPresenting: UIPresentationAccess {
    func speechOptions(for capability: SpeechCapability) -> [SpeechModelChoice]
    var source: ModelResourceSourceDraft { get }
    var items: [ModelResourceItem] { get }
    var installedGroups: Set<ModelResourceGroup> { get }
    var error: String? { get }
    var saving: Bool { get }
    var installationNotice: String? { get }
    var hasRestored: Bool { get }
    var pending: [String: ModelResourceOperation] { get }
    var admitted: Set<String> { get }
    var cancelling: Set<String> { get }
    var refreshGeneration: UInt64 { get }
    @discardableResult
    func present(_ update: ModelResourcesUpdate) -> Bool
    func beginRefresh() -> UInt64
    func applySnapshot(_ snapshot: ModelResourceViewSnapshot, generation: UInt64) -> Bool
    func applyRefreshFailure(_ message: String, generation: UInt64) -> Bool
    func presentInstallationNotice(_ message: String)
    func presentOperationFailure(_ message: String)
    func isDownloading(_ item: ModelResourceItem) -> Bool
    func isBusy(_ item: ModelResourceItem) -> Bool
    func isCancelling(_ id: String) -> Bool
    func status(_ item: ModelResourceItem) -> String
}

extension ModelResourcesState: ModelResourcesPresenting {}

@MainActor
public protocol ModelResourcesOperating: AnyObject {
    func refresh(generation: UInt64?) async throws -> ModelResourceViewSnapshot
    func restoreSource() async throws -> ModelResourceSourceDraft
    func saveSource(_ source: ModelResourceSourceDraft) async throws
    func download(_ id: String) async throws
    func cancel(_ id: String) async throws
    func remove(_ id: String) async throws
}

public struct ModelResourceSelectionError: LocalizedError, Sendable {
    public let group: ModelResourceGroup
    public init(group: ModelResourceGroup) { self.group = group }
    public var errorDescription: String? { group.installationMessage }
}

@MainActor
public final class UIModelResourcesContainer {
    public func stateSnapshot() async throws -> UIStateSnapshot {
        try Task.checkCancellation()
        return UIStateSnapshot(
            path: "ui.modelresources",
            business: [
                "itemCount": .count(state.items.count),
                "problem": state.error == nil ? .unknown : .text("resourceSettingsOperationFailed"),
                "saving": .flag(state.saving),
            ],
            runtime: ["available": .flag(state.isPresentationAvailable)],
            meanings: [
                "business.itemCount": "Number of catalog entries currently presented; not installed model count",
                "business.saving": "Resource-source or custom-speech preference save in progress; not a model download",
            ])
    }

    public let requests = UIRequests<ResourcesInput, ResourcesReply>(producer: "ui.settings.resources")

    public let state = ModelResourcesState()
    public var presentation: any ModelResourcesPresenting { state }
    init(admission: UIPresentationAdmission) { state.presentationAdmission = admission }
}

public enum ResourcesInput: Sendable {
    case refresh(UInt64?)
    case restore
    case save(ModelResourceSourceDraft)
    case download(String, ModelResourceSourceDraft)
    case cancel(String)
    case remove(String)
}
public enum ResourcesReply: Sendable {
    case snapshot(ModelResourceViewSnapshot)
    case source(ModelResourceSourceDraft)
    case completed
}

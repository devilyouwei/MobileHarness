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
    case recognition, synthesis, language, vision
    public var title: String {
        switch self {
        case .recognition: "音频识别"
        case .synthesis: "语音合成"
        case .language: "大模型"
        case .vision: "视觉识别"
        }
    }
    public var modelIDs: Set<String> {
        switch self {
        case .recognition: ["nemotron", "silero"]
        case .synthesis: ["moss-tts-nano"]
        case .language: ["gemma4-e2b"]
        case .vision: ["yolo26n-pose"]
        }
    }
    public var installationMessage: String {
        switch self {
        case .recognition: "请先下载并安装 Nemotron 语音识别模型，再开启自定义识别模型。"
        case .synthesis: "请先下载并安装 MOSS 语音合成模型，再开启自定义模型。"
        case .language: "请先下载并安装 Gemma 4 E2B 大模型，再切换到本地模型。"
        case .vision: "请先下载并安装 YOLO 姿态模型。"
        }
    }
}
public struct ModelResourceSourceDraft: Codable, Sendable {
    public var endpoint: String
    public var allowsCellular: Bool
    public var useCustomRecognition: Bool
    public var useCustomSynthesis: Bool
    public init(
        endpoint: String = "https://huggingface.co", allowsCellular: Bool = true,
        useCustomRecognition: Bool = false, useCustomSynthesis: Bool = false
    ) {
        self.endpoint = endpoint
        self.allowsCellular = allowsCellular
        self.useCustomRecognition = useCustomRecognition
        self.useCustomSynthesis = useCustomSynthesis
    }
    private enum CodingKeys: String, CodingKey {
        case endpoint, allowsCellular, useCustomRecognition, useCustomSynthesis, preferDownloadedSpeech
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try values.decode(String.self, forKey: .endpoint)
        allowsCellular = try values.decode(Bool.self, forKey: .allowsCellular)
        let legacy = try values.decodeIfPresent(Bool.self, forKey: .preferDownloadedSpeech) ?? true
        useCustomRecognition = try values.decodeIfPresent(Bool.self, forKey: .useCustomRecognition) ?? legacy
        useCustomSynthesis = try values.decodeIfPresent(Bool.self, forKey: .useCustomSynthesis) ?? legacy
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(endpoint, forKey: .endpoint)
        try values.encode(allowsCellular, forKey: .allowsCellular)
        try values.encode(useCustomRecognition, forKey: .useCustomRecognition)
        try values.encode(useCustomSynthesis, forKey: .useCustomSynthesis)
    }
}
/// Passive presentation snapshot; eligibility is supplied by the business layer.
public struct ModelResourceViewSnapshot: Sendable {
    public let items: [ModelResourceItem]
    public let installedGroups: Set<ModelResourceGroup>
    public init(items: [ModelResourceItem], installedGroups: Set<ModelResourceGroup> = []) {
        self.items = items
        self.installedGroups = installedGroups
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
    func setCustomModel(_ group: ModelResourceGroup, enabled: Bool) async
    func perform(_ id: String, operation: ModelResourceOperation) async
}

@MainActor
@Observable
public final class ModelResourcesState {
    @ObservationIgnored var presentationAdmission: UIPresentationAdmission?
    public var isPresentationAvailable: Bool { presentationAdmission.map { $0.started && !$0.stopped } ?? true }

    public internal(set) var source = ModelResourceSourceDraft()
    public internal(set) var items: [ModelResourceItem] = []
    public internal(set) var installedGroups: Set<ModelResourceGroup> = []
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
        if cancelling.contains(item.id) { return "正在取消…" }
        if pending[item.id] == .remove { return "正在删除…" }
        if pending[item.id] == .download && !item.active { return "正在提交下载…" }
        if admitted.contains(item.id) && !item.active { return "正在下载，等待状态更新…" }
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
        case .sourceUseCustomRecognition(let value): source.useCustomRecognition = value
        case .sourceUseCustomSynthesis(let value): source.useCustomSynthesis = value
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

    public let requests = UIRequests<ResourcesInput, ResourcesReply>()

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

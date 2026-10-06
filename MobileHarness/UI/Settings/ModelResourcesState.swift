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
public enum ModelResourceOperation: Sendable { case download, remove, cancel }

@MainActor public protocol ModelResourcesControlling: AnyObject {
    func restore() async
    func refresh() async
    func saveSource() async
    func saveDownloadSource() async -> Bool
    func setCustomModel(_ group: ModelResourceGroup, enabled: Bool) async
    func perform(_ id: String, operation: ModelResourceOperation) async
}

@MainActor @Observable public final class ModelResourcesState {
    public var source = ModelResourceSourceDraft()
    public var items: [ModelResourceItem] = []
    public var installedGroups: Set<ModelResourceGroup> = []
    public var error: String?
    public var saving = false
    public var installationNotice: String?
    public var hasRestored = false
    public var pending: [String: ModelResourceOperation] = [:]
    public var admitted: Set<String> = []
    public var cancelling: Set<String> = []
    public init() {}
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

}

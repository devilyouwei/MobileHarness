import Foundation
import FunctionContracts

public enum ResourceModelGroup: String, Codable, Sendable, CaseIterable {
    case recognition, synthesis, language, vision, decision
    public var requiredIDs: Set<String> {
        switch self {
        case .recognition: ["nemotron"]
        case .synthesis: ["moss-tts-nano", "kokoro-82m"]
        case .language: []
        case .vision: ["yolo26n-pose"]
        case .decision: []
        }
    }
    public func isInstalled(in ids: Set<String>) -> Bool {
        if self == .synthesis { return !requiredIDs.isDisjoint(with: ids) }
        return !requiredIDs.isEmpty && requiredIDs.isSubset(of: ids)
    }
}
public struct ModelResourceFact: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case notInstalled, queued, downloading, verifying, installed, deleting, failed
    }
    public let id: String
    public let name: String
    public let revision: String
    public let license: String
    public let bytes: Int64
    public let installedBytes: Int64
    public let completedBytes: Int64
    public let phase: Phase
    public let failure: String?
    public var progress: Double { min(1, Double(completedBytes) / Double(max(1, bytes))) }
    public var active: Bool { [.queued, .downloading, .verifying, .deleting].contains(phase) }
    public init(
        id: String, name: String, revision: String = "", license: String = "", bytes: Int64,
        installedBytes: Int64 = 0, completedBytes: Int64 = 0, phase: Phase, failure: String? = nil
    ) {
        self.id = id
        self.name = name
        self.revision = revision
        self.license = license
        self.bytes = bytes
        self.installedBytes = installedBytes
        self.completedBytes = completedBytes
        self.phase = phase
        self.failure = failure
    }
}
public struct LocalModelFact: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case assistant, writer, decision }
    public let id: String
    public let name: String
    public let artifactID: String?
    public let roles: Set<Role>
    public let nativeDecision: Bool
    public let available: Bool
    public let unavailableReason: String?
    public let needsDownload: Bool

    public init(
        id: String, name: String, artifactID: String?, roles: Set<Role>, nativeDecision: Bool,
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

public struct SpeechModelFact: Codable, Sendable, Equatable {
    public let capability: String
    public let id: String
    public let title: String
    public let artifactID: String?
    public let voicesByLanguage: [String: [String]]?
}

public enum ResourceInventoryError: Error, Sendable { case invalidSnapshot, capacityExceeded }
public struct ModelResourceInventory: Codable, Sendable, Equatable {
    public static let maximumBytes = 65_536
    public let version: Int
    public let items: [ModelResourceFact]
    public let languageModels: [LocalModelFact]?
    public let speechOptions: [SpeechModelFact]?
    public let installedGroups: Set<ResourceModelGroup>
    public init(
        items: [ModelResourceFact], languageModels: [LocalModelFact]? = nil,
        speechOptions: [SpeechModelFact]? = nil
    ) {
        version = 1
        self.items = items
        self.languageModels = languageModels
        self.speechOptions = speechOptions
        let ids = Set(items.filter { $0.phase == .installed }.map(\.id))
        var groups = Set(
            ResourceModelGroup.allCases.filter { $0 != .language && $0 != .decision && $0.isInstalled(in: ids) })
        if let languageModels {
            for model in languageModels where model.artifactID.map(ids.contains) == true {
                groups.insert(model.nativeDecision ? .decision : .language)
            }
        }
        installedGroups = groups
    }
    public func validate() throws {
        guard items.count <= 64, (languageModels?.count ?? 0) <= 32, (speechOptions?.count ?? 0) <= 32 else {
            throw ResourceInventoryError.capacityExceeded
        }
        guard version == 1, Set(items.map(\.id)).count == items.count else {
            throw ResourceInventoryError.invalidSnapshot
        }
        for item in items {
            guard !item.id.isEmpty, item.id.utf8.count <= 64, item.name.utf8.count <= 256,
                item.revision.utf8.count <= 512, item.license.utf8.count <= 512,
                (item.failure?.utf8.count ?? 0) <= 1024,
                item.bytes >= 0, item.installedBytes >= 0, item.completedBytes >= 0
            else { throw ResourceInventoryError.invalidSnapshot }
        }
    }
    public func encoded() throws -> String {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw ResourceInventoryError.capacityExceeded }
        return String(decoding: data, as: UTF8.self)
    }
    public static func decode(_ raw: String) throws -> Self {
        guard raw.utf8.count <= maximumBytes else { throw ResourceInventoryError.capacityExceeded }
        let value = try JSONDecoder().decode(Self.self, from: Data(raw.utf8))
        try value.validate()
        return value
    }
    public static func read(using capability: any ModelResourceInventoryCapability) async throws -> Self {
        try Task.checkCancellation()
        let items = try await capability.snapshotResources()
        try Task.checkCancellation()
        let value = try await Self(
            items: items, languageModels: capability.localLanguageModels(),
            speechOptions: capability.speechModelOptions())
        try value.validate()
        return value
    }
}
public protocol ModelResourceInventoryCapability: Sendable {
    func snapshotResources() async throws -> [ModelResourceFact]
    func localLanguageModels() async throws -> [LocalModelFact]
    func speechModelOptions() async throws -> [SpeechModelFact]
}

extension ModelResourceInventoryCapability {
    public func localLanguageModels() async throws -> [LocalModelFact] { [] }
    public func speechModelOptions() async throws -> [SpeechModelFact] { [] }
}

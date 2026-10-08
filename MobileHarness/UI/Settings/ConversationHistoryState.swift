import Foundation
import Observation

@MainActor @Observable
public final class ConversationHistoryState {
    public var archive: HistorySnapshot?
    public var status: String?
    public var isBusy = false
    public init() {}
}

@MainActor
public protocol ConversationHistoryControlling: AnyObject {
    func load() async
    func startNew()
    func summarize(_ id: UUID)
    func delete(_ id: UUID)
    func cancel()
    func preview(_ turn: HistoryTurn) -> String
    func imageData(_ id: UUID, for turnID: UUID) async throws -> Data?
}

public struct HistoryMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case system, user, assistant, tool }
    public let role: Role
    public let content: String
    public let toolCalls: [HistoryNativeToolCall]?
    public let toolCallID: String?
    public let imageReferences: [HistoryImageReference]?
    public init(role: Role, content: String, imageReferences: [HistoryImageReference] = []) {
        self.role = role
        self.content = content
        toolCalls = nil
        toolCallID = nil
        self.imageReferences = imageReferences.isEmpty ? nil : imageReferences
    }
}

public struct HistoryImageReference: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let mimeType: String
    public let byteCount: Int
    public init(id: UUID, mimeType: String, byteCount: Int) {
        self.id = id
        self.mimeType = mimeType
        self.byteCount = byteCount
    }
    public var isValid: Bool {
        ["image/jpeg", "image/png"].contains(mimeType) && byteCount > 0 && byteCount <= 4 * 1024 * 1024
    }
}

public struct HistoryNativeToolCall: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let argumentsJSON: String
}

public struct HistoryModelRequest: Codable, Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public let input: String
    public let requestJSON: String
    public let firstTokenAt: Date?
    public let fragments: [String]
    public let toolCalls: [HistoryToolCall]
    public let tokenUsage: HistoryTokenUsage?
    public let state: HistoryTurn.State
    public let finishReason: String?
    public let error: String?
}

public struct HistoryTokenUsage: Codable, Sendable, Equatable {
    public let input: Int
    public let generated: Int
    public let total: Int
    public init(input: Int, generated: Int, total: Int) {
        self.input = input
        self.generated = generated
        self.total = total
    }
}

public struct HistoryToolCall: Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case received, completed, failed, cancelled }
    public let id: UUID
    public let providerID: String
    public let name: String
    public let argumentsJSON: String
    public var state: State = .received
    public let output: String?
    public let error: String?
    public init(id: UUID, providerID: String, name: String, argumentsJSON: String) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.argumentsJSON = argumentsJSON
        output = nil
        error = nil
    }
}

public struct HistoryTurn: Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case generating, completed, failed, cancelled, interrupted }
    public let id: UUID
    public let date: Date
    public let user: String
    public let request: [HistoryMessage]
    public let model: String
    public let maximumOutputTokens: Int?
    public let temperature: Double
    // Optional additions keep version-1 records readable without migration.
    public let modelRequests: [HistoryModelRequest]?
    public let firstTokenAt: Date?
    public let requestJSON: String?
    public let ownerInputID: UUID?
    public let isReACT: Bool?
    public let generationMetadataAvailable: Bool?
    public let continuationRequests: [String]?
    public let toolDefinitions: [String]?
    public let toolCalls: [HistoryToolCall]?
    public let tokenUsage: HistoryTokenUsage?
    public var fragments: [String] = []
    public var state: State = .generating
    public let finishReason: String?
    public let error: String?
    public let executionError: String?
    public var raw: String { fragments.joined() }
}

public struct HistoryConversation: Codable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let archivedAt: Date?
    public let summaryTitle: String?
    public let titleError: String?
    public var turns: [HistoryTurn] = []
    public init() {
        id = UUID()
        createdAt = Date()
        archivedAt = nil
        summaryTitle = nil
        titleError = nil
    }
}

public struct HistorySnapshot: Codable, Sendable {
    public let version: Int
    public let current: HistoryConversation
    public let past: [HistoryConversation]
    public init() {
        version = 1
        current = HistoryConversation()
        past = []
    }
}

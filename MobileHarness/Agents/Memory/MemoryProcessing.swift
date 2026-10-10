import AgentCore
import Foundation
import ModelKit
import StorageChat

// MARK: - State

public struct MemoryContextState: AgentChatContextState {
    public static let agentID = AgentID.memory
    public static let configurationName = "Memory"
    public static func runtimeCapabilities(_ capabilities: CapabilityRegistry) throws -> CapabilityRegistry {
        try AgentChatWorker<Self>.runtimeCapabilities(capabilities)
    }
    public static func preprocess(_ input: AgentInput, state: Self) throws -> SignalDisposition {
        try MemorySignalPreprocessor().classify(input, state: state)
    }
    public static let requiresParentCommit = true
    public static func systemPrompt(_ capabilities: CapabilityRegistry) throws -> String {
        "You own Memory tasks. Use only granted functions. Plain text is spoken and displayed automatically. Never claim success before actual feedback. Report progress/questions and completion to the requester using send, preserving task identity. UI deletion requires existing explicit confirmation; do not invent confirmation.\n"
            + (try CapabilityContextBuilder.build(capabilities))
    }
    public var chatSchemaVersion = 1
    public var history = ConversationArchive()
    public var historyImported = false
    public var admissionSequence: UInt64 = 0
    public var taskViews: [UUID: AgentTaskView]?

    public var pendingRequestIDs: [UUID] = []
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case pendingRequestIDs, history, historyImported, admissionSequence, taskViews, chatSchemaVersion
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pendingRequestIDs = try values.decode([UUID].self, forKey: .pendingRequestIDs)
        let hasChat = [.history, .historyImported, .admissionSequence, .taskViews, .chatSchemaVersion].contains {
            values.contains($0)
        }
        if hasChat {
            chatSchemaVersion =
                values.contains(.chatSchemaVersion) ? try values.decode(Int.self, forKey: .chatSchemaVersion) : 1
            guard chatSchemaVersion == 1 else { throw CommunicationError.invalidPayload }
            history = try values.decode(ConversationArchive.self, forKey: .history)
            historyImported = try values.decode(Bool.self, forKey: .historyImported)
            admissionSequence = try values.decode(UInt64.self, forKey: .admissionSequence)
            taskViews = try values.decodeIfPresent([UUID: AgentTaskView].self, forKey: .taskViews)
        }
    }

    public func validateContextState() throws {
        guard chatSchemaVersion == 1 else { throw CommunicationError.invalidPayload }
        try validateChatState()
        guard pendingRequestIDs.count <= 1 else { throw CommunicationError.invalidPayload }
    }
    public mutating func recoverInterruptedWork() {
        recoverChatState()
        pendingRequestIDs.removeAll()
    }
}

// MARK: - Signal preprocessing

public struct MemorySignalPreprocessor: SignalPreprocessor {
    public static let outputCapacity = 256

    public init() {}
    public func classify(_ input: AgentInput, state: MemoryContextState) throws -> SignalDisposition {
        guard !input.metadata.expired else { throw CommunicationError.expired }
        switch input.payload {
        case .communicationReceipt, .actionResult, .toolResult, .roundResult: return .feedback
        case .text: return .enqueue(priority: 0)
        case .observation: return .enqueue(priority: 0)
        default: throw CommunicationError.invalidPayload
        }
    }
}

// MARK: - Context building

public struct MemoryContextBuilder: ContextBuilder {
    public struct Request: Sendable {
        public let input: AgentInput
        public let state: MemoryContextState
        public let batch: SignalBatch
    }
    public init() {}
    public func build(state: AgentDecisionContext<MemoryContextState>, batch: SignalBatch) throws -> Request {
        let input = try state.selected(by: batch)
        return Request(input: input, state: state.snapshot.state, batch: batch)
    }
}

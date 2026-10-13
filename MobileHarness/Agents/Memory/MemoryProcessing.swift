import AgentCore
import Foundation

// MARK: - State

public struct MemoryContextState: AgentTaskContextState {
    public static let agentID = AgentID.memory
    public static let configurationName = "Memory"

    public static func preprocess(_ input: AgentInput, state: Self) throws -> SignalDisposition {
        try MemorySignalPreprocessor().classify(input, state: state)
    }

    public var taskViews: [UUID: AgentTaskView]?

    public var pendingRequestIDs: [UUID] = []
    public init() {}
    public func validateContextState() throws {
        try validateTaskState()
        guard pendingRequestIDs.count <= 1 else { throw CommunicationError.invalidPayload }
    }
    public mutating func recoverInterruptedWork() {
        recoverTaskState()
        pendingRequestIDs.removeAll()
    }
}

// MARK: - Signal preprocessing

public struct MemorySignalPreprocessor: SignalPreprocessor {
    public static let outputCapacity = 256
    static let evidenceCapacity = 4096

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

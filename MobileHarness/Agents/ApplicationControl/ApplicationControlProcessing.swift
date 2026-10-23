import AgentCore
import Foundation
import StorageCore

// MARK: - State

public struct ApplicationControlContextState: AgentTaskContextState {
    public static let agentID = AgentID.applicationControl
    public static let configurationName = "ApplicationControl"

    public static func preprocess(_ input: AgentInput, state: Self) throws -> SignalDisposition {
        try ApplicationControlSignalPreprocessor().classify(input, state: state)
    }

    public var taskViews: [String: AgentTaskView]?

    public var pendingCallIDs: [String] = []
    public var environmentContracts: [String] = []
    public init() {}
    public func validateContextState() throws {
        try validateTaskState()
        guard pendingCallIDs.count <= 32, environmentContracts.count <= 32 else {
            throw CommunicationError.invalidPayload
        }
    }
    public mutating func recoverInterruptedWork() {
        recoverTaskState()
        pendingCallIDs.removeAll()
    }
}

// MARK: - Signal preprocessing

public struct ApplicationControlSignalPreprocessor: SignalPreprocessor {
    public static let inputCapacity = 32
    public static let outputCapacity = 256
    static let evidenceCapacity = 4096

    public init() {}
    public func classify(_ input: AgentInput, state: ApplicationControlContextState) throws -> SignalDisposition {
        guard !input.metadata.expired else { throw CommunicationError.expired }
        switch input.payload {
        case .communicationReceipt, .actionResult, .toolResult, .roundResult: return .feedback
        case .text: return .enqueue(priority: 0)
        case .observation(let message):
            return message.contract == "app.environment" ? .updateState : .enqueue(priority: 0)
        default: throw CommunicationError.invalidPayload
        }
    }
}

// MARK: - Context building

public struct ApplicationControlContextBuilder: ContextBuilder {
    public struct Request: Sendable {
        public let input: AgentInput
        public let state: ApplicationControlContextState
        public let batch: SignalBatch
    }
    public init() {}
    public func build(state: AgentDecisionContext<ApplicationControlContextState>, batch: SignalBatch) throws -> Request
    {
        let input = try state.selected(by: batch)
        return Request(input: input, state: state.snapshot.state, batch: batch)
    }
}

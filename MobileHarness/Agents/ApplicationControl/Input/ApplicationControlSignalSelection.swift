import AgentCore
import Foundation
import StorageCore

public struct ApplicationControlSignalPreprocessor: SignalPreprocessor {
    public static let inputCapacity = 32
    public static let outputCapacity = 256
    static let evidenceCapacity = 4096

    public init() {}
    public func classify(_ input: AgentInput, state: ApplicationControlContextState) throws -> SignalDisposition {
        guard !input.metadata.expired else { throw CommunicationError.expired }
        switch input.payload {
        case .toolResult: return .feedback
        case .text: return .enqueue(priority: 0)
        case .observation(let message):
            return message.contract == "app.environment" ? .updateState : .enqueue(priority: 0)
        default: throw CommunicationError.invalidPayload
        }
    }
}

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

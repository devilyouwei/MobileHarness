import AgentCore
import Foundation
import StorageCore

public struct CameraTransactionSignalPreprocessor: SignalPreprocessor {
    public static let outputCapacity = 256
    static let evidenceCapacity = 4096

    public init() {}
    public func classify(_ input: AgentInput, state: CameraTransactionContextState) throws -> SignalDisposition {
        guard !input.metadata.expired else { throw CommunicationError.expired }
        switch input.payload {
        case .toolResult: return .feedback
        case .text: return .enqueue(priority: 0)
        case .observation(let message):
            if message.contract == CameraStateObservation.contract { return .replaceLatest(key: "camera") }
            return .enqueue(priority: 0)
        default: throw HarnessError.unsupportedInput
        }
    }
}

public struct CameraTransactionContextBuilder: ContextBuilder {
    public struct Request: Sendable {
        public let input: AgentInput
        public let state: CameraTransactionContextState
        public let batch: SignalBatch
    }
    public init() {}
    public func build(state: AgentDecisionContext<CameraTransactionContextState>, batch: SignalBatch) throws -> Request
    {
        let input = try state.selected(by: batch)
        return Request(input: input, state: state.snapshot.state, batch: batch)
    }
}

import AgentCore
import Foundation
import ModelKit

// MARK: - State

public struct SpeechSynthesisContextState: AgentContextState {
    public var activeAudioID: UUID?
    public var pendingAudioIDs: [UUID] = []
    public init() {}
    public func validateContextState() throws {
        guard pendingAudioIDs.count <= 32 else { throw CommunicationError.invalidPayload }
    }
    public mutating func recoverInterruptedWork() {
        activeAudioID = nil
        pendingAudioIDs.removeAll()
    }
}

// MARK: - Signal preprocessing

public struct SpeechSynthesisSignalPreprocessor: SignalPreprocessor {
    public static let evidenceCapacity = 256
    public static let inputCapacity = 32
    public static let outputCapacity = 1

    public init() {}
    public func classify(_ input: AgentInput, state: SpeechSynthesisContextState) throws -> SignalDisposition {
        guard !input.metadata.expired else { throw CommunicationError.expired }
        switch input.payload {
        case .communicationReceipt, .actionResult, .toolResult, .roundResult: return .feedback
        case .observation(let message): return message.contract == "speech.cancel" ? .control : .enqueue(priority: 0)
        default: throw HarnessError.unsupportedInput
        }
    }
}

// MARK: - Context building

public struct SpeechSynthesisContextBuilder: ContextBuilder {
    public struct Request: Sendable {
        public let input: AgentInput
        public let state: SpeechSynthesisContextState
        public let batch: SignalBatch
        public func inferenceRequest() throws -> SpeechSynthesisRequest {
            guard case .speechSynthesis(let request)? = input.payload.perception else {
                throw HarnessError.unsupportedInput
            }
            try request.validate()
            return try SpeechSynthesisRequest(
                text: request.text, locale: request.locale,
                context: InferenceContext(requestID: request.audioID, scopeID: input.sessionID))
        }
    }
    public init() {}
    public func build(state: AgentDecisionContext<SpeechSynthesisContextState>, batch: SignalBatch) throws -> Request {
        let input = try state.selected(by: batch)
        return Request(input: input, state: state.snapshot.state, batch: batch)
    }
}

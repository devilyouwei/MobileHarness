import AgentCore
import Foundation
import StorageCore

// MARK: - State

public struct SpeechPerceptionContextState: AgentContextState {
    public var phase = "listening"
    public var utteranceCount: UInt64 = 0
    public init() {}
    public func validateContextState() throws {
        guard SpeechPhase(rawValue: phase) != nil else { throw CommunicationError.invalidPayload }
    }
    public mutating func recoverInterruptedWork() {
        phase = "listening"
    }
}

// MARK: - Signal preprocessing

public struct SpeechPerceptionSignalPreprocessor: SignalPreprocessor {
    public static let evidenceCapacity = 256
    public static let outputCapacity = 32

    public init() {}
    public func classify(_ input: AgentInput, state: SpeechPerceptionContextState) throws -> SignalDisposition {
        guard !input.metadata.expired else { throw CommunicationError.expired }
        switch input.payload {
        case .actionResult: return .feedback
        case .observation(let message)
        where [ListeningIntent.contract, SpeechCaptureEnded.contract].contains(message.contract):
            return .control
        default: throw HarnessError.unsupportedInput
        }
    }
}

// MARK: - Context building

public struct SpeechPerceptionContextBuilder: ContextBuilder {
    public struct Request: Sendable {
        public let input: AgentInput
        public let state: SpeechPerceptionContextState
        public let batch: SignalBatch
    }
    public init() {}
    public func build(state: AgentDecisionContext<SpeechPerceptionContextState>, batch: SignalBatch) throws -> Request {
        let input = try state.selected(by: batch)
        return Request(input: input, state: state.snapshot.state, batch: batch)
    }
}

// MARK: - Listening policy

enum SpeechPhase: String, Codable, Sendable { case listening, speaking, processing, empty }

/// Capture consent and the current native route capability.
struct SpeechListeningPolicy {
    var enabled = false
    var revision: UInt64 = 0
    var fullDuplex = false
}

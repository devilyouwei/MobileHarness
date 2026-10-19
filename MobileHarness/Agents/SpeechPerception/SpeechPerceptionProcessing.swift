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
    public static let inputCapacity = 4096
    public static let maximumQueuedSamples = 8_388_608
    public static let maximumQueuedDuration: TimeInterval = 30
    public static let outputCapacity = 32

    public init() {}
    public func classify(_ input: AgentInput, state: SpeechPerceptionContextState) throws -> SignalDisposition {
        guard !input.metadata.expired else { throw CommunicationError.expired }
        switch input.payload {
        case .actionResult, .toolResult, .roundResult: return .feedback
        case .audio: return .enqueue(priority: 0)
        case .observation(let message)
        where [ListeningIntent.contract, ReplyActivity.contract, SpeechCaptureEnded.contract].contains(message.contract):
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

/// Domain-owned consent and lifecycle-owned reply facts; unrelated streaming busy never closes listening.
struct SpeechListeningPolicy {
    struct Activity {
        var revision: UInt64
        var incarnation: String
        var occupied: Bool
    }
    var enabled = false
    var revision: UInt64 = 0
    var activities: [String: Activity] = [:]
    var pendingFinal: String?
    var paused: Bool { pendingFinal != nil || activities.values.contains { $0.occupied } }
    mutating func accept(_ value: ReplyActivity, source: String, incarnation: String) throws -> Bool {
        try value.validate()
        guard ["assistant", "photographer", "memory", "applicationControl"].contains(source) else {
            throw CommunicationError.unauthorized
        }
        guard activities[source]?.incarnation != incarnation || value.revision > (activities[source]?.revision ?? 0)
        else { return false }
        activities[source] = Activity(
            revision: value.revision, incarnation: incarnation, occupied: !value.inputs.isEmpty || !value.tasks.isEmpty)
        if source == "assistant", pendingFinal == value.acknowledgedRoot { pendingFinal = nil }
        return true
    }
}

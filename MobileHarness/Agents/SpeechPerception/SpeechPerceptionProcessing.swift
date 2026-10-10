import AgentCore
import Foundation

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
    public static let inputCapacity = 128
    public static let maximumQueuedSamples = 64000
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

/// Domain-owned consent and leased reply facts; unrelated streaming busy never closes listening.
struct SpeechListeningPolicy {
    struct Activity {
        var revision: UInt64
        var incarnation: UUID
        var occupied: Bool
        var deadline: ContinuousClock.Instant
    }
    var enabled = false
    var revision: UInt64 = 0
    var activities: [String: Activity] = [:]
    var pendingFinal: (root: UUID, deadline: ContinuousClock.Instant)?
    static let lease: Duration = .seconds(120)
    var paused: Bool { pendingFinal != nil || activities.values.contains { $0.occupied } }
    var deadline: ContinuousClock.Instant? {
        (activities.values.filter { $0.occupied }.map(\.deadline) + [pendingFinal?.deadline].compactMap { $0 }).min()
    }
    mutating func accept(_ value: ReplyActivity, source: String, incarnation: UUID) throws -> Bool {
        try value.validate()
        guard ["assistant", "photographer", "memory", "applicationControl"].contains(source) else {
            throw CommunicationError.unauthorized
        }
        guard activities[source]?.incarnation != incarnation || value.revision > (activities[source]?.revision ?? 0)
        else { return false }
        activities[source] = Activity(
            revision: value.revision, incarnation: incarnation, occupied: !value.inputs.isEmpty || !value.tasks.isEmpty,
            deadline: .now.advanced(by: Self.lease))
        if source == "assistant", pendingFinal?.root == value.acknowledgedRoot { pendingFinal = nil }
        return true
    }
    mutating func expire(at now: ContinuousClock.Instant) -> Bool {
        var changed = false
        if let pendingFinal, pendingFinal.deadline <= now {
            self.pendingFinal = nil
            changed = true
        }
        for key in activities.keys {
            if activities[key]!.occupied, activities[key]!.deadline <= now {
                activities[key]?.occupied = false
                changed = true
            }
        }
        return changed
    }
}

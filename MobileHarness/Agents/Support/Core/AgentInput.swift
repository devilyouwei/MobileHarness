import Foundation

/// Untrusted host content and causal hints. Only Gateway turns this into a Signal envelope.
public struct ExternalInputDraft: Sendable {
    public let id: String?
    public let sessionID: String
    public let payload: InputPayload
    public let source: String
    public let sequence: UInt64
    public let rootID: String?
    public let parentID: String?
    public let hops: Int
    public let deadline: ContinuousClock.Instant?
    public let turn: AgentTurn?
    public init(
        id: String? = nil, sessionID: String, payload: InputPayload, source: String,
        sequence: UInt64 = 0, rootID: String? = nil, parentID: String? = nil, hops: Int = 0,
        deadline: ContinuousClock.Instant? = nil, turn: AgentTurn? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.payload = payload
        self.source = source
        self.sequence = sequence
        self.rootID = rootID
        self.parentID = parentID
        self.hops = hops
        self.deadline = deadline
        self.turn = turn
    }
}

/// Domain-owned content adaptation; transport encoding is supplied by Gateway.
public protocol ExternalInputProviding: Sendable {
    func externalInput(sessionID: String, sequence: UInt64) throws -> ExternalInputDraft
}

/// Provenance is independent of payload meaning; Gateway entry points enforce authority.
public enum SignalOrigin: String, Codable, Sendable {
    case external, agent, runtime
}

public enum InputPayload: Sendable {
    case communicationReceipt(CommunicationReceipt)
    case text(String)
    case event(String)
    case toolResult(ToolResult)
    case actionResult(ActionResult)
    case roundResult(GenerationRoundResult)
    case activityEvent(ActivityEvent)
    case image(ImageInput)
    case audio(AudioInput)
    case observation(AgentMessage)
    public var kind: InputKind {
        switch self {
        case .communicationReceipt: .communicationReceipt
        case .audio: .audio
        case .observation: .observation
        case .image: .image
        case .text: .text
        case .event: .event
        case .toolResult: .toolResult
        case .actionResult: .actionResult
        case .roundResult: .roundResult
        case .activityEvent: .activityEvent
        }
    }
}

/// Session-local interaction identity; the producing workflow assigns its meaning and ordinal.
public struct AgentTurn: Codable, Sendable, Equatable {
    public let id: String
    public let ordinal: UInt64
    public init(id: String, ordinal: UInt64) {
        self.id = id
        self.ordinal = ordinal
    }
}

public struct AgentInput: Sendable {
    public let id: String
    public let sessionID: String
    public let metadata: InputMetadata
    public let payload: InputPayload
    public let turn: AgentTurn?
    public let taskScope: AgentTaskScope?
    public init(
        id: String, sessionID: String, payload: InputPayload, metadata: InputMetadata? = nil,
        turn: AgentTurn? = nil, taskScope: AgentTaskScope? = nil
    ) {
        self.turn = turn
        self.taskScope = taskScope
        self.id = id
        self.sessionID = sessionID
        self.payload = payload
        self.metadata = metadata ?? InputMetadata(payload: payload, rootID: id)
    }
}

public struct InputMetadata: Sendable {
    public let origin: SignalOrigin
    public let contract: String
    public let version: Int
    public let topic: String
    public let source: String
    public let incarnation: String?
    public let capturedAt: TimeInterval
    public let sequence: UInt64
    public let rootID: String
    public let parentID: String?
    public let hops: Int
    public let deadline: ContinuousClock.Instant?
    public init(
        payload: InputPayload, source: String? = nil, incarnation: String? = nil, origin: SignalOrigin = .external,
        capturedAt: TimeInterval? = nil, sequence: UInt64 = 0, rootID: String,
        parentID: String? = nil, hops: Int = 0, deadline: ContinuousClock.Instant? = nil
    ) {
        let contract: String
        var defaultSource = "runtime"
        switch payload {
        case .communicationReceipt: contract = "communication.receipt"
        case .text:
            contract = "user.text"
            defaultSource = "user"
        case .event: contract = "runtime.event"
        case .toolResult: contract = "tool.result"
        case .actionResult: contract = "action.result"
        case .roundResult: contract = "generation.round.result"
        case .activityEvent: contract = "activity.event"
        case .audio:
            contract = "media.audio"

        case .image:
            contract = "media.image"

        case .observation(let observation):
            contract = observation.contract
        }
        self.origin = origin
        self.contract = contract
        version = 1
        topic = contract
        self.source = source ?? defaultSource
        self.incarnation = incarnation
        self.capturedAt = capturedAt ?? ProcessInfo.processInfo.systemUptime
        self.sequence = sequence
        self.rootID = rootID
        self.parentID = parentID
        self.hops = hops
        self.deadline = deadline
    }
    public var expired: Bool { deadline.map { ContinuousClock.now >= $0 } ?? false }
}

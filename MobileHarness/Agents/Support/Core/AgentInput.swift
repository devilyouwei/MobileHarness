import Foundation

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
    public let id: UUID
    public let ordinal: UInt64
    public init(id: UUID = UUID(), ordinal: UInt64) {
        self.id = id
        self.ordinal = ordinal
    }
}

public struct AgentInput: Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let metadata: InputMetadata
    public let payload: InputPayload
    public let turn: AgentTurn?
    public let taskScope: AgentTaskScope?
    public init(
        id: UUID = UUID(), sessionID: UUID, payload: InputPayload, metadata: InputMetadata? = nil,
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
    public let incarnation: UUID?
    public let capturedAt: TimeInterval
    public let sequence: UInt64
    public let rootID: UUID
    public let parentID: UUID?
    public let hops: Int
    public let deadline: ContinuousClock.Instant
    public init(
        payload: InputPayload, source: String? = nil, incarnation: UUID? = nil, origin: SignalOrigin = .external,
        capturedAt: TimeInterval? = nil, sequence: UInt64 = 0, rootID: UUID = UUID(),
        parentID: UUID? = nil, hops: Int = 0, deadline: ContinuousClock.Instant? = nil
    ) {
        let contract: String
        var defaultSource = "runtime"
        let lifetime: Double = 10
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
        self.deadline = min(deadline ?? .now.advanced(by: .seconds(lifetime)), .now.advanced(by: .seconds(60)))
    }
    public var expired: Bool { ContinuousClock.now >= deadline }
}

import Foundation

public enum InputPayload: Sendable {
    case text(String)
    case event(String)
    case toolResult(ToolResult)
    case image(ImageInput)
    case audio(AudioInput)
    case observation(PerceptionObservation)
    public var kind: InputKind {
        switch self {
        case .audio: .audio
        case .observation: .observation
        case .image: .image
        case .text: .text
        case .event: .event
        case .toolResult: .toolResult
        }
    }
}

/// Session-local utterance identity, assigned once at first confirmed speech onset.
public struct ConversationTurn: Sendable, Equatable {
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
    public let turn: ConversationTurn?
    public init(
        id: UUID = UUID(), sessionID: UUID, payload: InputPayload, metadata: InputMetadata? = nil,
        turn: ConversationTurn? = nil
    ) {
        self.turn = turn
        self.id = id
        self.sessionID = sessionID
        self.payload = payload
        self.metadata = metadata ?? InputMetadata(payload: payload, rootID: id)
    }
}

public struct InputMetadata: Sendable {
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
        payload: InputPayload, source: String? = nil, incarnation: UUID? = nil,
        capturedAt: TimeInterval? = nil, sequence: UInt64 = 0, rootID: UUID = UUID(),
        parentID: UUID? = nil, hops: Int = 0, deadline: ContinuousClock.Instant? = nil
    ) {
        let contract: String
        var defaultSource = "runtime"
        var lifetime: Double = 10
        switch payload {
        case .text:
            contract = "user.text"
            defaultSource = "user"
        case .event: contract = "runtime.event"
        case .toolResult: contract = "tool.result"
        case .audio:
            contract = "media.audio"
            defaultSource = "phone.microphone"
            lifetime = 60
        case .image:
            contract = "media.image"
            defaultSource = "phone.camera"
            lifetime = 1
        case .observation(let observation):
            contract = observation.contract
            if contract == "vision.pose" { lifetime = 1 }
            if contract == "speech.partial" { lifetime = 2 }
        }
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

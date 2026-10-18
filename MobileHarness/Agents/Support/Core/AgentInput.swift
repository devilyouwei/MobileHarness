import Foundation

/// Passive technical failure evidence, never an execution result or a request to recover hardware.
public struct ContainerFailureEvent: Codable, Sendable, Equatable, Identifiable {
    public enum Phase: String, Codable, Sendable { case operation, startup, foreground, shutdown, cleanup, runtime }
    public static let contract = "container.failure"
    public static let source = "runtime"
    public let id: String
    public let scopeID: String
    public let module: String
    public let component: String
    public let operation: String
    public let phase: Phase
    public let code: String
    public let message: String
    public var occurrences: UInt64
    public var lastOccurred: Date
    public init(
        id: String = UUID().uuidString, scopeID: String, module: String, component: String, operation: String,
        phase: Phase, code: String, message: String, occurrences: UInt64 = 1, lastOccurred: Date = Date()
    ) {
        self.id = id
        self.scopeID = scopeID
        self.module = module
        self.component = component
        self.operation = operation
        self.phase = phase
        self.code = code
        self.message = message
        self.occurrences = occurrences
        self.lastOccurred = lastOccurred
    }
    public func validate() throws {
        guard [id, scopeID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
            !module.isEmpty, module.utf8.count <= 64,
            [component, operation].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
            !code.isEmpty, code.utf8.count <= 128, !message.isEmpty, message.utf8.count <= 2048,
            occurrences > 0, lastOccurred.timeIntervalSince1970.isFinite
        else { throw CommunicationError.invalidPayload }
    }
}

/// Technical runtime evidence; presentation policy belongs to ApplicationControl, not this value.
public struct RuntimeFailureEvent: Codable, Sendable, Equatable, Identifiable {
    public static let contract = "runtime.failure"
    public static let source = "runtime"
    public let id: String
    public let sourceAgent: String
    public let title: String
    public let message: String
    public let time: Date
    public let failureCode: String?
    public let sessionID: String?
    public let inputID: String?
    public let roundID: String?
    public let category: String?
    public let workerID: String?
    public let callID: String?
    public init(
        id: String = UUID().uuidString, source: String, title: String, message: String, time: Date = Date(),
        failureCode: String? = nil, sessionID: String? = nil, inputID: String? = nil, roundID: String? = nil,
        category: String? = nil, workerID: String? = nil, callID: String? = nil
    ) {
        self.id = id
        sourceAgent = source
        self.title = String(title.prefix(128))
        self.message = String(message.prefix(2048))
        self.time = time
        self.failureCode = failureCode
        self.sessionID = sessionID
        self.inputID = inputID
        self.roundID = roundID
        self.category = category
        self.workerID = workerID
        self.callID = callID
    }
    public init(_ record: OutputFailureRecord) {
        self.init(
            id: record.id, source: record.source.rawValue, title: record.title, message: record.message,
            time: record.time, failureCode: record.failureCode, sessionID: record.sessionID,
            inputID: record.inputID, roundID: record.roundID, category: record.diagnostic?.category.rawValue)
    }
    public func validate() throws {
        guard !id.isEmpty, id.utf8.count <= 128, !sourceAgent.isEmpty, sourceAgent.utf8.count <= 64,
            !title.isEmpty, title.utf8.count <= 512, !message.isEmpty, message.utf8.count <= 8192,
            time.timeIntervalSince1970.isFinite,
            failureCode.map({ !$0.isEmpty && $0.utf8.count <= 64 }) ?? true,
            [sessionID, inputID, roundID, workerID, callID].allSatisfy({
                $0.map { !$0.isEmpty && $0.utf8.count <= 128 } ?? true
            }),
            category.map({ ["modelResponse", "modelTransport", "generation", "context", "runtime"].contains($0) })
                ?? true
        else { throw CommunicationError.invalidPayload }
    }
}

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

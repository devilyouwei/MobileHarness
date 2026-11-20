import AgentCore
import Foundation
import FunctionContracts
import StorageCore

/// Structured failure facts reported by a peer task executor.
public struct AgentTaskFailure: Codable, Sendable, Equatable {
    public let category: String
    public let code: String
    public let stage: String
    public let message: String
    public let details: [String: String]
    public let causes: [AgentTaskFailure]
    public init(
        category: String, code: String, stage: String, message: String,
        details: [String: String] = [:], causes: [AgentTaskFailure] = []
    ) {
        self.category = category
        self.code = code
        self.stage = stage
        self.message = message
        self.details = details
        self.causes = causes
    }
}

/// Ordered peer task evidence carried by the authenticated task transport.
public struct AgentTaskEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case started, draftUpdated, recovering, userInput, inputAccepted, completed, declined, failed, cancelled

        var isMilestone: Bool { self == .draftUpdated || self == .recovering }
    }
    static let version = 1
    public let version: Int
    public let eventID: String
    public let sequence: UInt64
    public let kind: Kind
    public let goal: String?
    public let windowID: String?
    public let failure: AgentTaskFailure?
    public init(
        sequence: UInt64, kind: Kind, goal: String? = nil, windowID: String? = nil,
        failure: AgentTaskFailure? = nil, eventID: String = UUID().uuidString
    ) {
        version = Self.version
        self.eventID = eventID
        self.sequence = sequence
        self.kind = kind
        self.goal = goal
        self.windowID = windowID
        self.failure = failure
    }
    public func validate() throws {
        guard version == Self.version, UUID(uuidString: eventID) != nil, sequence > 0 else {
            throw CommunicationError.invalidPayload
        }
    }
}

/// Public task content, separate from private inference history and trusted UI commands.
public struct AgentTaskContent: Codable, Sendable, Equatable {
    public enum Stage: String, Codable, Sendable { case running, waitingUser, completed }
    public let text: String
    public let stage: Stage
    public let interactionID: String?
    public let artifactID: String?
    public let event: AgentTaskEvent?
    public init(
        text: String, stage: Stage = .running, interactionID: String? = nil, artifactID: String? = nil,
        event: AgentTaskEvent? = nil
    )
        throws
    {
        guard !text.isEmpty, text.utf8.count <= 4096,
            stage != .waitingUser || interactionID != nil
        else { throw CommunicationError.invalidPayload }
        try event?.validate()
        self.event = event
        self.text = text
        self.stage = stage
        self.interactionID = interactionID
        self.artifactID = artifactID
    }
    public static let contract = "agent.task"
    public func signal(_ kind: AgentTaskSignal.Kind, scope: AgentTaskScope, status: AgentTaskSignal.Status? = nil)
        throws -> AgentTaskSignal
    {
        return try AgentTaskSignal(
            kind: kind, scope: scope, businessContract: Self.contract,
            data: JSONEncoder().encode(self), status: status, id: event?.eventID)
    }
    public static func decode(_ signal: AgentTaskSignal) throws -> Self {
        guard signal.businessContract == contract else { throw CommunicationError.unsupportedContract }
        let content = try JSONDecoder().decode(Self.self, from: signal.data)
        return try Self(
            text: content.text, stage: content.stage,
            interactionID: content.interactionID, artifactID: content.artifactID, event: content.event)
    }
}

/// A peer report refers to either an incoming message or an admitted task.
public struct AgentTaskResponse: Codable, Sendable, Equatable {
    static let contract = AgentTaskSignal.responseContract

    struct Rejection: Codable, Sendable, Equatable {
        let eventID: String
        let messageID: String
        let sessionID: String
        let text: String
    }

    public let signal: AgentTaskSignal?
    let rejection: Rejection?

    init(_ signal: AgentTaskSignal) throws {
        self.signal = signal
        rejection = nil
        try validate()
    }

    init(rejecting messageID: String, sessionID: String, text: String) throws {
        signal = nil
        rejection = Rejection(eventID: UUID().uuidString, messageID: messageID, sessionID: sessionID, text: text)
        try validate()
    }

    func validate() throws {
        if let rejection, signal == nil {
            guard UUID(uuidString: rejection.eventID) != nil, UUID(uuidString: rejection.messageID) != nil,
                !rejection.sessionID.isEmpty, rejection.sessionID.utf8.count <= 128,
                !rejection.text.isEmpty, rejection.text.utf8.count <= 4096
            else { throw CommunicationError.invalidPayload }
            return
        }
        guard let signal, rejection == nil else { throw CommunicationError.invalidPayload }
        try signal.validate()
        let content = try AgentTaskContent.decode(signal)
        guard signal.scope.requester != signal.scope.executor, signal.scope.execution == .background,
            let event = content.event
        else { throw CommunicationError.invalidPayload }
        if signal.kind == .progress {
            guard [.started, .draftUpdated, .recovering, .userInput, .inputAccepted].contains(event.kind),
                event.kind == .userInput
                    ? content.stage == .waitingUser && content.interactionID != nil
                    : content.stage == .running && content.interactionID == nil
            else { throw CommunicationError.invalidPayload }
            return
        }
        guard signal.kind == .result, content.stage == .completed,
            (event.kind == .completed && signal.status == .succeeded)
                || ([.failed, .declined].contains(event.kind) && signal.status == .failed)
                || (event.kind == .cancelled && signal.status == .cancelled)
        else { throw CommunicationError.invalidPayload }
    }

    var message: AgentMessage { publication() }
    func publication(scope: String? = nil) -> AgentMessage {
        AgentMessage(
            contract: Self.contract, content: self, maximumBytes: 131072, task: signal,
            id: rejection?.eventID ?? signal?.id, eventScope: scope ?? signal?.scope.id ?? rejection?.messageID,
            eventOwner: signal?.scope.requester, validate: { try $0.validate() })
    }
}

struct AgentTaskFact: Codable, Sendable {
    let kind: AgentTaskEvent.Kind
    let text: String
    let receivedAt: Date
}

public struct AgentTaskView: Codable, Sendable {
    public let scope: AgentTaskScope
    public var stage: AgentTaskContent.Stage
    public var text: String
    public var interactionID: String?
    public var artifactID: String?
    public var goal: String?
    public var skills: [String]?
    public var createdAt: Date?
    public var terminal: Bool
    public var event: AgentTaskEvent?
    public var originDialog: String?
    var facts: [AgentTaskFact]?
    public init(scope: AgentTaskScope, content: AgentTaskContent, terminal: Bool = false) {
        self.scope = scope
        event = content.event
        stage = content.stage
        text = content.text
        interactionID = content.interactionID
        artifactID = content.artifactID
        self.terminal = terminal
    }

    mutating func retainFacts(from previous: Self?) {
        guard let event else { return }
        var retained = previous?.facts ?? []
        retained.append(.init(kind: event.kind, text: String(text.prefix(240)), receivedAt: Date()))
        facts = Array(retained.suffix(6))
    }
}

/// Only Assistant can forward typed UI intent; model communication cannot construct this payload.
public enum AgentFixedTaskInput {
    public static func unwrap(
        _ signal: AgentTaskSignal, input: AgentInput, executor: AgentID,
        decode: (AgentTaskSignal) throws -> AgentMessage
    ) throws -> AgentInput {
        guard signal.kind == .request || signal.kind == .input,
            signal.scope.executor == executor, input.taskScope == signal.scope,
            input.metadata.origin == .agent, input.metadata.source == signal.scope.requester.rawValue,
            input.metadata.incarnation != nil
        else { throw CommunicationError.unauthorized }
        let message = try decode(signal)
        try input.validate(message)
        let payload = InputPayload.observation(message)
        return AgentInput(
            id: input.metadata.rootID, sessionID: input.sessionID, payload: payload,
            metadata: InputMetadata(
                payload: payload, source: input.metadata.source,
                incarnation: input.metadata.incarnation, origin: input.metadata.origin,
                capturedAt: input.metadata.capturedAt, sequence: input.metadata.sequence,
                rootID: input.metadata.rootID, parentID: input.metadata.parentID, hops: input.metadata.hops,
                deadline: input.metadata.deadline), turn: input.turn, taskScope: signal.scope)
    }

    public static func cancellation(_ query: AgentTaskQuery, input: AgentInput) throws -> AgentInput {
        guard query.operation == .cancel, input.metadata.source == query.scope.requester.rawValue,
            input.metadata.origin == .agent, input.metadata.incarnation != nil,
            input.sessionID == query.scope.sessionID
        else { throw CommunicationError.unauthorized }
        let signal = try AgentTaskSignal(
            kind: .cancel, scope: query.scope, businessContract: "agent.task.control",
            data: Data((query.reason ?? "Cancelled").utf8), id: query.id)
        return AgentInput(
            id: input.id, sessionID: input.sessionID, payload: .observation(try signal.message()),
            metadata: input.metadata, turn: input.turn, taskScope: query.scope)
    }

    public static func isTrusted(_ input: AgentInput) -> Bool {
        input.metadata.origin == .agent && input.metadata.incarnation != nil
            && input.metadata.source == input.taskScope?.requester.rawValue
            && input.taskScope?.sessionID == input.sessionID
    }
}

/// Explicit user reply targets an existing question; runtime ownership is not user-supplied.
public struct AgentTaskInputIntent: Codable, Sendable, Equatable {
    public static let contract = "agent.userInput"
    public let taskID: String
    public let interactionID: String
    public let artifactID: String?
    public let text: String
    public init(taskID: String, interactionID: String, artifactID: String? = nil, text: String) throws {
        guard !text.isEmpty, text.utf8.count <= 4096,
            [taskID, interactionID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
            artifactID.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true
        else { throw CommunicationError.invalidPayload }
        self.taskID = taskID
        self.interactionID = interactionID
        self.artifactID = artifactID
        self.text = text
    }
    public func input(sessionID: String) throws -> AgentInput {
        let payload = InputPayload.observation(
            AgentMessage(
                contract: Self.contract, content: self, maximumBytes: 16_384,
                validate: { value in
                    _ = try Self(
                        taskID: value.taskID, interactionID: value.interactionID, artifactID: value.artifactID,
                        text: value.text)
                }))
        return ProcessingContext(sessionID: sessionID, source: "user").input(payload)
    }
}

/// Input-only validation shared by local and remote task requests.
enum AgentTaskSkillIDs {
    static func decode(_ text: String?) throws -> [String] {
        guard let text else { return [] }
        guard text.utf8.count <= 4096, let ids = try? JSONDecoder().decode([String].self, from: Data(text.utf8)),
            ids.count <= 16, ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }), Set(ids).count == ids.count
        else { throw CommunicationError.invalidPayload }
        return ids
    }
}

/// Implemented peer task adapters, shared by discovery and execution admission.
/// A peer receives `AgentTaskRequest` messages and reports only through `AgentTaskResponse`.
/// A resource description or a communication grant alone cannot create an adapter.
enum AgentTaskMessaging {
    private static let peers: Set<AgentID> = [.writer]

    static func isPeer(_ executor: AgentID) -> Bool { peers.contains(executor) }

    static func permits(
        target: AgentID, requester: AgentID, communication: CommunicationDeclaration
    ) -> Bool {
        // Public protocol support belongs to the target capability catalog, never a sender/target pair.
        guard !requester.rawValue.isEmpty && requester.rawValue.utf8.count <= 64 else { return false }
        return AgentContracts.requestImplementations[target]?.contains {
            $0.protocolID == AgentTaskRequest.contract && $0.acceptsTextSubmission
        } ?? false
    }
}

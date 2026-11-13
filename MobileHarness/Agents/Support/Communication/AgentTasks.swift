import AgentCore
import Foundation
import FunctionContracts
import StorageCore

/// A peer message may carry a reply address captured by the runtime.
struct AgentTaskRequest: Codable, Equatable, Sendable {
    static let contract = "agent.task.request"
    let id: String
    let text: String
    let replyTo: String?
    let interactionID: String?

    init(id: String = UUID().uuidString, text: String, replyTo: String? = nil, interactionID: String? = nil) {
        self.id = id
        self.text = text
        self.replyTo = replyTo
        self.interactionID = interactionID
    }

    func validate() throws {
        guard UUID(uuidString: id) != nil, text.utf8.count <= 4096,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            (replyTo == nil) == (interactionID == nil),
            replyTo.map({ UUID(uuidString: $0) != nil && $0 != id }) ?? true,
            interactionID.map({ UUID(uuidString: $0) != nil }) ?? true
        else { throw CommunicationError.invalidPayload }
    }

    var message: AgentMessage {
        AgentMessage(contract: Self.contract, content: self, maximumBytes: 32768, validate: { try $0.validate() })
    }
}

/// Writer-owned failure facts; persistence and presentation adapters project this value explicitly.
public struct WriterFailureDiagnostic: Codable, Sendable, Equatable {
    public let category: String
    public let code: String
    public let stage: String
    public let message: String
    public let details: [String: String]
    public let causes: [WriterFailureDiagnostic]
    public init(
        category: String, code: String, stage: String, message: String,
        details: [String: String] = [:], causes: [WriterFailureDiagnostic] = []
    ) {
        self.category = category
        self.code = code
        self.stage = stage
        self.message = message
        self.details = details
        self.causes = causes
    }
}

/// Writer business evidence carried by the authenticated task transport.
public struct WriterDelegationEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case started, draftUpdated, recovering, userInput, inputAccepted, completed, declined, failed, cancelled

        var isMilestone: Bool { self == .draftUpdated || self == .recovering }
    }
    public let version: Int
    public let eventID: String
    public let sequence: UInt64
    public let kind: Kind
    public let workspaceID: String?
    public let goal: String?
    public let windowID: String?
    public let delegateID: String?
    public let failure: WriterFailureDiagnostic?
    public init(
        sequence: UInt64, kind: Kind, workspaceID: String? = nil, goal: String? = nil, windowID: String? = nil,
        delegateID: String? = nil, failure: WriterFailureDiagnostic? = nil,
        eventID: String = UUID().uuidString
    ) {
        version = 3
        self.eventID = eventID
        self.sequence = sequence
        self.kind = kind
        self.goal = goal
        self.workspaceID = workspaceID
        self.windowID = windowID
        self.delegateID = delegateID
        self.failure = failure
    }
    public func validate() throws {
        guard version == 3, UUID(uuidString: eventID) != nil, sequence > 0,
            workspaceID.map({ WorkspaceID(rawValue: $0) != nil }) ?? true,
            delegateID.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true
        else {
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
    public let writerEvent: WriterDelegationEvent?
    public init(
        text: String, stage: Stage = .running, interactionID: String? = nil, artifactID: String? = nil,
        writerEvent: WriterDelegationEvent? = nil
    )
        throws
    {
        guard !text.isEmpty, text.utf8.count <= 4096,
            stage != .waitingUser || interactionID != nil
        else { throw CommunicationError.invalidPayload }
        try writerEvent?.validate()
        self.writerEvent = writerEvent
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
            data: JSONEncoder().encode(self), status: status)
    }
    public static func decode(_ signal: AgentTaskSignal) throws -> Self {
        guard signal.businessContract == contract else { throw CommunicationError.unsupportedContract }
        let content = try JSONDecoder().decode(Self.self, from: signal.data)
        return try Self(
            text: content.text, stage: content.stage,
            interactionID: content.interactionID, artifactID: content.artifactID, writerEvent: content.writerEvent)
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
            let event = content.writerEvent, event.delegateID == nil || event.delegateID == signal.scope.id
        else { throw CommunicationError.invalidPayload }
        if signal.kind == .progress {
            guard [.started, .draftUpdated, .recovering, .userInput, .inputAccepted].contains(event.kind),
                event.kind == .userInput
                    ? content.stage == .waitingUser && content.interactionID != nil
                    : content.stage == .running && content.interactionID == nil
            else { throw CommunicationError.invalidPayload }
            return
        }
        guard signal.kind == .result, content.stage == .completed, event.delegateID == signal.scope.id,
            (event.kind == .completed && signal.status == .succeeded)
                || ([.failed, .declined].contains(event.kind) && signal.status == .failed)
                || (event.kind == .cancelled && signal.status == .cancelled)
        else { throw CommunicationError.invalidPayload }
    }

    var message: AgentMessage {
        AgentMessage(contract: Self.contract, content: self, maximumBytes: 131072, validate: { try $0.validate() })
    }
}

struct WriterContextFact: Codable, Sendable {
    let kind: WriterDelegationEvent.Kind
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
    public var writerEvent: WriterDelegationEvent?
    public var originDialog: String?
    var writerFacts: [WriterContextFact]?
    public init(scope: AgentTaskScope, content: AgentTaskContent, terminal: Bool = false) {
        self.scope = scope
        writerEvent = content.writerEvent
        stage = content.stage
        text = content.text
        interactionID = content.interactionID
        artifactID = content.artifactID
        self.terminal = terminal
    }

    mutating func retainWriterFacts(from previous: Self?) {
        guard let writerEvent else { return }
        var facts = previous?.writerFacts ?? []
        facts.append(.init(kind: writerEvent.kind, text: String(text.prefix(240)), receivedAt: Date()))
        writerFacts = Array(facts.suffix(6))
    }
}

/// Only Assistant can forward typed UI intent; model communication cannot construct this payload.
public enum AgentFixedTaskInput {
    public static func unwrap(
        _ signal: AgentTaskSignal, input: AgentInput, executor: AgentID,
        decode: (AgentTaskSignal) throws -> AgentMessage
    ) throws -> AgentInput {
        guard signal.kind == .request || signal.kind == .input, signal.scope.requester == .assistant,
            signal.scope.executor == executor, input.taskScope == signal.scope,
            input.metadata.origin == .agent, input.metadata.source == AgentID.assistant.rawValue,
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

    public static func isTrusted(_ input: AgentInput) -> Bool {
        input.metadata.origin == .agent && input.metadata.incarnation != nil
            && input.metadata.source == AgentID.assistant.rawValue
            && input.taskScope?.requester == .assistant && input.taskScope?.sessionID == input.sessionID
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

/// Implemented public task adapters, shared by discovery and execution admission.
/// A resource description or a communication grant alone cannot create an adapter.
enum AgentTaskMessaging {
    static func permits(
        target: AgentID, requester: AgentID, communication: CommunicationDeclaration
    ) -> Bool {
        requester == .assistant && target == .writer
            && communication.sends.contains {
                $0.contract == AgentTaskRequest.contract && $0.target == target.rawValue
            }
    }
}

/// Model registration metadata for the task communication protocol.
enum AgentTaskCommunication {
    /// Runtime-owned communication declaration; model exposure is selected only by Skills.
    static let sendDeclaration = ActionDeclaration(
        path: .init(domain: "Agent", module: "Communication", function: "send"),
        doc: "Send directed task communication to a declared target. Admission is not task completion.",
        parameters: [
            .init("target", description: "Declared target Agent ID"),
            .init("kind", description: "Declared task message kind"),
            .init("content", description: "Public task content"),
            .init(
                "taskID", required: false, description: "Existing task identity",
                constraints: "Omit for request. Required for input, cancel, progress, and result."),
            .init("artifactID", required: false, description: "Authorized artifact reference"),
        ])

}

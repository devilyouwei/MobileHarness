import AgentCore
import Foundation
import FunctionContracts
import StorageCore

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

/// Writer business evidence carried by the existing authenticated task transport.
public struct WriterRequestProgress: Codable, Sendable, Equatable {
    public let inputID: String
    public let number: Int
    public let phase: String
    public let attempt: Int
    public let path: String?
    public init(inputID: String, number: Int, phase: String, attempt: Int, path: String? = nil) {
        self.inputID = inputID
        self.number = number
        self.phase = phase
        self.attempt = attempt
        self.path = path
    }
}
public struct WriterTaskEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case started, progress, userInput, completed, failed, cancelled
    }
    public let version: Int
    public let eventID: String
    public let sequence: UInt64
    public let kind: Kind
    public let workspaceID: String?
    public let goal: String?
    public let windowID: String?
    public let taskID: String?
    public let delegateID: String?
    public let failure: WriterFailureDiagnostic?
    public let request: WriterRequestProgress?
    public init(
        sequence: UInt64, kind: Kind, workspaceID: String? = nil, goal: String? = nil, windowID: String? = nil,
        taskID: String? = nil,
        delegateID: String? = nil, failure: WriterFailureDiagnostic? = nil, request: WriterRequestProgress? = nil,
        eventID: String = UUID().uuidString
    ) {
        version = 2
        self.eventID = eventID
        self.sequence = sequence
        self.kind = kind
        self.goal = goal
        self.workspaceID = workspaceID
        self.windowID = windowID
        self.taskID = taskID
        self.delegateID = delegateID
        self.failure = failure
        self.request = request
    }
    public func validate() throws {
        if let request {
            guard request.number > 0, request.attempt > 0, !request.inputID.isEmpty, request.inputID.utf8.count <= 128,
                !request.phase.isEmpty
            else { throw CommunicationError.invalidPayload }
        }
        guard version == 2, UUID(uuidString: eventID) != nil, sequence > 0,
            [taskID, delegateID].allSatisfy({ $0.map { !$0.isEmpty && $0.utf8.count <= 128 } ?? true })
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
    public let writerEvent: WriterTaskEvent?
    public init(
        text: String, stage: Stage = .running, interactionID: String? = nil, artifactID: String? = nil,
        writerEvent: WriterTaskEvent? = nil
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
        try AgentTaskSignal(
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

/// A completed Writer fact outlives the execution grant. Gateway authenticates the role;
/// the Assistant validates its persisted task/run/event binding before admitting a reply.
public struct WriterTaskCompletion: Codable, Sendable, Equatable {
    public static let contract = "writer.completion"
    public let signal: AgentTaskSignal
    public init(_ signal: AgentTaskSignal) throws {
        self.signal = signal
        try validate()
    }
    public func validate() throws {
        try signal.validate()
        let content = try AgentTaskContent.decode(signal)
        guard signal.kind == .result, signal.scope.requester == .assistant, signal.scope.executor == .writer,
            signal.scope.execution == .background, content.stage == .completed, let event = content.writerEvent,
            event.delegateID == signal.scope.id,
            (event.kind == .completed && signal.status == .succeeded)
                || (event.kind == .failed && signal.status == .failed)
                || (event.kind == .cancelled && signal.status == .cancelled)
        else {
            throw CommunicationError.invalidPayload
        }
    }
    public var message: AgentMessage {
        AgentMessage(contract: Self.contract, content: self, maximumBytes: 131072, validate: { try $0.validate() })
    }
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
    public var businessTaskID: String?
    public var writerEvent: WriterTaskEvent?
    public var originDialog: String?
    public init(scope: AgentTaskScope, content: AgentTaskContent, terminal: Bool = false) {
        self.scope = scope
        writerEvent = content.writerEvent
        stage = content.stage
        text = content.text
        interactionID = content.interactionID
        artifactID = content.artifactID
        self.terminal = terminal
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

/// Validated background request; target capability declarations are injected by the host.
public struct AgentBackgroundTaskRequest: Sendable {
    public let goal: String
    public let skills: [String]
    public let target: AgentID
    public let businessContract: String
    public let data: Data
    public init(arguments: [String: String]) throws {
        let required: Set<String> = ["goal", "execution", "target", "businessContract", "payload"]
        guard required.isSubset(of: Set(arguments.keys)), Set(arguments.keys).isSubset(of: required.union(["skills"])),
            arguments["execution"] == "background", let goal = arguments["goal"],
            !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, goal.utf8.count <= 4096,
            let target = arguments["target"], !target.isEmpty, target.utf8.count <= 64,
            let contract = arguments["businessContract"], !contract.isEmpty, contract.utf8.count <= 64,
            let payload = arguments["payload"], payload.utf8.count <= 65_536,
            (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) != nil
        else { throw CommunicationError.invalidPayload }
        self.goal = goal
        self.skills = try AgentTaskSkillIDs.decode(arguments["skills"])
        self.target = AgentID(rawValue: target)
        self.businessContract = contract
        self.data = Data(payload.utf8)
    }
    public func signal(id: String, requester: AgentID, parent: String?, session: String) throws -> AgentTaskSignal {
        guard target != requester else { throw CommunicationError.unauthorized }
        return try AgentTaskSignal(
            kind: .request,
            scope: AgentTaskScope(
                id: id,
                parentID: parent, requester: requester, executor: target, sessionID: session, execution: .background),
            businessContract: businessContract, data: data, goal: goal, requestedSkills: skills)
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
enum AgentTaskDelegation {
    case writer
    var target: AgentID { .writer }
    var businessContract: String { "writer.author" }
    static func resolve(
        target: AgentID, requester: AgentID, communication: CommunicationDeclaration
    ) -> Self? {
        guard requester == .assistant, target == .writer,
            communication.sends.contains(where: { $0.contract == "task.request" && $0.target == target.rawValue })
        else { return nil }
        return .writer
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
            .init("taskID", required: false, description: "Existing task identity"),
            .init("artifactID", required: false, description: "Authorized artifact reference"),
            .init("businessContract", required: false, description: "Declared background business contract"),
            .init("payload", required: false, description: "Business input encoded as a JSON string"),
        ])

}

import AgentCore
import Foundation
import FunctionContracts

/// Public task content, separate from private inference history and trusted UI commands.
public struct AgentTaskContent: Codable, Sendable, Equatable {
    public enum Stage: String, Codable, Sendable { case running, waitingUser, completed }
    public let text: String
    public let stage: Stage
    public let interactionID: UUID?
    public let artifactID: UUID?
    public init(text: String, stage: Stage = .running, interactionID: UUID? = nil, artifactID: UUID? = nil) throws {
        guard !text.isEmpty, text.utf8.count <= 4096,
            stage != .waitingUser || interactionID != nil
        else { throw CommunicationError.invalidPayload }
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
            interactionID: content.interactionID, artifactID: content.artifactID)
    }
}

public struct AgentTaskView: Codable, Sendable {
    public let scope: AgentTaskScope
    public var stage: AgentTaskContent.Stage
    public var text: String
    public var interactionID: UUID?
    public var artifactID: UUID?
    public var goal: String?
    public var skills: [String]?
    public var createdAt: Date?
    public var terminal: Bool
    public init(scope: AgentTaskScope, content: AgentTaskContent, terminal: Bool = false) {
        self.scope = scope
        stage = content.stage
        text = content.text
        interactionID = content.interactionID
        artifactID = content.artifactID
        self.terminal = terminal
    }
}

/// Only Assistant can forward typed UI intent; model communication cannot construct this payload.
public enum AgentFixedTaskInput {
    public static func unwrap(_ signal: AgentTaskSignal, input: AgentInput, executor: AgentID) throws -> AgentInput {
        guard signal.kind == .request || signal.kind == .input, signal.scope.requester == .assistant,
            signal.scope.executor == executor, input.taskScope == signal.scope,
            input.metadata.origin == .agent, input.metadata.source == AgentID.assistant.rawValue,
            input.metadata.incarnation != nil
        else { throw CommunicationError.unauthorized }
        let message: AgentMessage
        switch (executor, signal.businessContract) {
        case (.photographer, PhotographerCameraIntent.contract):
            message = try JSONDecoder().decode(PhotographerCameraIntent.self, from: signal.data).message
        case (.memory, MemoryHistoryIntent.contract):
            let value = try JSONDecoder().decode(MemoryHistoryIntent.self, from: signal.data)
            if case .cancel = value { throw CommunicationError.unauthorized }
            message = AgentMessage(
                contract: signal.businessContract, content: value, maximumBytes: 512, validate: { _ in })
        case (.applicationControl, AppInteractionIntent.contract):
            let value = try JSONDecoder().decode(AppInteractionIntent.self, from: signal.data)
            message = AgentMessage(
                contract: signal.businessContract, content: value, maximumBytes: 2048, validate: { try $0.validate() })
        case (.applicationControl, ModelResourceIntent.contract):
            let value = try JSONDecoder().decode(ModelResourceIntent.self, from: signal.data)
            if case .retire = value { throw CommunicationError.unauthorized }
            message = AgentMessage(
                contract: signal.businessContract, content: value, maximumBytes: 2048, validate: { try $0.validate() })
        case (.applicationControl, ProviderSettingsIntent.contract):
            message = AgentMessage(
                contract: signal.businessContract,
                content: try JSONDecoder().decode(ProviderSettingsIntent.self, from: signal.data), maximumBytes: 512,
                validate: { _ in })
        case (.applicationControl, ProviderDiscoveryIntent.contract):
            message = AgentMessage(
                contract: signal.businessContract,
                content: try JSONDecoder().decode(ProviderDiscoveryIntent.self, from: signal.data), maximumBytes: 512,
                validate: { _ in })
        default: throw CommunicationError.unsupportedContract
        }
        _ = try message.validatedSize()
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
    public let taskID: UUID
    public let interactionID: UUID
    public let artifactID: UUID?
    public let text: String
    public init(taskID: UUID, interactionID: UUID, artifactID: UUID? = nil, text: String) throws {
        guard !text.isEmpty, text.utf8.count <= 4096 else { throw CommunicationError.invalidPayload }
        self.taskID = taskID
        self.interactionID = interactionID
        self.artifactID = artifactID
        self.text = text
    }
    public func input(sessionID: UUID) -> AgentInput {
        let id = UUID()
        let payload = InputPayload.observation(
            AgentMessage(
                contract: Self.contract, content: self, maximumBytes: 16_384,
                validate: { value in
                    _ = try Self(
                        taskID: value.taskID, interactionID: value.interactionID, artifactID: value.artifactID,
                        text: value.text)
                }))
        return AgentInput(
            id: id, sessionID: sessionID, payload: payload,
            metadata: InputMetadata(payload: payload, source: "user", rootID: id))
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
    public func signal(requester: AgentID, parent: UUID?, session: UUID) throws -> AgentTaskSignal {
        guard target != requester else { throw CommunicationError.unauthorized }
        return try AgentTaskSignal(
            kind: .request,
            scope: AgentTaskScope(
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

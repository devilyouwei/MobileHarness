import AgentCore
import Foundation

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

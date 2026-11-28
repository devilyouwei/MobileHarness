import AgentCore
import Foundation
import ModelKit
import StorageChat
import StorageCore
import StorageTasks

public struct AssistantContextState: AssistantChatState {
    public static let supportsSkills = true
    public static func sessionControl(_ message: AgentMessage) throws -> AssistantChatControl? {
        guard message.contract == AssistantSessionControl.contract else { return nil }
        guard let control = message.assistantControl else { throw CommunicationError.invalidPayload }
        return control == .cancelSession ? .close : .interrupt
    }
    public static let agentID = AgentID.assistant
    public static let configurationName = "Assistant"
    public static func runtimeCapabilities(_ capabilities: CapabilityRegistry) throws -> CapabilityRegistry {
        return try AssistantChatWorker<Self>.chatRuntimeCapabilities(capabilities).adding(
            internalTools: [
                .init(path: "UI.Island.present", required: ["activityID", "revision", "content"]),
                .init(path: "UI.Island.end", required: ["activityID", "revision"]),
            ], controls: try AssistantControls.registrations, controlGuidance: try AssistantControls.guidance)
    }
    public static let acceptsDirectedUserInput = true
    public static let commitDependentTargets: Set<AgentID> = [.memory]
    public var skillState: AgentTaskSkillState?
    public var variables = AgentStateVariables()
    public var listeningWakeCondition: String?
    public var taskViews: [String: AgentTaskView]?
    public var history = AssistantArchive()
    public var admissionSequence: UInt64 = 0
    public init() {}
    /// The variables as the model sees them: stored ones plus `task`, which the active goal record owns.
    public func visibleVariables(session: String? = nil) -> AgentStateVariables {
        let active = skillState?.tasks.first {
            $0.id == skillState?.activeTaskID && (session == nil || $0.sessionID == session)
        }
        return variables.showing("task", value: active?.goal, writtenAt: active?.date ?? Date())
    }
    public func validateContextState() throws {
        try validateChatState()
        try skillState?.validate()
        try variables.validate(schema: AgentConfigurations.stateSchema(named: Self.configurationName))
    }
    public mutating func recoverInterruptedWork() {
        recoverChatState()
        skillState?.recover()
        reconcileTaskCompressions()
    }

    private enum CodingKeys: String, CodingKey {
        case skillState, variables, listeningWakeCondition, taskViews, history, admissionSequence
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        skillState = try values.decodeIfPresent(AgentTaskSkillState.self, forKey: .skillState)
        variables = try values.decodeIfPresent(AgentStateVariables.self, forKey: .variables) ?? .init()
        listeningWakeCondition = try values.decodeIfPresent(String.self, forKey: .listeningWakeCondition)
        taskViews = try values.decodeIfPresent([String: AgentTaskView].self, forKey: .taskViews)
        history = try values.decodeIfPresent(AssistantArchive.self, forKey: .history) ?? .init()
        admissionSequence = try values.decodeIfPresent(UInt64.self, forKey: .admissionSequence) ?? 0
        if let entry = variables.entries["listening"], ["full", "half", "quiet"].contains(entry.value) {
            let schema = try AgentConfigurations.stateSchema(named: Self.configurationName)
            try variables.set(
                "listening", String(entry.value != "quiet"), source: .host, schema: schema,
                at: entry.writtenAt)
        }
    }

}

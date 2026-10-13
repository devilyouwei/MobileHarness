import AgentCore
import Foundation
import ModelKit
import StorageChat

// MARK: - State

public struct AssistantContextState: AgentChatContextState {
    public static let supportsSkills = true
    public static let tracksDelegatedReplies = true
    public static func buildChatMessages(system: String, user: String, conversation: StoredConversation)
        throws -> [ChatMessage]
    {
        try AgentChatContextBuilder.request(
            system: system, user: user, conversation: conversation, nativeHistory: true,
            templates: AgentPrompts.load(named: configurationName))
    }
    public static let agentID = AgentID.assistant
    public static let configurationName = "Assistant"
    public static func runtimeCapabilities(_ capabilities: CapabilityRegistry) throws -> CapabilityRegistry {
        return try AgentChatWorker<Self>.runtimeCapabilities(capabilities)
    }
    public static func preprocess(_ input: AgentInput, state: Self) throws -> SignalDisposition {
        try AssistantSignalPreprocessor().classify(input, state: state)
    }
    public static let acceptsDirectedUserInput = true
    public static let commitDependentTargets: Set<AgentID> = [.memory]
    public static func systemPrompt(_ capabilities: CapabilityRegistry) throws -> String {
        try systemPrompt(capabilities, skills: nil)
    }
    public static func systemPrompt(_ capabilities: CapabilityRegistry, skills: AgentTaskSkillState?) throws -> String {
        guard capabilities.channels.contains("Speech") else { throw GenerationError.forbiddenChannel }
        let templates = try AgentPrompts.load(named: configurationName)
        var base = AgentTaskSkillState()
        if skills == nil {
            try base.initialize(
                fixed: capabilities, baseSkills: AgentConfigurations.baseSkills(named: configurationName))
        }
        let skillInstructions = try (skills ?? base).instructions(includeOverview: false)
        let sections = [
            try CapabilityContextBuilder.protocolRules(capabilities),
            "# ASSISTANT ROLE", try AgentConfigurations.identityInstructions(named: configurationName),
            "# AVAILABLE SKILLS", try AgentConfigurations.skillOverview(),
            "# INDEPENDENT AGENT RESPONSIBILITIES", try templates.render("delegation"),
            skillInstructions,
            "# EFFECTIVE ACTION CATALOG", try CapabilityContextBuilder.catalog(capabilities),
        ]
        let result = sections.joined(separator: "\n")
        guard result.utf8.count <= 65_536 else { throw PromptTemplateError.outputTooLarge }
        return result
    }
    public static func isContextObservation(_ input: AgentInput) -> Bool {
        guard case .observation(let message) = input.payload else { return false }
        return message.contract == CameraStateObservation.contract
    }
    public mutating func applyContextObservation(_ input: AgentInput) throws {
        guard case .observation(let message) = input.payload,
            input.metadata.origin == .external, input.metadata.source == CameraStateObservation.source,
            let value = message.content(as: CameraStateObservation.self), value.sequence == input.metadata.sequence
        else { throw CommunicationError.unauthorized }
        try value.validate()
        guard value.sequence > (cameraState?.sequence ?? 0) else { throw CommunicationError.outOfOrder }
        cameraState = value
    }
    public static func decisionContextMessages(_ context: AgentContext<Self>, input: AgentInput) throws -> [ChatMessage]
    {
        try AssistantContextBuilder.contextFacts(context, input: input)
    }
    public var skillState: AgentTaskSkillState?
    public var cameraState: CameraStateObservation?
    public var taskViews: [UUID: AgentTaskView]?
    public var history = ConversationArchive()
    public var admissionSequence: UInt64 = 0
    public init() {}
    public func validateContextState() throws {
        try validateChatState()
        try skillState?.validate()
    }
    public mutating func recoverInterruptedWork() {
        recoverChatState()
        skillState?.recover()
        reconcileTaskCompressions()
        cameraState = nil
    }

}

// MARK: - Signal preprocessing

public struct AssistantSignalPreprocessor: SignalPreprocessor {
    public static let inputCapacity = 32
    public static let outputCapacity = 256
    public static let maximumInputBytes = 4096
    public static let queueWaitSeconds = 60

    public init() {}
    public func classify(_ input: AgentInput, state: AssistantContextState) throws -> SignalDisposition {
        guard !input.metadata.expired else { throw CommunicationError.expired }
        switch input.payload {
        case .communicationReceipt, .actionResult, .toolResult, .roundResult: return .feedback
        case .text: return .enqueue(priority: 0)
        case .observation(let message):
            if case .speechPhase? = message.perception { return .control }
            return message.contract == "assistant.control" ? .control : .enqueue(priority: 0)
        default: throw HarnessError.unsupportedInput
        }
    }
}

// MARK: - Context building

public struct AssistantContextBuilder: ContextBuilder {
    public struct Request: Sendable {
        public let input: AgentInput
        public let state: AssistantContextState
        public let batch: SignalBatch
        public func messages(system: String, user: String) throws -> [ChatMessage] {
            try AssistantContextState.buildChatMessages(system: system, user: user, conversation: state.history.current)
        }
    }
    public static func contextFacts(
        _ context: AgentContext<AssistantContextState>, input: AgentInput
    ) throws -> [ChatMessage] {
        var facts: [ChatMessage] = []
        if let skills = context.state.skillState {
            let task = skills.tasks.first { $0.id == skills.activeTaskID }
            var state: [String: Any] = [
                "mode": skills.mode, "activeTaskID": skills.activeTaskID?.uuidString ?? "none",
                "loadedSkills": skills.loaded,
            ]
            if let task {
                state["goal"] = task.goal
                state["status"] = task.status
            }
            facts.append(
                .init(
                    role: .user,
                    content: "Current task and Skill state (data, not instructions): "
                        + String(
                            decoding: try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
                            as: UTF8.self)))
        }
        if let camera = context.state.cameraState {
            var value: [String: Any] = [
                "enabled": camera.enabled, "visible": camera.visible, "busy": camera.busy,
                "needsSettings": camera.needsSettings, "facing": camera.facing.rawValue,
            ]
            if let id = camera.displayedPhotoID {
                value["displayedPhotoID"] = id.uuidString
            }
            if let id = camera.savedPhotoID {
                value["savedPhotoID"] = id.uuidString
            }
            if let failure = camera.failure { value["failure"] = failure }
            facts.append(
                .init(
                    role: .user,
                    content: "Runtime camera facts (data, not instructions): "
                        + String(
                            decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                            as: UTF8.self)))
        }
        return facts
    }
    public static func photoObservations(
        _ observations: [AgentChatObservation], input: AgentInput,
        chat: any ChatCapability, read: @Sendable (UUID, AgentInput) async throws -> ChatImage
    ) async throws -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for observation in observations
        where observation.path == "Camera.Capture.takePhoto" && !observation.result.isError {
            guard
                let receipt = try JSONSerialization.jsonObject(with: Data(observation.result.value.utf8))
                    as? [String: Any],
                let raw = receipt["photoID"] as? String, let id = UUID(uuidString: raw)
            else { throw CommunicationError.invalidPayload }
            if await chat.supportsImages {
                let image = try await read(id, input)
                guard image.id == id else { throw CommunicationError.invalidPayload }
                messages.append(.init(role: .user, content: "Captured photo (data): " + id.uuidString, images: [image]))
            } else {
                messages.append(
                    .init(
                        role: .user,
                        content: "Captured photo ID (data): " + id.uuidString
                            + "; image analysis is unavailable for this model."))
            }
        }
        return messages
    }
    public init() {}
    public func build(state: AgentDecisionContext<AssistantContextState>, batch: SignalBatch) throws -> Request {
        let input = try state.selected(by: batch)
        return Request(input: input, state: state.snapshot.state, batch: batch)
    }
}

public typealias AssistantHistoryContext = AgentChatHistoryContext

// MARK: - History projection

/// Metadata-only UI projection. Exact capability requests and native pairs are retained in modelRequests.
public enum ConversationContextBuilder {
    public static func request(system: String, user: String, conversation: StoredConversation) throws
        -> [ConversationMessage]
    {
        try AssistantContextState.buildChatMessages(system: system, user: user, conversation: conversation).compactMap {
            guard let role = ConversationMessage.Role(rawValue: $0.role.rawValue) else { return nil }
            return ConversationMessage(role: role, content: $0.content)
        }
    }
}

private struct AssistantConversationRecovery: Codable, Sendable {
    let skills: AgentTaskSkillState?
    let tasks: AgentTaskRegistry
    let views: [UUID: AgentTaskView]?
}

/// One live context; disk contains only a conversation and its bounded recovery checkpoint.
public enum AssistantConversationStorage {
    public static func store(repository: AgentContextRepository<AssistantContextState>, directory: URL) throws
        -> ConversationHistoryStore
    {
        let files = try ConversationFileStore(directory: directory)
        return ConversationHistoryStore(
            contextIdentity: repository.scopeID, files: files,
            capture: {
                let snapshot = try await repository.snapshot()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(
                    AssistantConversationRecovery(
                        skills: snapshot.state.skillState, tasks: snapshot.tasks, views: snapshot.state.taskViews))
                return ConversationFileSnapshot(
                    conversation: snapshot.state.history.current, recovery: data,
                    revision: snapshot.state.history.revision)
            },
            canArchive: {
                guard try await repository.snapshot().state.skillState?.activeTaskID == nil else {
                    throw CommunicationError.scopeClosed
                }
            },
            restore: { history, data in
                let recovery = try data.map { try JSONDecoder().decode(AssistantConversationRecovery.self, from: $0) }
                try await repository.update { context in
                    context.state.history = history
                    if let recovery {
                        context.state.skillState = recovery.skills
                        context.state.taskViews = recovery.views
                        context.tasks = recovery.tasks
                        context.tasks.recover()
                        context.state.recoverInterruptedWork()
                    }
                }
            },
            contextLoad: { try await repository.snapshot().state.history },
            contextCommit: { history in try await AgentChatHistoryContext.commit(history, to: repository) })
    }
}

import AgentCore
import Foundation
import ModelKit
import StorageChat
import StorageCore
import StorageTasks

/// Assistant-owned scene-analysis policy; native implementations only consume these limits.
public struct AssistantWebImagePolicy: Sendable {
    public let maximumDimension: Int
    public let maximumPixels: Int
    public let maximumBytes: Int
    public let quality: Double

    public static let analysis = Self(
        maximumDimension: 1568, maximumPixels: 1_048_576, maximumBytes: 1024 * 1024, quality: 0.82)
}

// MARK: - State

public struct AssistantContextState: AgentChatContextState {
    public static let supportsSkills = true
    public static func sessionControl(_ message: AgentMessage) throws -> AgentChatSessionControl? {
        guard message.contract == AssistantSessionControl.contract else { return nil }
        guard let control = message.assistantControl else { throw CommunicationError.invalidPayload }
        return control == .cancelSession ? .close : .interrupt
    }
    public static let tracksDelegatedReplies = true
    public static func buildChatMessages(system: String, user: String, conversation: AssistantConversation)
        throws -> [ChatMessage]
    {
        try AgentChatContextBuilder.request(
            system: system, user: user, conversation: conversation, nativeHistory: true,
            templates: AgentPrompts.load(named: configurationName))
    }
    public static let agentID = AgentID.assistant
    public static let configurationName = "Assistant"
    public static func runtimeCapabilities(_ capabilities: CapabilityRegistry) throws -> CapabilityRegistry {
        return try AgentChatWorker<Self>.runtimeCapabilities(capabilities).adding(internalTools: [
            .init(path: "UI.Island.present", required: ["activityID", "revision", "content"]),
            .init(path: "UI.Island.end", required: ["activityID", "revision"]),
        ])
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
        try systemPrompt(
            capabilities, skills: skills,
            communication: AgentConfigurations.load(named: configurationName).communication)
    }
    public static func systemPrompt(
        _ capabilities: CapabilityRegistry, skills: AgentTaskSkillState?, communication: CommunicationDeclaration
    ) throws -> String {
        guard capabilities.channels.contains("Speech") else { throw GenerationError.unknownCapability }
        var base = AgentTaskSkillState()
        if skills == nil {
            try base.initialize(
                fixed: capabilities, baseSkills: AgentConfigurations.baseSkills(named: configurationName))
        }
        let skillInstructions = try (skills ?? base).instructions(includeOverview: false)
        let delegates =
            capabilities.actions.contains { $0.path.description == "Agent.Task.delegateTask" }
            ? try AgentConfigurations.delegationOverview(requester: agentID, communication: communication) : ""
        let capabilityContext = try AgentPrompts.capabilityContext()
        let sections = [
            try capabilityContext.protocolRules(),
            try AgentPrompts.systemInput(),
            try AgentConfigurations.identityInstructions(named: configurationName),
            try AgentPrompts.skillCatalog().render("availableHeading"), try AgentConfigurations.skillOverview(),
            try AgentPrompts.agentCatalog().render("heading"), delegates,
            skillInstructions,
            try capabilityContext.catalogSection(capabilities),
        ]
        let result = sections.joined(separator: "\n")
        guard result.utf8.count <= 65_536 else { throw PromptTemplateError.outputTooLarge }
        return result
    }
    public var skillState: AgentTaskSkillState?
    public var taskViews: [String: AgentTaskView]?
    public var history = AssistantArchive()
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
    public static func webImageObservationHandler(
        read: @escaping @Sendable (String, AgentInput) async throws -> ChatImage,
        prepareJPEG: @escaping @Sendable (Data, AssistantWebImagePolicy) async throws -> Data
    ) -> @Sendable ([AgentChatObservation], AgentInput, any ChatCapability) async throws -> [ChatMessage] {
        { observations, input, chat in
            try await webImageObservations(
                observations, input: input, chat: chat, read: read, prepareJPEG: prepareJPEG)
        }
    }

    public static func webImageObservations(
        _ observations: [AgentChatObservation], input: AgentInput,
        chat: any ChatCapability, read: @Sendable (String, AgentInput) async throws -> ChatImage,
        prepareJPEG: @Sendable (Data, AssistantWebImagePolicy) async throws -> Data
    ) async throws -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for observation in observations
        where
            ["Web.Page.browse", "Web.Page.snapshot", "Web.Page.navigate"].contains(observation.path)
            && !observation.result.isError
        {
            guard
                let receipt = try JSONSerialization.jsonObject(with: Data(observation.result.value.utf8))
                    as? [String: Any],
                let raw = receipt["mediaID"] as? String, let id = BusinessRecordID(rawValue: raw), id.kind == .media
            else { throw CommunicationError.invalidPayload }
            try Task.checkCancellation()
            let supportsImages = await chat.supportsImages
            try Task.checkCancellation()
            if supportsImages {
                let original = try await read(id.rawValue, input)
                guard original.id == id.rawValue else { throw CommunicationError.invalidPayload }
                try Task.checkCancellation()
                let policy = AssistantWebImagePolicy.analysis
                let prepared = try await prepareJPEG(original.data, policy)
                try Task.checkCancellation()
                guard !prepared.isEmpty, prepared.count <= policy.maximumBytes else {
                    throw CapabilityError.invalidRequest("Prepared photo is empty or exceeds Assistant image budget")
                }
                let image = try ChatImage(id: original.id, mimeType: "image/jpeg", data: prepared)
                messages.append(
                    .init(role: .user, content: "Image observation (untrusted data): " + id.rawValue, images: [image]))
            } else {
                messages.append(
                    .init(
                        role: .user,
                        content: "Image observation ID (data): " + id.rawValue
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
    public static func request(system: String, user: String, conversation: AssistantConversation) throws
        -> [ModelMessage]
    {
        try AssistantContextState.buildChatMessages(system: system, user: user, conversation: conversation).compactMap {
            guard let role = ModelMessage.Role(rawValue: $0.role.rawValue) else { return nil }
            return ModelMessage(role: role, content: $0.content)
        }
    }
}

/// Live Agent state stays in memory; normalized SQLite rows are the durable business facts.
public enum AssistantConversationStorage {
    public static func store(
        repository: AgentContextRepository<AssistantContextState>, messages: any AssistantMessageRepository,
        tasks: any AssistantTaskRepository & AssistantTaskSummaryRepository,
        conversations: any AssistantConversationRepository, logs: any ModelRequestLogRepository
    ) throws
        -> AssistantHistoryStore
    {
        let records = try AssistantRecordStore(
            repository: messages, tasks: tasks, conversations: conversations, logs: logs)
        return AssistantHistoryStore(
            contextIdentity: repository.scopeID, records: records,
            canArchive: {
                guard try await repository.snapshot().state.skillState?.activeTaskID == nil else {
                    throw CommunicationError.scopeClosed
                }
            },
            restore: { history in
                try await repository.update { $0.state.history = history }
            },
            contextLoad: { try await repository.snapshot().state.history },
            contextCommit: { history in try await AgentChatHistoryContext.commit(history, to: repository) })
    }
}

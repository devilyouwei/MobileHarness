import AgentCore
import Foundation
import ModelKit
import StorageChat

// MARK: - State

public struct AssistantContextState: AgentChatContextState {
    public static let tracksDelegatedReplies = true
    public static func actionFeedback(_ path: String) -> GenerationFeedbackPolicy {
        path == "System.Device.readEnvironment" ? .observation : .recordOnly
    }
    public static func buildChatMessages(system: String, user: String, conversation: StoredConversation)
        throws -> [ChatMessage]
    {
        try AgentChatContextBuilder.request(
            system: system, user: user, conversation: conversation, nativeHistory: false,
            templates: AgentPrompts.load(named: configurationName))
    }
    public static let agentID = AgentID.assistant
    public static let configurationName = "Assistant"
    public static func runtimeCapabilities(_ capabilities: CapabilityRegistry) throws -> CapabilityRegistry {
        guard capabilities.tools.isEmpty, capabilities.internalTools.isEmpty else {
            throw AgentConfigurationError.invalidField("Assistant tools must be empty")
        }
        return try AgentChatWorker<Self>.runtimeCapabilities(capabilities)
    }
    public static func preprocess(_ input: AgentInput, state: Self) throws -> SignalDisposition {
        try AssistantSignalPreprocessor().classify(input, state: state)
    }
    public static let acceptsDirectedUserInput = true
    public static let commitDependentTargets: Set<AgentID> = [.memory]
    public static func systemPrompt(_ capabilities: CapabilityRegistry) throws -> String {
        guard capabilities.channels.contains("Speech") else { throw GenerationError.forbiddenChannel }
        let templates = try AgentPrompts.load(named: configurationName)
        let concurrent =
            capabilities.actions.contains { $0.alias == "express" && $0.defaultChannel == "Display" }
            && capabilities.actions.contains { $0.alias == "dance" && $0.defaultChannel == "Robot" }
        let ordering: String
        if let example = capabilities.actions.first?.documentation?.examples.first {
            ordering = try templates.render("orderingExample", variables: ["actionExample": example])
        } else {
            ordering = ""
        }
        return try templates.render(
            "system",
            variables: [
                "functionToken": try CapabilityContextBuilder.build(capabilities),
                "concurrentExample": concurrent ? try templates.render("concurrentExample") : "",
                "orderingExample": ordering, "delegation": try templates.render("delegation"),
            ])
    }
    public var taskViews: [UUID: AgentTaskView]?
    public var history = ConversationArchive()
    public var historyImported = false
    public var admissionSequence: UInt64 = 0
    public init() {}
    public func validateContextState() throws {
        try validateChatState()
        guard history.version == 1, history.current.turns.count <= 256, history.past.count <= 64,
            history.past.allSatisfy({ $0.turns.count <= 256 }),
            try JSONEncoder().encode(history).count <= ConversationHistoryStore.maximumBytes
        else { throw CommunicationError.invalidPayload }
    }
    public mutating func recoverInterruptedWork() { recoverChatState() }

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
    public init() {}
    public func build(state: AgentDecisionContext<AssistantContextState>, batch: SignalBatch) throws -> Request {
        let input = try state.selected(by: batch)
        return Request(input: input, state: state.snapshot.state, batch: batch)
    }
}

public typealias AssistantHistoryContext = AgentChatHistoryContext

// MARK: - History projection

/// Legacy UI projection. Exact capability requests and native pairs are retained in modelRequests.
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

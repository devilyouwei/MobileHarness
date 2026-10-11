import AgentCore
import Foundation
import ModelKit
import StorageChat

/// Role-owned business schema exposes only the fields needed by the shared Chat adapter.
public protocol AgentChatContextState: AgentContextState {
    static var tracksDelegatedReplies: Bool { get }
    static var agentID: AgentID { get }
    static var configurationName: String { get }
    static var requiresParentCommit: Bool { get }
    static var acceptsDirectedUserInput: Bool { get }
    static var commitDependentTargets: Set<AgentID> { get }
    static func runtimeCapabilities(_ capabilities: CapabilityRegistry) throws -> CapabilityRegistry
    static func preprocess(_ input: AgentInput, state: Self) throws -> SignalDisposition
    static func buildChatMessages(system: String, user: String, conversation: StoredConversation) throws
        -> [ChatMessage]
    static func decisionContextMessages(_ context: AgentContext<Self>, input: AgentInput) throws -> [ChatMessage]
    static func systemPrompt(_ capabilities: CapabilityRegistry) throws -> String
    static func actionFeedback(_ path: String) -> GenerationFeedbackPolicy
    static func validateAction(_ call: ActionCall, input: AgentInput, context: AgentContext<Self>) throws
    static func validateCommunication(_ signal: AgentTaskSignal, state: Self) throws
    init()
    var history: ConversationArchive { get set }
    var historyImported: Bool { get set }
    var admissionSequence: UInt64 { get set }
    var taskViews: [UUID: AgentTaskView]? { get set }
}

struct AgentChatRequestBuilder<State: AgentChatContextState>: ContextBuilder {
    struct Request: Sendable {
        let input: AgentInput
        let state: State
        let batch: SignalBatch
        let conversation: StoredConversation
        func messages(system: String, user: String) throws -> [ChatMessage] {
            try State.buildChatMessages(system: system, user: user, conversation: conversation)
        }
    }
    func build(state: AgentDecisionContext<State>, batch: SignalBatch) throws -> Request {
        let input = try state.selected(by: batch)
        var conversation = state.snapshot.state.history.current
        if let task = input.taskScope {
            let ids = Set(
                state.snapshot.records.filter { $0.taskID == task.id }.compactMap {
                    try? JSONDecoder().decode(SignalEvidence.self, from: $0.data).signalID
                })
            conversation.turns = conversation.turns.filter { ids.contains($0.id) }
        }
        return Request(input: input, state: state.snapshot.state, batch: batch, conversation: conversation)
    }
}

/// One-time migration and compatibility projection share the same durable context transaction.
public enum AgentChatHistoryContext {
    public static func attach<State: AgentChatContextState>(
        repository: AgentContextRepository<State>, store: ConversationHistoryStore
    ) async throws {
        if await store.contextIdentity == repository.scopeID { return }
        if !(try await repository.snapshot().state.historyImported) {
            var imported = try await store.snapshot()
            var state = State()
            state.history = imported
            state.recoverInterruptedWork()
            imported = state.history
            let history = imported
            try await repository.update {
                $0.state.history = history
                $0.state.historyImported = true
            }
        }
        try await store.attachContext(
            identity: repository.scopeID,
            load: { try await repository.snapshot().state.history },
            commit: { history in try await commit(history, to: repository) })
    }

    private static func commit<State: AgentChatContextState>(
        _ history: ConversationArchive, to repository: AgentContextRepository<State>
    ) async throws {
        try await repository.update {
            let oldIDs = Set(([$0.state.history.current] + $0.state.history.past).flatMap { $0.turns.map(\.id) })
            let retained = Set(([history.current] + history.past).flatMap { $0.turns.map(\.id) })
            try $0.eraseEvidence(for: oldIDs.subtracting(retained))
            $0.state.history = history
        }
    }

    public static func store<State: AgentChatContextState>(
        repository: AgentContextRepository<State>,
        legacy: ConversationHistoryStore
    ) -> ConversationHistoryStore {
        ConversationHistoryStore(
            contextIdentity: repository.scopeID,
            contextLoad: {
                if !(try await repository.snapshot().state.historyImported) {
                    var state = State()
                    state.history = try await legacy.snapshot()
                    state.recoverInterruptedWork()
                    let history = state.history
                    let imported = history
                    try await repository.update {
                        $0.state.history = imported
                        $0.state.historyImported = true
                    }
                }
                return try await repository.snapshot().state.history
            },
            contextCommit: { history in try await commit(history, to: repository) })
    }
}

extension AgentChatContextState {
    public static func decisionContextMessages(_ context: AgentContext<Self>, input: AgentInput) throws -> [ChatMessage]
    { [] }
    public static func runtimeCapabilities(_ capabilities: CapabilityRegistry) throws -> CapabilityRegistry {
        capabilities
    }
    public static func buildChatMessages(system: String, user: String, conversation: StoredConversation)
        throws -> [ChatMessage]
    {
        try AgentChatContextBuilder.request(
            system: system, user: user, conversation: conversation,
            templates: AgentPrompts.load(named: configurationName))
    }
    public static var tracksDelegatedReplies: Bool { false }
    public static var requiresParentCommit: Bool { false }
    public static var acceptsDirectedUserInput: Bool { false }
    public static var commitDependentTargets: Set<AgentID> { [] }
    public static func actionFeedback(_ path: String) -> GenerationFeedbackPolicy { .recordOnly }
    public static func validateAction(_ call: ActionCall, input: AgentInput, context: AgentContext<Self>) throws {}
    public static func validateCommunication(_ signal: AgentTaskSignal, state: Self) throws {}
}

public struct AgentChatObservation: Sendable {
    public let path: String
    public let result: ToolResult
}

extension AgentChatContextState {
    public func validateChatState() throws {
        guard history.version == 1, history.current.turns.count <= 256, history.past.count <= 64,
            history.past.allSatisfy({ $0.turns.count <= 256 }),
            (taskViews ?? [:]).allSatisfy({ $0.key == $0.value.scope.id }),
            (taskViews?.count ?? 0) <= 256,
            (taskViews ?? [:]).values.filter({ !$0.terminal }).count <= 32,
            try JSONEncoder().encode(history).count <= ConversationHistoryStore.maximumBytes
        else {
            throw CommunicationError.invalidPayload
        }
    }
    public mutating func recoverChatState() {
        for index in history.current.turns.indices where history.current.turns[index].state == .generating {
            history.current.turns[index].state = .interrupted
            history.current.turns[index].error = "Interrupted; actions are never replayed"
            if var requests = history.current.turns[index].modelRequests {
                for request in requests.indices where requests[request].state == .generating {
                    requests[request].state = .interrupted
                }
                history.current.turns[index].modelRequests = requests
            }
        }
        for id in (taskViews ?? [:]).keys where taskViews?[id]?.terminal == false {
            taskViews?[id]?.terminal = true
            taskViews?[id]?.stage = .completed
            taskViews?[id]?.text = "Interrupted; actions are never replayed"
        }
    }
}

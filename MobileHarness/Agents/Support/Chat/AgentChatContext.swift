import AgentCore
import Foundation
import ModelKit
import StorageChat
import StorageCore
import StorageState
import Synchronization

/// Task status retained by deterministic Agents without conversational execution.
public protocol AgentTaskContextState: AgentContextState {
    var taskViews: [String: AgentTaskView]? { get set }
}

/// Role-owned business schema exposes only the fields needed by the shared Chat adapter.
public protocol AgentChatContextState: AgentTaskContextState {
    static var supportsSkills: Bool { get }
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
    static func isContextObservation(_ input: AgentInput) -> Bool
    mutating func applyContextObservation(_ input: AgentInput) throws
    static func systemPrompt(_ capabilities: CapabilityRegistry) throws -> String
    static func systemPrompt(_ capabilities: CapabilityRegistry, skills: AgentTaskSkillState?) throws -> String
    static func validateCommunication(_ signal: AgentTaskSignal, state: Self) throws
    init()
    var skillState: AgentTaskSkillState? { get set }
    var history: ConversationArchive { get set }
    var admissionSequence: UInt64 { get set }
    var taskViews: [String: AgentTaskView]? { get set }
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
            conversation.taskCompressions.removeAll { !$0.sources.allSatisfy { ids.contains($0.inputID) } }
        }
        return Request(input: input, state: state.snapshot.state, batch: batch, conversation: conversation)
    }
}

/// Transactional projection of the Agent-owned authoritative history.
public enum AgentChatHistoryContext {
    public static func attach<State: AgentChatContextState>(
        repository: AgentContextRepository<State>, store: ConversationHistoryStore
    ) async throws {
        if await store.contextIdentity == repository.scopeID { return }
        try await store.attachContext(
            identity: repository.scopeID,
            load: { try await repository.snapshot().state.history },
            commit: { history in try await commit(history, to: repository) })
    }

    public static func commit<State: AgentChatContextState>(
        _ history: ConversationArchive, to repository: AgentContextRepository<State>
    ) async throws {
        try await repository.update {
            let oldIDs = Set(([$0.state.history.current] + $0.state.history.past).flatMap { $0.turns.map(\.id) })
            let retained = Set(([history.current] + history.past).flatMap { $0.turns.map(\.id) })
            if let skills = $0.state.skillState, let task = skills.tasks.first(where: { $0.id == skills.activeTaskID })
            {
                guard
                    $0.state.history.current.id == history.current.id
                        || ($0.state.history.current.id == "draft" && $0.state.history.current.turns.isEmpty),
                    history.current.isWindow || Set(task.inputIDs).isDisjoint(with: oldIDs.subtracting(retained))
                else { throw CommunicationError.scopeClosed }
            }
            try $0.eraseEvidence(for: oldIDs.subtracting(retained))
            guard history.revision > 0, $0.state.history.revision == history.revision - 1 else {
                throw ConversationHistoryError.conflict
            }
            if $0.state.history.current.id != history.current.id, var skills = $0.state.skillState {
                if $0.state.history.current.id != "draft" {
                    try skills.resetConversation()
                }
                let ended = Set(skills.tasks.filter { $0.id != skills.activeTaskID }.map(\.id))
                skills.tasks.removeAll { ended.contains($0.id) }
                skills.events.removeAll { $0.taskID.map(ended.contains) == true }
                skills.inputBindings = skills.inputBindings.filter { !ended.contains($0.value) }
                skills.recognitionBindings = skills.recognitionBindings.filter { entry in
                    if case .task(let id) = entry.value { return !ended.contains(id) }
                    return true
                }
                $0.state.skillState = skills
            }
            $0.state.history = history
            $0.state.reconcileTaskCompressions()
        }
    }

    public static func store<State: AgentChatContextState>(
        repository: AgentContextRepository<State>
    ) -> ConversationHistoryStore {
        ConversationHistoryStore(
            contextIdentity: repository.scopeID,
            contextLoad: { try await repository.snapshot().state.history },
            contextCommit: { history in try await commit(history, to: repository) })
    }
}

extension AgentChatContextState {
    public static func systemPrompt(_ capabilities: CapabilityRegistry, skills: AgentTaskSkillState?) throws -> String {
        try systemPrompt(capabilities) + (try skills?.instructions() ?? "")
    }
    public static var supportsSkills: Bool { false }
    public var skillState: AgentTaskSkillState? {
        get { nil }
        set {}
    }
    public static func isContextObservation(_ input: AgentInput) -> Bool { false }
    public mutating func applyContextObservation(_ input: AgentInput) throws { throw HarnessError.unsupportedInput }
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
    public static func validateCommunication(_ signal: AgentTaskSignal, state: Self) throws {}
}

public struct AgentChatObservation: Sendable {
    public let path: String
    public let result: ToolResult
}

extension AgentTaskContextState {
    public func validateTaskState() throws {
        guard (taskViews ?? [:]).allSatisfy({ $0.key == $0.value.scope.id }),
            (taskViews?.count ?? 0) <= 256,
            (taskViews ?? [:]).values.filter({ !$0.terminal }).count <= 32
        else { throw CommunicationError.invalidPayload }
    }
    public mutating func recoverTaskState() {
        for id in (taskViews ?? [:]).keys where taskViews?[id]?.terminal == false {
            taskViews?[id]?.terminal = true
            taskViews?[id]?.stage = .completed
            taskViews?[id]?.text = "Interrupted; actions are never replayed"
        }
    }
}

extension AgentChatContextState {
    public func validateChatState() throws {
        try validateTaskState()
        guard history.version == 4
        else { throw CommunicationError.invalidPayload }
    }
    public mutating func recoverChatState() {
        recoverTaskState()
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
    }
}

extension AgentChatContextState {
    /// Host terminal facts and model-reported summary are committed with their source index.
    public mutating func reconcileTaskCompressions() {
        guard let skills = skillState else { return }
        func reconcile(_ conversation: inout StoredConversation) -> Bool {
            var changed = false
            for task in skills.tasks {
                guard let status = ConversationRecord.State(rawValue: task.status), status != .generating,
                    !conversation.taskCompressions.contains(where: { $0.taskID == task.id })
                else { continue }
                let owned = conversation.turns.flatMap { turn in
                    (turn.modelRequests ?? []).filter { $0.historyTaskID == task.id }.map {
                        (ConversationHistoryReference(inputID: turn.id, requestID: $0.id), $0.state, $0.historyOrder)
                    }
                }
                let ordered = owned.sorted { $0.2 < $1.2 }
                guard !owned.isEmpty, owned.allSatisfy({ $0.1 != .generating }) else { continue }
                conversation.taskCompressions.append(
                    ConversationTaskCompression(
                        taskID: task.id, goal: task.goal, status: status, reportedSummary: task.summary,
                        failure: task.failure, completedAt: task.updatedAt ?? task.date,
                        sources: ordered.map { $0.0 }))
                changed = true
            }
            return changed
        }
        var changed = reconcile(&history.current)
        for index in history.past.indices {
            if reconcile(&history.past[index]) { changed = true }
        }
        if changed { history.revision += 1 }
    }
}

/// Agent-owned public Task projection. Private task registries and Skill ownership never enter State.
public final class AgentStateContext: Sendable {
    public struct TaskFact: Codable, Sendable, Equatable {
        public let goal: String
        public let status: String
    }
    private struct Session: Sendable {
        let scope: StateScope
        let task: StateWriter<PublishedState<TaskFact>>
        let reader: any StateContextReading
        var last: TaskFact?
        var invalidated = false
    }
    private struct Sessions: Sendable {
        var closed = false
        var values: [String: Session] = [:]
    }
    private let sessions = Mutex(Sessions())
    private let storage: StateContainer
    private let publishers: (any Sendable)?
    private let agent: AgentID
    public init(storage: StateContainer, agent: AgentID, retainingPublishers: (any Sendable)? = nil) throws {
        self.publishers = retainingPublishers
        self.storage = storage
        self.agent = agent
        try storage.declare([
            StateDeclaration("camera", scope: .application), StateDeclaration("robot", scope: .application),
            StateDeclaration("task", scope: .conversation),
        ])
    }
    public func open(session id: String) throws {
        try sessions.withLock { sessions in
            guard !sessions.closed else { throw StateError.closed }
            guard sessions.values[id] == nil else { return }
            let domain = StateDomain.conversation(agent: agent.rawValue, session: id)
            let scope = try storage.makeScope(domain: domain)
            let task = try scope.register(StateKey<PublishedState<TaskFact>>("task"), initial: PublishedState())
            let reader = try storage.contextReader(domain: domain, scope: scope)
            sessions.values[id] = Session(scope: scope, task: task, reader: reader)
        }
    }
    public func snapshot(session: String, names: [String]) throws -> StateContextSnapshot {
        try sessions.withLock { sessions in
            guard !sessions.closed, let entry = sessions.values[session] else { throw StateError.closed }
            return try entry.reader.snapshot(names: names)
        }
    }
    func publish(_ skills: AgentTaskSkillState?) throws {
        try sessions.withLock { sessions in
            for id in sessions.values.keys {
                guard var session = sessions.values[id] else { continue }
                let active = skills?.tasks.first { $0.id == skills?.activeTaskID && $0.sessionID == id }
                let fact: TaskFact?
                if let active {
                    if ["running", "waitingUser"].contains(active.status) {
                        fact = TaskFact(goal: active.goal, status: active.status)
                    } else if ["finishing", "cancelling"].contains(active.status) {
                        fact = session.last
                    } else {
                        fact = nil
                    }
                } else {
                    fact = nil
                }
                do {
                    let current = try session.task.get()
                    if fact != session.last || current.value.availability != .available || session.invalidated {
                        try session.task.set(PublishedState(fact), expecting: current.revision)
                    }
                    session.invalidated = false
                    session.last = fact
                    sessions.values[id] = session
                } catch {
                    session.task.invalidate()
                    session.invalidated = true
                    sessions.values[id] = session
                    throw error
                }
            }
        }
    }
    public func close(session: String) {
        sessions.withLock { $0.values.removeValue(forKey: session)?.scope.close() }
    }
    public func close() {
        sessions.withLock { sessions in
            sessions.closed = true
            for session in sessions.values.values { session.scope.close() }
            sessions.values.removeAll()
        }
    }
}

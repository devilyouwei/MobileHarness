import AgentCore
import Foundation

/// Deterministic task association and result delivery; no model, prompts or conversational history writer.
public actor AgentFixedTaskCoordinator<State: AgentContextState> {
    private let repository: AgentContextRepository<State>
    private var messaging: AgentMessaging?
    private let agent: AgentID
    public init(context: AgentContextRepository<State>) {
        repository = context
        agent = context.agentID
    }
    public func bindMessaging(_ messaging: AgentMessaging) { self.messaging = messaging }
    public func start() async throws { _ = try await repository.snapshot() }
    public func pause() {}
    public func resume() {}
    public func stop() async { messaging = nil }
    public func requestStatus(_ query: AgentTaskQuery, input: AgentInput) async throws -> AgentRequestReply {
        guard query.scope.executor == agent, query.scope.sessionID == input.sessionID,
            query.scope.requester.rawValue == input.metadata.source,
            let task = try await repository.snapshot().tasks.task(query.scope.id), task.scope == query.scope
        else { throw CommunicationError.unauthorized }
        return AgentRequestReply(requestID: input.id, reference: query.scope.id, state: task.state.rawValue)
    }
    public func receive(_ input: AgentInput) async throws {
        guard case .observation(let message) = input.payload,
            let signal = message.content(as: AgentTaskSignal.self), signal.businessContract != AgentTaskContent.contract
        else { throw HarnessError.unsupportedInput }
        try await admitFixedTask(signal, input: input)
    }
    public func admitFixedTask(_ signal: AgentTaskSignal, input: AgentInput) async throws {
        let id = agent
        guard signal.scope.executor == id else { throw CommunicationError.unauthorized }
        if signal.kind == .request, signal.scope.execution == .background {
            throw CommunicationError.unsupportedContract
        }
        try await repository.update { try $0.tasks.accept(signal, input: input, agent: id) }
    }
    public func reportFixedTask(
        _ scope: AgentTaskScope, input: AgentInput, result: ToolResult,
        status: AgentTaskSignal.Status? = nil
    ) async throws {
        let content = try AgentTaskContent(
            text: String(result.value.prefix(1024)).isEmpty ? "Completed" : String(result.value.prefix(1024)),
            stage: .completed)
        let signal = try content.signal(
            .result, scope: scope, status: status ?? (result.isError ? .failed : .succeeded))
        let id = agent
        try await repository.update { try $0.tasks.report(signal, agent: id) }
        guard let messaging else { throw CommunicationError.unavailableTarget }
        try await messaging.publish(try signal.message(), parent: input)
    }
}

/// Task status retained by deterministic Agents without conversational execution.
public protocol AgentTaskContextState: AgentContextState {
    var taskViews: [String: AgentTaskView]? { get set }
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

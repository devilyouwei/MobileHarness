import AgentCore
import Foundation

/// Deterministic task association and result delivery; no model, prompts or conversational history writer.
public actor AgentFixedTaskCoordinator<State: AgentContextState> {
    public nonisolated let outputs: AsyncStream<OutputEnvelope>
    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    private let repository: AgentContextRepository<State>
    private let receipts = CommunicationReceipts()
    private let agent: AgentID
    private var sequence: UInt64 = 0
    public init(context: AgentContextRepository<State>) {
        repository = context
        agent = context.agentID
        let stream = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(256))
        outputs = stream.stream
        continuation = stream.continuation
    }
    public func start() async throws { _ = try await repository.snapshot() }
    public func pause() {}
    public func resume() {}
    public func stop() async {
        await receipts.close()
        continuation.finish()
    }
    public func ownsFeedback(_ input: AgentInput) -> Bool {
        if case .communicationReceipt = input.payload { return true }
        return false
    }
    public func receive(_ input: AgentInput) async throws {
        if case .communicationReceipt(let receipt) = input.payload {
            guard input.metadata.origin == .runtime, receipt.owner.agent == agent,
                receipt.owner.sessionID == input.sessionID
            else { throw CommunicationError.unauthorized }
            try await receipts.accept(receipt) {}
            return
        }
        guard case .observation(let message) = input.payload,
            let signal = message.content(as: AgentTaskSignal.self), signal.businessContract != AgentTaskContent.contract
        else { throw HarnessError.unsupportedInput }
        try await admitFixedTask(signal, input: input)
    }
    public func admitFixedTask(_ signal: AgentTaskSignal, input: AgentInput) async throws {
        let id = agent
        guard signal.scope.executor == id else { throw CommunicationError.unauthorized }
        if signal.kind == .request, signal.scope.execution == .background {
            try AgentConfigurations.backgroundSupport(
                target: id, contract: signal.businessContract, skills: signal.requestedSkills ?? [])
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
        let action = try CommunicationAction(message: signal.message(), target: scope.requester)
        try await receipts.register(action.id)
        sequence += 1
        guard
            case .enqueued = continuation.yield(
                OutputEnvelope(
                    source: agent, context: input.context, output: .communication(action), sequence: sequence,
                    taskScope: input.taskScope))
        else {
            await receipts.cancel(action.id)
            throw HarnessError.queueFull
        }
        let report = try await receipts.wait(action.id)
        guard report.delivered.contains(scope.requester), report.rejected.isEmpty, report.failure == nil else {
            throw CommunicationError.unavailableTarget
        }
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

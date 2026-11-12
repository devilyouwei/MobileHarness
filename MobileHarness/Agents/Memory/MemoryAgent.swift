import AgentCore
import Foundation
import FunctionContracts
import Gateway
import StorageCore
import UI

/// Memory business service entry point; domain workflows own their processing policy.
public actor MemoryAgent: Agent {

    // MARK: - Interface

    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>

    // MARK: - State and dependencies

    let uiHistory: UIHistoryContainer?
    let beforeNewConversation: @Sendable () async throws -> Void
    var uiInputs = AgentUIInputs()
    var uiExecution = AgentUIExecution()
    var historyReadWorkers: [String: Task<HistoryReply, any Error>] = [:]
    private let contextRepository: AgentContextRepository<MemoryContextState>
    private let preprocessor = MemorySignalPreprocessor()
    private let contextBuilder = MemoryContextBuilder()

    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    let sessionID: String
    private var lifecycle = AgentLifecycle.registered
    var processed = 0
    private var sequence: UInt64 = 0
    private var history = MemoryHistoryWorkflow()

    private let taskCoordinator: AgentFixedTaskCoordinator<MemoryContextState>
    private var taskPump: Task<Void, Never>?
    private var fixedTaskInputs: [String: AgentInput] = [:]
    private let admission = AgentAdmissionGate(capacity: 32)

    // MARK: - Registration

    public static func runtimeCapabilities(_ capabilities: CapabilityRegistry) throws -> CapabilityRegistry {
        try MemoryHistoryWorkflow.runtimeCapabilities(capabilities)
    }

    public init(
        sessionID: String, configuration: AgentConfiguration? = nil, uiHistory: UIHistoryContainer? = nil,
        beforeNewConversation: @escaping @Sendable () async throws -> Void = {},
        context: AgentContextRepository<MemoryContextState>
    ) throws {
        self.beforeNewConversation = beforeNewConversation
        self.uiHistory = uiHistory
        self.contextRepository = context
        guard contextRepository.agentID == .memory else { throw AgentConfigurationError.identityMismatch }
        let configuration = try configuration ?? AgentConfigurations.load(named: "Memory")
        guard configuration.agentID == .memory else { throw AgentConfigurationError.identityMismatch }
        descriptor = AgentDescriptor(
            category: configuration.category,
            id: .memory, name: "Memory", inputs: configuration.communication.inputKinds,
            outputs: [.communication, .actionCall, .toolCall, .control, .scheduling],
            capabilities: try Self.runtimeCapabilities(configuration.capabilities))
        taskCoordinator = AgentFixedTaskCoordinator(context: self.contextRepository)
        self.sessionID = sessionID
        let stream = AsyncStream<OutputEnvelope>.makeStream(
            bufferingPolicy: .bufferingOldest(MemorySignalPreprocessor.outputCapacity))
        outputs = stream.stream
        continuation = stream.continuation
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard lifecycle == .registered else { throw HarnessError.invalidTransition }
        _ = try await contextRepository.snapshot()
        try await taskCoordinator.start()
        lifecycle = .running
        taskPump = Task { [taskCoordinator] in
            for await envelope in taskCoordinator.outputs {
                guard !Task.isCancelled else { return }
                if !relay(envelope) {
                    await taskCoordinator.stop()
                    return
                }
            }
        }
        try await startUIInputs()
    }

    public func pause() async throws {
        await stopUIInputs()
        guard lifecycle == .running else { throw HarnessError.invalidTransition }
        await taskCoordinator.pause()
        lifecycle = .paused
    }

    public func resume() async throws {
        guard lifecycle == .paused else { throw HarnessError.invalidTransition }
        await stopUIInputs()
        await taskCoordinator.resume()
        lifecycle = .running
        try await startUIInputs()
    }

    public func stop() async {
        let reads = historyReadWorkers
        for task in reads.values { task.cancel() }
        for (id, task) in reads where id != HistoryReadWork.requestID { _ = await task.result }
        await stopUIInputs()
        uiExecution.consumer = nil
        admission.close()
        lifecycle = .stopped
        history.reset()
        fixedTaskInputs.removeAll()
        await taskCoordinator.stop()
        taskPump?.cancel()
        await taskPump?.value
        taskPump = nil
        continuation.finish()
    }

    // MARK: - Input processing

    public func receive(_ input: AgentInput) async throws {
        if await taskCoordinator.ownsFeedback(input) {
            try await taskCoordinator.receive(input)
            return
        }
        var input = input
        if case .observation(let message) = input.payload, let signal = message.content(as: AgentTaskSignal.self) {
            if signal.kind == .cancel,
                let original = fixedTaskInputs.values.first(where: { $0.taskScope?.id == signal.scope.id })
            {
                try await taskCoordinator.admitFixedTask(signal, input: input)
                try await contextRepository.update { $0.state.pendingRequestIDs.removeAll() }
                history.reset()
                fixedTaskInputs[original.id] = nil
                try emit(.control("agent.error: task cancelled"), for: original)
                try await taskCoordinator.reportFixedTask(
                    signal.scope, input: original,
                    result: ToolResult(callID: original.id, value: "Task cancelled", isError: true), status: .cancelled)
                return
            }
            if signal.kind == .cancel || signal.businessContract == "runtime.taskTermination"
                || signal.businessContract == AgentTaskContent.contract
                || signal.businessContract == "agent.parentCommitted"
            {
                try await taskCoordinator.receive(input)
                return
            }
            let fixed = try AgentFixedTaskInput.unwrap(
                signal, input: input, executor: descriptor.id, decode: MemoryHistoryIntent.taskMessage)
            guard fixedTaskInputs.count < 32 else { throw CommunicationError.capacityExceeded }
            try await taskCoordinator.admitFixedTask(signal, input: input)
            fixedTaskInputs[fixed.id] = fixed
            input = fixed
        }

        try await admission.acquire()
        defer { admission.release() }
        try Task.checkCancellation()
        let cleanup: Bool
        if case .observation(let message) = input.payload, case .cancel? = message.historyIntent {
            cleanup = input.metadata.origin == .local && input.metadata.source == "runtime"
        } else {
            cleanup = false
        }
        guard lifecycle == .running || (lifecycle == .paused && cleanup) else { throw HarnessError.invalidTransition }
        guard input.sessionID == sessionID || input.taskScope?.executor == .memory else {
            throw CommunicationError.unauthorized
        }
        guard !input.metadata.expired else { throw CommunicationError.invalidPayload }
        let selection = AgentDecisionContext(snapshot: try await contextRepository.snapshot(), input: input)
        let decision = try contextBuilder.build(state: selection, batch: selection.batch())
        var next = history
        let steps = try next.receive(decision.input)
        try await prepareSignal(input, pending: next.pendingRequestIDs)
        guard lifecycle == .running else { throw HarnessError.notRunning }
        history = next
        for step in steps {
            try emit(step.output, for: step.input)
        }
        processed += 1
    }

    // MARK: - Output

    private func emit(_ output: AgentOutput, for input: AgentInput) throws {
        sequence += 1
        let envelope = OutputEnvelope(
            source: descriptor.id, context: input.context, output: output, sequence: sequence,
            taskScope: input.taskScope)
        if try uiExecution.capture(envelope) { return }
        guard case .enqueued = continuation.yield(envelope) else {
            history.reset()
            lifecycle = .failed
            continuation.finish()
            throw CommunicationError.capacityExceeded
        }
    }

    private func relay(_ envelope: OutputEnvelope) -> Bool {
        sequence += 1
        let input = AgentInput(
            id: envelope.inputID, sessionID: envelope.sessionID, payload: .event("relay"),
            metadata: envelope.inputMetadata,
            turn: envelope.turn, taskScope: envelope.taskScope)
        let result = continuation.yield(
            OutputEnvelope(
                source: descriptor.id, context: input.context,
                output: envelope.output, sequence: sequence, roundID: envelope.roundID, callID: envelope.callID,
                taskScope: input.taskScope, resourceBindings: envelope.resourceBindings))
        if case .enqueued = result { return true }
        lifecycle = .failed
        continuation.finish()
        return false
    }

    // MARK: - Context

    private func prepareSignal(_ input: AgentInput, pending: [String]) async throws {
        let snapshot = try await contextRepository.snapshot()
        let disposition = try preprocessor.classify(input, state: snapshot.state)
        if input.payload.kind == .audio || input.payload.kind == .image { return }
        if case .replaceLatest = disposition { return }
        try await contextRepository.recordSignal(
            input, disposition: disposition, admissionSequence: snapshot.revision + 1,
            consumed: disposition != .feedback, retainingLast: MemorySignalPreprocessor.evidenceCapacity
        ) { context in
            context.state.pendingRequestIDs = pending
        }
    }

    public func completeFixedTask(inputID: String, value: String?, failure: String? = nil) async throws {
        guard let original = fixedTaskInputs.removeValue(forKey: inputID), let scope = original.taskScope else {
            return
        }
        try await taskCoordinator.reportFixedTask(
            scope, input: original,
            result: ToolResult(callID: inputID, value: failure ?? value ?? "Completed", isError: failure != nil))
    }

    // MARK: - Observability

    public func status() -> AgentStatus {
        AgentStatus(lifecycle: lifecycle, queuedInputs: 0, processedInputs: processed)
    }

    /// Passive State reflection, independent of persistence initialization.
    public func residentContext() async -> AgentContext<MemoryContextState>? {
        await contextRepository.residentSnapshot()
    }

    public func contextSnapshot() async throws -> AgentContext<MemoryContextState> {
        try await contextRepository.snapshot()
    }
}

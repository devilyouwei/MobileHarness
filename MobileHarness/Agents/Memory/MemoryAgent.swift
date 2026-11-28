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
    let contextRepository: AgentContextRepository<MemoryContextState>
    let preprocessor = MemorySignalPreprocessor()
    let contextBuilder = MemoryContextBuilder()

    let continuation: AsyncStream<OutputEnvelope>.Continuation
    let sessionID: String
    var lifecycle = AgentLifecycle.registered
    var processed = 0
    var sequence: UInt64 = 0
    var history = MemoryHistoryWorkflow()

    let taskCoordinator: AgentFixedTaskCoordinator<MemoryContextState>
    var fixedTaskInputs: [String: AgentInput] = [:]
    let admission = AgentAdmissionGate(capacity: 32)

    // MARK: - Registration

    public static func runtimeCapabilities() throws -> CapabilityRegistry {
        try MemoryHistoryWorkflow.runtimeCapabilities()
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
            category: configuration.category, publicationChannels: configuration.communication.publicationChannels,
            id: .memory, name: "Memory", inputs: configuration.communication.inputKinds,
            outputs: [.communication, .toolCall, .control],
            capabilities: try Self.runtimeCapabilities())
        taskCoordinator = AgentFixedTaskCoordinator(context: self.contextRepository)
        self.sessionID = sessionID
        let stream = AsyncStream<OutputEnvelope>.makeStream(
            bufferingPolicy: .bufferingOldest(MemorySignalPreprocessor.outputCapacity))
        outputs = stream.stream
        continuation = stream.continuation
    }

    // MARK: - Lifecycle

    public func receiveRequest(_ request: AgentProtocolRequest) async throws -> AgentRequestReply {
        let input = request.input
        guard case .observation(let message) = input.payload, message.operation == request.operation else {
            throw CommunicationError.invalidPayload
        }
        if request.operation == .status {
            guard let query = message.content(as: AgentTaskQuery.self) else { throw CommunicationError.invalidPayload }
            return try await taskCoordinator.requestStatus(query, input: input)
        }
        if request.operation == .cancel, let query = message.content(as: AgentTaskQuery.self) {
            _ = try await taskCoordinator.requestStatus(query, input: input)
            try await receive(AgentFixedTaskInput.cancellation(query, input: input))
            return AgentRequestReply(requestID: input.id, reference: query.scope.id)
        }
        guard let signal = message.content(as: AgentTaskSignal.self),
            (request.operation == .submit && signal.kind == .request)
                || ([.update, .answer].contains(request.operation) && signal.kind == .input)
                || (request.operation == .cancel && signal.kind == .cancel)
        else { throw CommunicationError.invalidPayload }
        try await receive(input)
        return AgentRequestReply(requestID: input.id, reference: signal.scope.id)
    }
    public func bindMessaging(_ messaging: AgentMessaging) async {
        await taskCoordinator.bindMessaging(messaging)
    }
    public func start() async throws {
        guard lifecycle == .registered else { throw HarnessError.invalidTransition }
        _ = try await contextRepository.snapshot()
        try await taskCoordinator.start()
        lifecycle = .running

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
        continuation.finish()
    }

    // MARK: - Input processing

    public func receive(_ input: AgentInput) async throws {

        if case .toolResult = input.payload { throw CommunicationError.invalidPayload }
        try await processInput(input)
    }

    func clearPending(for inputID: String) async throws {
        guard history.pendingInputID == inputID else { return }
        history.reset()
        try await contextRepository.update { $0.state.pendingRequestIDs.removeAll() }
    }

    public func completeFixedTask(inputID: String, value: String?, failure: String? = nil) async throws {
        guard let original = fixedTaskInputs.removeValue(forKey: inputID), let scope = original.taskScope else {
            return
        }
        if failure != nil { try await clearPending(for: original.id) }
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

public struct MemoryContextState: AgentTaskContextState {
    public static let agentID = AgentID.memory
    public static let configurationName = "Memory"

    public var taskViews: [String: AgentTaskView]?

    public var pendingRequestIDs: [String] = []
    public init() {}
    public func validateContextState() throws {
        try validateTaskState()
        guard pendingRequestIDs.count <= 1 else { throw CommunicationError.invalidPayload }
    }
    public mutating func recoverInterruptedWork() {
        recoverTaskState()
        pendingRequestIDs.removeAll()
    }
}

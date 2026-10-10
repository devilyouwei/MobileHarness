import Actions
import AgentCore
import Agents
import AppWorkflows
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import ModelKit
import Storage
import StorageChat
import Testing

private struct TaskFixtureState: AgentContextState {
    var dialogue: [String] = []
    var effects: [String] = []
    var receipts: [UUID] = []
    var reports: [AgentTaskSignal.Kind] = []
}
private actor TaskFixtureChat: ChatCapability {
    let availability: CapabilityAvailability = .available
    private(set) var requests: [ChatRequest] = []
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        requests.append(request)
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        try pair.emitter.yield(.text("child decision \(requests.count)"))
        try pair.emitter.yield(.finished(.stop))
        pair.emitter.finish()
        return pair.session
    }
}
private func taskFixtureConfiguration(parent: Bool) throws -> AgentConfiguration {
    let id = parent ? "taskParent" : "taskPhotographer"
    let peer = parent ? "taskPhotographer" : "taskParent"
    let accepted =
        parent
        ? ["task.progress", "task.result", "communication.receipt"]
        : [
            "task.request", "task.input", "task.cancel", "communication.receipt", "action.result",
            "generation.round.result",
        ]
    let sends = parent ? ["task.request", "task.input", "task.cancel"] : ["task.progress", "task.result"]
    let actions: [String: Any] =
        parent
        ? [:]
        : [
            "Camera": [
                [
                    "alias": "fixtureCapture",
                    "path": ["domain": "Fixture", "module": "Camera", "function": "capture"],
                    "parameters": [], "examples": ["<fixtureCapture/>"],
                    "doc": "Synthetic capture; no physical camera.",
                ]
            ]
        ]
    let inputs: [[String: Any]] = accepted.map { contract in
        let kind =
            contract == "communication.receipt"
            ? "communicationReceipt"
            : contract == "action.result"
                ? "actionResult" : contract == "generation.round.result" ? "roundResult" : "observation"
        return ["contract": contract, "version": 1, "kind": kind]
    }
    return try AgentConfiguration(
        contracts: AgentContracts.communication,
        data: JSONSerialization.data(withJSONObject: [
            "version": 6, "id": id, "actions": actions, "tools": [],
            "communication": [
                "inputs": inputs, "subscriptions": [], "publications": [],
                "sends": sends.map { ["contract": $0, "target": peer] },
            ],
        ]))
}

/// An independent model-backed child built only from shared mechanisms. No Assistant implementation is reused.
private actor TaskFixtureAgent: Agent {
    nonisolated let descriptor: AgentDescriptor
    nonisolated let outputs: AsyncStream<OutputEnvelope>
    private let output: AsyncStream<OutputEnvelope>.Continuation
    let context: AgentContextRepository<TaskFixtureState>
    private let model: TaskFixtureChat?
    private var lifecycle: AgentLifecycle = .registered
    private var worker: Task<Void, Never>?
    private var active: AgentInput?
    private var round: AgentRoundCoordinator?
    private var budget: AgentTaskBudget
    private var sequence: UInt64 = 0
    private var requestCalls: [UUID: UUID] = [:]
    init(configuration: AgentConfiguration, model: TaskFixtureChat? = nil) throws {
        descriptor = AgentDescriptor(
            id: configuration.agentID, name: configuration.agentID.rawValue,
            inputs: Set(configuration.communication.inputs.map(\.kind)),
            outputs: [.communication, .actionCall, .control],
            capabilities: configuration.capabilities)
        context = AgentContextRepository(agent: configuration.agentID, scope: UUID(), state: TaskFixtureState())
        self.model = model
        budget = try AgentTaskBudget()
        let pair = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(32))
        outputs = pair.stream
        output = pair.continuation
    }
    func start() { lifecycle = .running }
    func pause() { lifecycle = .paused }
    func resume() { lifecycle = .running }
    func stop() async {
        lifecycle = .stopped
        worker?.cancel()
        await worker?.value
        do {
            try await context.update {
                $0.tasks.recover()
                $0.recoverWork()
            }
        } catch { Issue.record("Synthetic stop context failed: \(error)") }
        output.finish()
    }
    func status() -> AgentStatus { .init(lifecycle: lifecycle, queuedInputs: 0, processedInputs: budget.requests) }
    func emit(_ action: AgentOutput, input: AgentInput, roundID: UUID? = nil, callID: UUID? = nil) throws {
        sequence += 1
        guard
            case .enqueued = output.yield(
                OutputEnvelope(
                    source: descriptor.id, input: input, output: action,
                    sequence: sequence, roundID: roundID, callID: callID))
        else { throw CommunicationError.capacityExceeded }
    }
    func send(_ signal: AgentTaskSignal, parent: AgentInput) async throws {
        let incoming = signal.kind == .request || signal.kind == .input || signal.kind == .cancel
        let action = try CommunicationAction(
            message: signal.message(), target: incoming ? signal.scope.executor : signal.scope.requester)
        if signal.kind == .request {
            try await context.update { try $0.tasks.register(signal.scope) }
            requestCalls[action.id] = signal.scope.id
        }
        try emit(.communication(action), input: parent)
        if model == nil { try emit(.control("agent.finished"), input: parent) }
    }
    func receive(_ input: AgentInput) async throws {
        guard lifecycle == .running else { throw HarnessError.notRunning }
        switch input.payload {
        case .communicationReceipt(let receipt):
            guard input.metadata.origin == .runtime, receipt.owner.agent == descriptor.id else {
                throw CommunicationError.unauthorized
            }
            let taskID = requestCalls.removeValue(forKey: receipt.callID)
            try await context.update { context in
                context.state.receipts.append(receipt.callID)
                if let taskID {
                    try context.tasks.acknowledge(
                        taskID, accepted: receipt.report.rejected.isEmpty && !receipt.report.delivered.isEmpty)
                }
            }
        case .observation(let message):
            guard let task = message.content(as: AgentTaskSignal.self) else { throw CommunicationError.invalidPayload }
            let agentID = descriptor.id
            try await context.update { context in
                try context.tasks.accept(task, input: input, agent: agentID)
                context.state.reports.append(task.kind)
                if task.kind == .request { context.state.dialogue.append(String(decoding: task.data, as: UTF8.self)) }
            }
            if task.kind == .request {
                active = input
                worker = Task { await drive(input) }
            } else if task.kind == .cancel {
                round?.cancel()
                worker?.cancel()
                await worker?.value
                let result = try AgentTaskSignal(
                    kind: .result, scope: task.scope, businessContract: "fixture.photo", data: Data(),
                    status: .cancelled)
                try await context.update { try $0.tasks.report(result, agent: agentID) }
                if input.metadata.origin != .runtime { try await send(result, parent: active ?? input) }

            }
        case .actionResult(let result):
            guard input.metadata.origin == .runtime, result.owner.agent == descriptor.id,
                input.metadata.parentID == active?.id, let callID = result.callID, let roundID = result.roundID
            else { throw CommunicationError.unauthorized }
            try round?.accept(callID: callID, roundID: roundID)
            let value: String
            if case .value(let text) = result.completion { value = text } else { value = result.status.rawValue }
            try await context.update { $0.state.effects.append(value) }
        case .roundResult(let result):
            guard input.metadata.origin == .runtime, result.roundID == round?.id, result.failure == nil,
                round?.complete == true, let active
            else { throw CommunicationError.unauthorized }
            worker = Task { await drive(active) }
        default: throw HarnessError.unsupportedInput
        }
    }
    private func drive(_ input: AgentInput) async {
        defer { worker = nil }
        do {
            guard let model, let scope = input.taskScope else { throw CommunicationError.invalidPayload }
            try budget.reserveRequest()
            let snapshot = try await context.snapshot()
            let messages =
                snapshot.state.dialogue.map { ChatMessage(role: .user, content: $0) }
                + snapshot.state.effects.map { ChatMessage(role: .user, content: "Own observation: " + $0) }
            let decision = UUID()
            let text = try await AgentChatDriver.collect(
                ChatRequest(
                    messages: messages,
                    context: InferenceContext(requestID: decision, conversationID: scope.id)), using: model,
                consumers: .init(
                    text: { fragments in
                        var text = ""
                        for try await part in fragments { text += part }
                        return text
                    }, native: { calls in for try await _ in calls { throw CommunicationError.invalidPayload } },
                    evidence: { _ in }))
            try await context.update { $0.state.dialogue.append(text) }
            if budget.requests == 1 {
                let progress = try AgentTaskSignal(
                    kind: .progress, scope: scope, businessContract: "fixture.photo",
                    data: Data("accepted photo task".utf8))
                try await send(progress, parent: input)
                let call = try descriptor.capabilities.resolveAction("fixtureCapture", parameters: [:])
                let id = UUID()
                round = AgentRoundCoordinator(id: decision, taskID: scope.id)
                try round?.register(id: id, policy: .observation)
                try round?.seal()
                try emit(.actionCall(call), input: input, roundID: decision, callID: id)
                try emit(.roundFinished(decision), input: input, roundID: decision)
            } else {
                let result = try AgentTaskSignal(
                    kind: .result, scope: scope, businessContract: "fixture.photo",
                    data: Data(text.utf8), status: .succeeded)
                let agentID = descriptor.id
                try await context.update { try $0.tasks.report(result, agent: agentID) }
                try await send(result, parent: input)
                try emit(.control("agent.finished"), input: input)
            }
        } catch is CancellationError {} catch {
            Issue.record("Synthetic child decision failed: \(error)")
            try? emit(.control("agent.error: \(error)"), input: input)
        }
    }
}
private struct TaskFixtureActions: ActionModule { let definitions: [ActionBinding] }
private func waitForArchitecture(_ condition: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(try await condition()) {
        guard ContinuousClock.now < deadline else { throw CommunicationError.expired }
        try await Task.sleep(for: .milliseconds(2))
    }
}

@Test(.timeLimit(.minutes(1))) func taskChildOwnsActionResultsChatHistoryAndExplicitParentReports() async throws {
    let parentConfig = try taskFixtureConfiguration(parent: true)
    let childConfig = try taskFixtureConfiguration(parent: false)
    let model = TaskFixtureChat()
    let parent = try TaskFixtureAgent(configuration: parentConfig)
    let child = try TaskFixtureAgent(configuration: childConfig, model: model)
    let manager = AgentManager()
    try await manager.register(parent)
    try await manager.register(child)
    await parent.start()
    await child.start()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, configurations: [parentConfig, childConfig])
    let input = InputGateway(manager: manager, policy: policy, allowsExternalSend: true)
    let definition = ActionBinding(
        path: .init(domain: "Fixture", module: "Camera", function: "capture"),
        displayName: "Synthetic photo", kind: .finite, completion: "Synthetic fixture value.",
        completing: { invocation in
            #expect(invocation.context.source == "taskPhotographer")
            #expect(invocation.context.taskExecutor == "taskPhotographer")
            return .value("one actual fixture effect")
        })
    let scheduler = ChannelScheduler(
        registry: try ActionRegistry(modules: [TaskFixtureActions(definitions: [definition])])
    ) {
        await input.deliverActionResult($0)
    }
    let gateway = OutputGateway(
        manager: manager, requests: input, tools: ToolRegistry(), actions: scheduler, policy: policy, sink: { _ in })
    let parentPump = Task {
        try await IndependentOutputWorkflow.consumeSignals(parent.outputs) { _ = try await gateway.execute($0) }
    }
    let childPump = Task {
        try await IndependentOutputWorkflow.consumeGeneration(child.outputs) { _ = try await gateway.execute($0) }
    }
    let root = AgentInput(sessionID: UUID(), payload: .text("parent user input"))
    let scope = AgentTaskScope(
        parentID: root.id, requester: parent.descriptor.id, executor: child.descriptor.id, sessionID: root.sessionID)
    try await parent.send(
        AgentTaskSignal(
            kind: .request, scope: scope, businessContract: "fixture.photo", data: Data("take one photo".utf8)),
        parent: root)
    do {
        try await waitForArchitecture { try await parent.context.snapshot().tasks.task(scope.id)?.state == .succeeded }
    } catch {
        Issue.record(
            "Parent: \(try await parent.context.snapshot().state); child: \(try await child.context.snapshot().state); executions: \(await gateway.executionResults())"
        )
        await manager.stopAll()
        await gateway.shutdown()
        parentPump.cancel()
        childPump.cancel()
        _ = await parentPump.result
        _ = await childPump.result
        throw error
    }
    let parentContext = try await parent.context.snapshot()
    let childContext = try await child.context.snapshot()
    #expect(parentContext.state.dialogue.isEmpty && parentContext.state.effects.isEmpty)
    #expect(parentContext.state.reports == [.progress, .result])
    #expect(childContext.state.effects == ["one actual fixture effect"])
    #expect(childContext.tasks.task(scope.id)?.state == .succeeded)
    #expect(await model.requests.count == 2)
    let requests = await model.requests
    #expect(requests.last?.messages.contains { $0.content == "Own observation: one actual fixture effect" } == true)
    #expect(requests.allSatisfy { !$0.messages.contains { $0.content == "parent user input" } })
    #expect(await scheduler.executionSnapshot().records.count == 1)
    await #expect(throws: CommunicationError.scopeClosed) {
        try await manager.validateTask(scope, agent: child.descriptor.id, sessionID: scope.sessionID)
    }
    await manager.stopAll()
    await gateway.shutdown()
    parentPump.cancel()
    childPump.cancel()
    _ = await parentPump.result
    _ = await childPump.result
}

@Test func ownedContextImportIsOnceAtomicAndRestartsInterruptWithoutReplay() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("history.json")
    let legacy = ConversationHistoryStore(
        document: try LocalDocumentStore(url: source, maximumBytes: ConversationHistoryStore.maximumBytes))
    let id = UUID()
    let token = try await legacy.readCurrent().token
    _ = try await legacy.begin(
        id: id, user: "retained input", request: [.init(role: .user, content: "retained input")], expecting: token,
        model: "fixture")
    try await legacy.append("partial", to: id)
    let original = try Data(contentsOf: source)
    let scope = UUID()
    let url = directory.appendingPathComponent("assistant.context.json")
    let repository = try AgentContextRepository.persistent(
        agent: .assistant, scope: scope, state: AssistantContextState(), url: url)
    let projected = AssistantHistoryContext.store(repository: repository, legacy: legacy)
    #expect(try await projected.snapshot().current.turns.first?.state == .interrupted)
    #expect(try await repository.snapshot().state.historyImported)
    let read = try await projected.readCurrent()
    let newID = UUID()
    _ = try await projected.begin(
        id: newID, user: "another input", request: [.init(role: .user, content: "another input")],
        expecting: read.token, model: "fixture")
    #expect(try Data(contentsOf: source) == original)
    let restarted = try AgentContextRepository.persistent(
        agent: .assistant, scope: scope, state: AssistantContextState(), url: url)
    let recovered = try await restarted.snapshot()
    #expect(recovered.state.history.current.turns.last?.state == .interrupted)
    #expect(recovered.state.history.current.turns.first?.raw == "partial")
    let foreign = try AgentContextRepository.persistent(
        agent: .assistant, scope: UUID(), state: AssistantContextState(), url: url)
    await #expect(throws: CommunicationError.invalidPayload) { _ = try await foreign.snapshot() }
}

@Test func signalInboxFusionOwnershipExpiryAndRoundBudgetAreBounded() throws {
    let session = UUID()
    let root = UUID()
    func input(_ text: String, rootID: UUID = UUID()) -> AgentInput {
        let payload = InputPayload.text(text)
        return AgentInput(
            sessionID: session, payload: payload, metadata: InputMetadata(payload: payload, rootID: rootID))
    }
    var inbox = try SignalInbox(capacity: 2)
    let first = input("a", rootID: root)
    let second = input("b", rootID: root)
    #expect(try inbox.admit(first, disposition: .merge(key: "observations")) == 1)
    #expect(try inbox.admit(second, disposition: .merge(key: "observations")) == 2)
    #expect(throws: CommunicationError.capacityExceeded) {
        try inbox.admit(input("overflow"), disposition: .enqueue(priority: 0))
    }
    #expect(inbox.takeBatch().map(\.input.id) == [first.id, second.id])
    try inbox.admit(input("other task"), disposition: .merge(key: "observations"))
    try inbox.admit(input("separate task"), disposition: .merge(key: "observations"))
    #expect(inbox.takeBatch().count == 1 && inbox.count == 1)
    var budget = try AgentTaskBudget()
    try budget.reserveRequest()
    try budget.charge(.seconds(10))
    try budget.reserveRequest()
    try budget.charge(.seconds(10))
    #expect(budget.remainingExecution == .seconds(10))
    try budget.reserveRequest()
    try budget.reserveRequest()
    #expect(throws: CommunicationError.capacityExceeded) { try budget.reserveRequest() }
    for _ in 0..<16 { try budget.reserveNativeCall() }
    #expect(throws: CommunicationError.capacityExceeded) { try budget.reserveNativeCall() }
    #expect(throws: CommunicationError.expired) { try budget.charge(.seconds(11)) }
    var round = AgentRoundCoordinator(taskID: root)
    let call = UUID()
    try round.register(id: call, policy: .observation)
    try round.seal()
    #expect(!round.complete)
    try round.accept(callID: call, roundID: round.id)
    #expect(round.needsObservation)
    #expect(throws: CommunicationError.unauthorized) { try round.accept(callID: call, roundID: round.id) }
    round.cancel()
    #expect(!round.needsObservation)
}

@Test func rollingContextEvidenceRejectsDuplicatesBeforeEviction() throws {
    var context = AgentContext(agentID: .assistant, scopeID: UUID(), state: TaskFixtureState())
    let first = try AgentContext<TaskFixtureState>.Record(kind: "first")
    let second = try AgentContext<TaskFixtureState>.Record(kind: "second")
    try context.append(first, retainingLast: 2)
    try context.append(second, retainingLast: 2)
    #expect(throws: CommunicationError.outOfOrder) { try context.append(first, retainingLast: 2) }
    #expect(context.records == [first, second] && context.evictedRecordCount == nil)
    let third = try AgentContext<TaskFixtureState>.Record(kind: "third")
    try context.append(third, retainingLast: 2)
    #expect(context.records == [second, third] && context.evictedRecordCount == 1)
    let batch = try SignalBatch(taskID: UUID(), signalIDs: [UUID()], admissionSequence: 1)
    try context.consume(batch, retainingLast: 1)
    #expect(throws: CommunicationError.capacityExceeded) { try context.consume(batch, retainingLast: 1) }
    #expect(context.consumedBatches == [batch] && context.evictedBatchCount == nil)
    let next = try SignalBatch(taskID: UUID(), signalIDs: [UUID()], admissionSequence: 2)
    try context.consume(next, retainingLast: 1)
    #expect(context.consumedBatches == [next] && context.evictedBatchCount == 1)
}

@Test func replyIdentitySurvivesNewRecognitionAndRequiresChildGrant() {
    let session = UUID()
    let old = AgentTurn(ordinal: 1)
    let new = AgentTurn(ordinal: 2)
    let round = UUID()
    let childTask = UUID()
    var presentation = ConversationPresentation()
    func context(_ source: String, _ turn: AgentTurn, _ seq: UInt64, task: Bool = false) -> ActionExecutionContext {
        ActionExecutionContext(
            source: source, sessionID: session, inputID: UUID(), sequence: seq,
            correlationID: turn.id, ordinal: turn.ordinal, decisionID: round,
            taskID: task ? childTask : nil, taskExecutor: task ? source : nil)
    }
    let accepted1 = presentation.accept(context("speechPerception", new, 1), update: .transcript)
    #expect(accepted1)
    let accepted2 = presentation.accept(context("assistant", old, 1), update: .beginReply)
    #expect(accepted2)
    let accepted3 = presentation.accept(context("assistant", old, 2), update: .reply)
    #expect(accepted3)
    #expect(presentation.turn == new && presentation.replyTurn == old)
    let accepted4 = !presentation.accept(context("taskPhotographer", old, 1), update: .beginReply)
    #expect(accepted4)
    let accepted5 = presentation.accept(context("taskPhotographer", old, 1, task: true), update: .beginReply)
    #expect(accepted5)
    let accepted6 = presentation.accept(context("taskPhotographer", old, 2, task: true), update: .reply)
    #expect(accepted6)
    let accepted7 = !presentation.accept(context("assistant", old, 3), update: .reply)
    #expect(accepted7)
}

@Test func boundOutputRejectsStoppedProducerAndTaskCancellationRejectsNewEffects() async throws {
    let configuration = try taskFixtureConfiguration(parent: true)
    let childConfiguration = try taskFixtureConfiguration(parent: false)
    let parent = try TaskFixtureAgent(configuration: configuration)
    let child = try TaskFixtureAgent(configuration: childConfiguration)
    let manager = AgentManager()
    try await manager.register(parent)
    try await manager.register(child)
    let session = UUID()
    let scope = AgentTaskScope(requester: parent.descriptor.id, executor: child.descriptor.id, sessionID: session)
    try await manager.grantTask(scope, sender: parent.descriptor.id)
    try await manager.validateTaskInput(scope, agent: child.descriptor.id)
    await #expect(throws: CommunicationError.unauthorized) {
        try await manager.cancelTask(scope, requester: child.descriptor.id)
    }
    try await manager.cancelTask(scope, requester: parent.descriptor.id)
    await #expect(throws: CommunicationError.scopeClosed) {
        try await manager.validateTaskInput(scope, agent: child.descriptor.id)
    }
    await #expect(throws: CommunicationError.scopeClosed) {
        try await manager.registerExecution(UUID(), scope: scope, agent: child.descriptor.id)
    }
    let gateway = OutputGateway(
        manager: manager, requests: InputGateway(manager: manager, allowsExternalSend: true), tools: ToolRegistry(),
        sink: { _ in })
    let consumer = try await gateway.consumer(for: parent)
    let late = OutputEnvelope(
        source: parent.descriptor.id,
        input: AgentInput(sessionID: session, payload: .text("late")), output: .control("agent.finished"), sequence: 1)
    try await manager.remove(parent.descriptor.id)
    let replacement = try TaskFixtureAgent(configuration: configuration)
    try await manager.register(replacement)
    await #expect(throws: CommunicationError.staleIncarnation) { _ = try await consumer.execute(late) }
    await #expect(throws: CommunicationError.staleIncarnation) { _ = try await gateway.consumer(for: parent) }
    await #expect(throws: CommunicationError.scopeClosed) {
        try await manager.validateTask(scope, agent: child.descriptor.id, sessionID: session)
    }
    await gateway.shutdown()
    await manager.stopAll()
}

@Test func failedCommunicationReceiptDoesNotCompleteRemoteTask() async throws {
    let parentConfiguration = try taskFixtureConfiguration(parent: true)
    let childConfiguration = try taskFixtureConfiguration(parent: false)
    let parent = try TaskFixtureAgent(configuration: parentConfiguration)
    let manager = AgentManager()
    try await manager.register(parent)
    await parent.start()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, configurations: [parentConfiguration, childConfiguration])
    let input = InputGateway(manager: manager, policy: policy, allowsExternalSend: true)
    let gateway = OutputGateway(
        manager: manager, requests: input, tools: ToolRegistry(), policy: policy, sink: { _ in })
    let root = AgentInput(sessionID: UUID(), payload: .text("delegation"))
    let scope = AgentTaskScope(
        requester: parent.descriptor.id, executor: childConfiguration.agentID, sessionID: root.sessionID)
    try await parent.send(
        AgentTaskSignal(kind: .request, scope: scope, businessContract: "fixture.photo", data: Data()), parent: root)
    var iterator = parent.outputs.makeAsyncIterator()
    let envelope = try #require(await iterator.next())
    let consumer = try await gateway.consumer(for: parent)
    _ = try await consumer.execute(envelope)
    let snapshot = try await parent.context.snapshot()
    #expect(snapshot.state.receipts.count == 1)
    #expect(snapshot.tasks.task(scope.id)?.state == .failed)
    #expect(!snapshot.state.reports.contains(.result))
    await gateway.shutdown()
    await manager.stopAll()
}

@Test func communicationReceiptsAreBoundedDeduplicatedAndFailedWritesDoNotAcknowledge() async throws {
    let receipts = CommunicationReceipts()
    let ids = (0..<16).map { _ in UUID() }
    for id in ids { try await receipts.register(id) }
    await #expect(throws: CommunicationError.capacityExceeded) { try await receipts.register(UUID()) }
    let result = CommunicationReceipt(
        callID: ids[0], report: .init(delivered: [.assistant]),
        owner: ExecutionOwner(agent: .assistant, incarnation: UUID(), sessionID: UUID()), causality: .root())
    await #expect(throws: CommunicationError.invalidPayload) {
        try await receipts.accept(result) { throw CommunicationError.invalidPayload }
    }
    await #expect(throws: CommunicationError.unauthorized) { try await receipts.accept(result) }
    await #expect(throws: CommunicationError.invalidPayload) { _ = try await receipts.wait(ids[0]) }
    let next = UUID()
    try await receipts.register(next)
    let accepted = CommunicationReceipt(
        callID: next, report: .init(delivered: [.assistant]), owner: result.owner, causality: result.causality)
    try await receipts.accept(accepted)
    #expect(try await receipts.wait(next).delivered == [.assistant])
    await receipts.close()
    await #expect(throws: CommunicationError.scopeClosed) { _ = try await receipts.wait(ids[1]) }
}

@Test func contextRejectedCommitAndCorruptStateLeaveNoWritableFallback() async throws {
    let repository = AgentContextRepository(
        agent: .assistant, scope: UUID(), state: AssistantContextState(),
        persistence: .init(load: { nil }, commit: { _, _ in throw CommunicationError.invalidPayload }))
    let input = AgentInput(sessionID: UUID(), payload: .text("Persist before processing"))
    await #expect(throws: CommunicationError.invalidPayload) {
        try await repository.recordSignal(
            input, disposition: .enqueue(priority: 0), admissionSequence: 1, consumed: true
        ) { try $0.beginWork(input.id, sessionID: input.sessionID) }
    }
    let uncommitted = try await repository.snapshot()
    #expect(uncommitted.work.isEmpty && uncommitted.records.isEmpty && uncommitted.consumedBatches.isEmpty)
    #expect(uncommitted.revision == 0)
    let agent = AgentID.assistant
    let scope = UUID()
    let invalid = AgentContext(agentID: agent, scopeID: scope, state: AssistantContextState())
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(invalid)) as? [String: Any])
    object["version"] = 99
    let saved = try JSONDecoder().decode(
        AgentContext<AssistantContextState>.self, from: JSONSerialization.data(withJSONObject: object))
    let corrupt = AgentContextRepository(
        agent: agent, scope: scope, state: AssistantContextState(),
        persistence: .init(load: { saved }, commit: { _, _ in Issue.record("Corrupt state must never commit") }))
    await #expect(throws: CommunicationError.invalidPayload) { _ = try await corrupt.snapshot() }
    await #expect(throws: CommunicationError.invalidPayload) { try await corrupt.update { _ in } }
}

private actor TaskStopProbe {
    var started = false
    var cancelled = false
    func run() async throws -> ActionCompletion {
        started = true
        do {
            try await Task.sleep(for: .seconds(60))
            return .completed
        } catch {
            cancelled = true
            throw error
        }
    }
}
@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func parentOrChildStopJoinsEffectsAndRecordsDistinctTerminal(_ stopParent: Bool) async throws {
    let parentConfiguration = try taskFixtureConfiguration(parent: true)
    let childConfiguration = try taskFixtureConfiguration(parent: false)
    let parent = try TaskFixtureAgent(configuration: parentConfiguration)
    let model = TaskFixtureChat()
    let child = try TaskFixtureAgent(configuration: childConfiguration, model: model)
    let probe = TaskStopProbe()
    let manager = AgentManager()
    try await manager.register(parent)
    try await manager.register(child)
    await parent.start()
    await child.start()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, configurations: [parentConfiguration, childConfiguration])
    let input = InputGateway(manager: manager, policy: policy, allowsExternalSend: true)
    let definition = ActionBinding(
        path: .init(domain: "Fixture", module: "Camera", function: "capture"),
        displayName: "Synthetic held effect", kind: .finite, completion: "Cancellation fixture.",
        completing: { _ in try await probe.run() })
    let scheduler = ChannelScheduler(
        registry: try ActionRegistry(modules: [TaskFixtureActions(definitions: [definition])])
    ) {
        await input.deliverActionResult($0)
    }
    let gateway = OutputGateway(
        manager: manager, requests: input, tools: ToolRegistry(), actions: scheduler, policy: policy, sink: { _ in })
    let parentConsumer = try await gateway.consumer(for: parent)
    let childConsumer = try await gateway.consumer(for: child)
    let parentPump = Task {
        try await IndependentOutputWorkflow.consumeSignals(parent.outputs) { _ = try await parentConsumer.execute($0) }
    }
    let childPump = Task {
        try await IndependentOutputWorkflow.consumeGeneration(child.outputs) { _ = try await childConsumer.execute($0) }
    }
    let root = AgentInput(sessionID: UUID(), payload: .text("stop child task"))
    let scope = AgentTaskScope(
        parentID: root.id, requester: parent.descriptor.id, executor: child.descriptor.id, sessionID: root.sessionID)
    try await parent.send(
        AgentTaskSignal(kind: .request, scope: scope, businessContract: "fixture.photo", data: Data()), parent: root)
    try await waitForArchitecture { await probe.started }
    try await manager.stop(stopParent ? parent.descriptor.id : child.descriptor.id)
    #expect(await probe.cancelled)
    if stopParent {
        #expect(try await child.context.snapshot().tasks.task(scope.id)?.state == .cancelled)
        #expect(try await parent.context.snapshot().tasks.task(scope.id)?.state == .interrupted)
    } else {
        #expect(try await parent.context.snapshot().tasks.task(scope.id)?.state == .failed)
    }
    if stopParent {
        #expect(try await child.context.snapshot().state.effects.allSatisfy { $0 == "cancelled" })
    } else {
        #expect(try await child.context.snapshot().state.effects.isEmpty)
    }
    #expect(await model.requests.count == 1)
    let actions = await scheduler.executionSnapshot().records
    #expect(actions.count == 1 && actions.first?.phase == .cancelled)
    await manager.stopAll()
    await gateway.shutdown()
    parentPump.cancel()
    childPump.cancel()
    _ = await parentPump.result
    _ = await childPump.result
}

@Test func deletedHistoryErasesItsOwnedSignalEvidenceAndProtectsActiveWork() async throws {
    let store = ConversationHistoryStore()
    let repository = AgentContextRepository(agent: .assistant, scope: UUID(), state: AssistantContextState())
    try await AssistantHistoryContext.attach(repository: repository, store: store)
    let id = UUID()
    let token = try await store.readCurrent().token
    _ = try await store.begin(
        id: id, user: "private archived text", request: [.init(role: .user, content: "private archived text")],
        expecting: token, model: "fixture")
    try await repository.update {
        try $0.beginWork(id, sessionID: UUID())
        try $0.append(.init(taskID: id, kind: "text", data: Data("private archived text".utf8)))
    }
    await #expect(throws: CommunicationError.scopeClosed) {
        try await repository.update { try $0.eraseEvidence(for: [id]) }
    }
    try await repository.update { try $0.transitionWork(id, to: .completed) }
    try await store.finish(id, state: .completed)
    let archived = try #require(try await store.startNew())
    try await store.deleteArchived(archived.id)
    let context = try await repository.snapshot()
    #expect(context.state.history.past.isEmpty && context.records.isEmpty && context.work[id] == nil)
}

@Test func duplicateTaskRequestCannotRevokeThePreviouslyAcceptedGrant() async throws {
    let parentConfiguration = try taskFixtureConfiguration(parent: true)
    let childConfiguration = try taskFixtureConfiguration(parent: false)
    let parent = try TaskFixtureAgent(configuration: parentConfiguration)
    let child = try TaskFixtureAgent(configuration: childConfiguration)
    let manager = AgentManager()
    try await manager.register(parent)
    try await manager.register(child)
    await parent.start()
    await child.start()
    let root = AgentInput(sessionID: UUID(), payload: .text("duplicate admission"))
    let scope = AgentTaskScope(
        requester: parent.descriptor.id, executor: child.descriptor.id, sessionID: root.sessionID)
    try await manager.grantTask(scope, sender: parent.descriptor.id)
    try await parent.context.update { try $0.tasks.register(scope) }
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, configurations: [parentConfiguration, childConfiguration])
    let gateway = OutputGateway(
        manager: manager, requests: InputGateway(manager: manager, policy: policy, allowsExternalSend: true),
        tools: ToolRegistry(),
        policy: policy, sink: { _ in })
    let duplicate = try AgentTaskSignal(kind: .request, scope: scope, businessContract: "fixture.photo", data: Data())
    try await parent.emit(
        .communication(CommunicationAction(message: duplicate.message(), target: child.descriptor.id)), input: root)
    var iterator = parent.outputs.makeAsyncIterator()
    let envelope = try #require(await iterator.next())
    let consumer = try await gateway.consumer(for: parent)
    _ = try await consumer.execute(envelope)
    try await manager.validateTaskInput(scope, agent: child.descriptor.id)
    #expect(try await parent.context.snapshot().tasks.task(scope.id)?.state == .requested)
    #expect(try await child.context.snapshot().state.reports.isEmpty)
    await manager.retireTask(scope.id)
    await gateway.shutdown()
    await manager.stopAll()
}

private actor HeldAdmissionCommit {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        guard !started else { return }
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@Test(.timeLimit(.minutes(1)))
func concurrentEnvironmentFactsWaitForStateCommitInsteadOfRejectingAsCapacity() async throws {
    let session = UUID()
    let held = HeldAdmissionCommit()
    let context = AgentContextRepository(
        agent: .applicationControl, scope: UUID(), state: ApplicationControlContextState(),
        persistence: .init(
            load: { nil },
            commit: { value, _ in
                if value.records.contains(where: { $0.kind == AppEnvironmentFact.contract }) { await held.hold() }
            }))
    let agent = try ApplicationControlAgent(sessionID: session, context: context)
    try await agent.start()
    let first = Task {
        try await agent.receive(
            AppEnvironmentFact(category: .scene, sequence: 1, value: "active").input(sessionID: session))
    }
    while !(await held.started) { await Task.yield() }
    let second = Task {
        try await agent.receive(
            AppEnvironmentFact(category: .devices, sequence: 1, value: "camera").input(sessionID: session))
    }
    await Task.yield()
    await held.release()
    try await first.value
    try await second.value
    let state = try await context.snapshot()
    #expect(state.records.filter { $0.kind == AppEnvironmentFact.contract }.count == 2)
    #expect(await agent.status().lifecycle == .running)
    await agent.stop()
}

@Test func admissionGateCancelsAndClosesWaitingInputsWithoutLeakingPermit() async throws {
    let gate = AgentAdmissionGate(capacity: 2)
    try await gate.acquire()
    let waiting = Task {
        try await gate.acquire()
        defer { gate.release() }
        try Task.checkCancellation()
    }
    waiting.cancel()
    await #expect(throws: CancellationError.self) { try await waiting.value }
    gate.release()
    try await gate.acquire()
    let stopped = Task {
        try await gate.acquire()
        gate.release()
    }
    gate.close()
    await #expect(throws: HarnessError.notRunning) { try await stopped.value }
    gate.release()
}

@Test func communicationCatalogDefinesRequestKindsAndExcludesTelemetryPublish() throws {
    let configuration = try AgentConfigurations.load(named: "Assistant")
    for role in try AgentConfigurations.all() {
        let catalog = try AgentCommunicationAdapter.catalog(role.capabilities, policy: role.communication)
        #expect(catalog.tools.map(\.path) == role.capabilities.tools.map(\.path))
        #expect(!catalog.tools.contains { $0.alias == "Agent.send" || $0.path.hasPrefix("Agent.Communication.") })
        #expect(
            catalog.actions.contains { $0.alias == "send" }
                == role.communication.sends.contains { $0.contract.hasPrefix("task.") })
    }
    let catalog = try AgentCommunicationAdapter.catalog(configuration.capabilities, policy: configuration.communication)
    let send = try #require(catalog.actions.first { $0.alias == "send" })
    #expect(!catalog.actions.contains { $0.alias == "publish" })
    #expect(send.documentation?.doc.contains("request") == true)
    let invalid = try CapabilityRegistry(tools: [
        ToolRegistration(alias: "Agent.send", path: "Agent.Communication.send")
    ])
    #expect(throws: CommunicationError.invalidPayload) {
        try AgentCommunicationAdapter.catalog(invalid, policy: configuration.communication)
    }
    #expect(throws: CommunicationError.invalidPayload) {
        try AgentCommunicationAdapter.action(
            path: "Agent.Communication.send",
            arguments: ["kind": "task", "target": "photographer", "content": "关闭摄像头"], sender: .assistant,
            input: .init(sessionID: UUID(), payload: .text("close")), policy: configuration.communication)
    }
}

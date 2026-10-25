import Actions
import AgentCore
import Agents
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import ModelKit
import PlatformKit
import StorageChat
import StorageCore
import Testing

private struct TaskFixtureState: AgentContextState {
    var dialogue: [String] = []
    var effects: [String] = []
    var receipts: [String] = []
    var reports: [AgentTaskSignal.Kind] = []
}

/// A decoded durable snapshot already at both Core evidence limits; no user data is used.
func saturatedEvidenceContext<State: AgentContextState>(agent: AgentID, state: State) throws -> AgentContext<State> {
    let seed = AgentContext(agentID: agent, scopeID: UUID().uuidString, state: state)
    let records = try (0..<8192).map { _ in
        try AgentContext<State>.Record(kind: "fixture.evidence")
    }
    let batches = try records.enumerated().map { index, record in
        try SignalBatch(
            taskID: UUID().uuidString, signalIDs: [record.id], admissionSequence: UInt64(index + 1))
    }
    var wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(seed)) as? [String: Any])
    wire["records"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(records))
    wire["consumedBatches"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(batches))
    let decoded = try JSONDecoder().decode(
        AgentContext<State>.self, from: JSONSerialization.data(withJSONObject: wire))
    try decoded.validate(agent: agent, scope: seed.scopeID)
    return decoded
}

extension LiveRuntimeTests {
    @Test(.actionCatalog, .timeLimit(.minutes(1)))
    func saturatedApplicationControlContextRetainsEvidenceAndKeepsSettingsAvailable() async throws {
        let seed = try saturatedEvidenceContext(agent: .applicationControl, state: ApplicationControlContextState())
        var defaultPolicy = seed
        #expect(throws: CommunicationError.capacityExceeded) {
            try defaultPolicy.append(.init(kind: "fixture.overflow"))
        }
        let context = try AgentContextRepository(
            agent: seed.agentID, scope: seed.scopeID, state: seed.state,
            persistence: .init(load: { seed }, commit: { _, _ in })
        )
        let session = UUID().uuidString
        let agent = try ApplicationControlAgent(sessionID: session, context: context)
        try await agent.start()
        try await agent.receive(
            AppEnvironmentFact(category: .scene, sequence: 1, value: "active").input(sessionID: session))
        let first = try await context.snapshot()
        #expect(first.records.count == 4096 && first.consumedBatches.count == 4096)
        #expect(first.evictedRecordCount == 4097 && first.evictedBatchCount == 4097)
        #expect(first.records.first?.id == seed.records[4097].id)
        #expect(first.state.environmentContracts == ["scene"])
        try await agent.receive(ModelResourceIntent.restoreSource.input(sessionID: session))
        var outputs = agent.outputs.makeAsyncIterator()
        let output = try #require(await outputs.next())
        guard case .toolCall(let call) = output.output else {
            Issue.record("Expected model preferences restoration")
            await agent.stop()
            return
        }
        #expect(call.toolPath == "System.ModelResources.restoreSource")
        let second = try await context.snapshot()
        #expect(second.records.count == 4096 && second.consumedBatches.count == 4096)
        #expect(second.evictedRecordCount == 4098 && second.evictedBatchCount == 4098)
        #expect(second.state.pendingCallIDs == [call.id])
        #expect(await agent.status().lifecycle == .running)
        await agent.stop()
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog, .timeLimit(.minutes(1)))
    func saturatedMemoryContextKeepsHistoryRefreshAvailable() async throws {
        let seed = try saturatedEvidenceContext(agent: .memory, state: MemoryContextState())
        let context = try AgentContextRepository(
            agent: seed.agentID, scope: seed.scopeID, state: seed.state,
            persistence: .init(load: { seed }, commit: { _, _ in })
        )
        let session = UUID().uuidString
        let agent = try MemoryAgent(sessionID: session, context: context)
        try await agent.start()
        var outputs = agent.outputs.makeAsyncIterator()
        for _ in 0..<2 {
            try await agent.receive(MemoryHistoryIntent.refresh.input(sessionID: session))
            let output = try #require(await outputs.next())
            guard case .toolCall(let call) = output.output else {
                Issue.record("Expected history presentation")
                await agent.stop()
                return
            }
            #expect(call.toolPath == "UI.HistoryPresentation.showHistory")
        }
        let snapshot = try await context.snapshot()
        #expect(snapshot.records.count == 4096 && snapshot.consumedBatches.count == 4096)
        #expect(snapshot.evictedRecordCount == 4098 && snapshot.evictedBatchCount == 4098)
        #expect(snapshot.state.pendingRequestIDs.isEmpty)
        #expect(await agent.status().lifecycle == .running)
        await agent.stop()
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog, .timeLimit(.minutes(1)))
    func saturatedPhotographerContextPreservesAdmittedCameraRequest() async throws {
        let seed = try saturatedEvidenceContext(agent: .photographer, state: PhotographerContextState())
        let context = try AgentContextRepository(
            agent: seed.agentID, scope: seed.scopeID, state: seed.state,
            persistence: .init(load: { seed }, commit: { _, _ in })
        )
        let session = UUID().uuidString
        let agent = try PhotographerAgent(sessionID: session, context: context)
        try await agent.start()
        let intent = PhotographerCameraIntent(.open, requestID: UUID().uuidString)
        try await agent.receive(intent.input(sessionID: session))
        var outputs = agent.outputs.makeAsyncIterator()
        let output = try #require(await outputs.next())
        guard case .toolCall(let call) = output.output else {
            Issue.record("Expected admitted camera call")
            await agent.stop()
            return
        }
        #expect(call.toolPath == "Camera.Capture.open" && call.id == intent.requestID)
        let first = try await context.snapshot()
        #expect(first.records.count == 4096 && first.consumedBatches.count == 4096)
        #expect(first.evictedRecordCount == 4097 && first.evictedBatchCount == 4097)
        #expect(first.state.cameraRequestID == intent.requestID)
        try await agent.receive(
            PhotographerCameraIntent(.cancel, requestID: intent.requestID).input(sessionID: session))
        let second = try await context.snapshot()
        #expect(second.evictedRecordCount == 4098 && second.evictedBatchCount == 4098)
        #expect(second.state.cameraRequestID == nil)
        #expect(await agent.status().lifecycle == .running)
        await agent.stop()
    }
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
    private var requestCalls: [String: String] = [:]
    init(configuration: AgentConfiguration, model: TaskFixtureChat? = nil) throws {
        descriptor = AgentDescriptor(
            id: configuration.agentID, name: configuration.agentID.rawValue,
            inputs: Set(configuration.communication.inputs.map(\.kind)),
            outputs: [.communication, .actionCall, .control],
            capabilities: configuration.capabilities)
        context = try AgentContextRepository(
            agent: configuration.agentID, scope: UUID().uuidString, state: TaskFixtureState()
        )
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
    func emit(_ action: AgentOutput, input: AgentInput, roundID: String? = nil, callID: String? = nil) throws {
        sequence += 1
        guard
            case .enqueued = output.yield(
                OutputEnvelope(
                    source: descriptor.id, context: input.context, output: action,
                    sequence: sequence, roundID: roundID, callID: callID, taskScope: input.taskScope))
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
            let value: String
            if case .value(let text) = result.completion { value = text } else { value = result.status.rawValue }
            try round?.accept(
                ToolResult(
                    callID: callID, value: value, isError: result.status != .succeeded,
                    completion: result.completion, roundID: roundID), roundID: roundID)
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
            let decision = UUID().uuidString
            let text = try await AgentChatDriver.collect(
                ChatRequest(
                    messages: messages,
                    context: InferenceContext(requestID: decision, scopeID: scope.id)), using: model,
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
                let id = UUID().uuidString
                round = AgentRoundCoordinator(id: decision, taskID: scope.id)
                try round?.register(id: id)
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

extension LiveRuntimeTests {
    @Test(.actionCatalog, .timeLimit(.minutes(1))) func taskChildOwnsActionResultsChatHistoryAndExplicitParentReports()
        async throws
    {
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
        let input = InputGateway(manager: manager, policy: policy)
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
            manager: manager, requests: input, tools: ToolRegistry(), actions: scheduler, policy: policy, sink: { _ in }
        )
        let parentPump = Task {
            try await IndependentOutputWorkflow.consumeSignals(parent.outputs) { _ = try await gateway.execute($0) }
        }
        let childPump = Task {
            try await IndependentOutputWorkflow.consumeGeneration(child.outputs) { _ = try await gateway.execute($0) }
        }
        let root = AgentInput(
            id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("parent user input"))
        let scope = AgentTaskScope(
            id: UUID().uuidString,
            parentID: root.id, requester: parent.descriptor.id, executor: child.descriptor.id, sessionID: root.sessionID
        )
        try await parent.send(
            AgentTaskSignal(
                kind: .request, scope: scope, businessContract: "fixture.photo", data: Data("take one photo".utf8)),
            parent: root)
        do {
            try await waitForArchitecture {
                try await parent.context.snapshot().tasks.task(scope.id)?.state == .succeeded
            }
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
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func runtimeContextDiscardsPartialStateOnRestartWithoutReplaying() async throws {
        let scope = UUID().uuidString
        let repository = try AgentContextRepository(
            agent: .assistant, scope: scope, state: AssistantContextState()
        )
        let projected = AssistantHistoryContext.store(repository: repository)
        let read = try await projected.readCurrent()
        let id = UUID().uuidString
        _ = try await projected.begin(
            id: id, user: "live input", request: [.init(role: .user, content: "live input")],
            expecting: read.token, model: "fixture")
        try await projected.beginModelRequest(
            .init(id: UUID().uuidString, input: "live input", requestJSON: "[]"), for: id)
        try await projected.append("partial", to: id)
        #expect(try await repository.snapshot().state.history.current.turns.first?.raw == "partial")
        let restarted = try AgentContextRepository(
            agent: .assistant, scope: scope, state: AssistantContextState()
        )
        let recovered = try await restarted.snapshot()
        #expect(recovered.state.history.current.turns.isEmpty)
        #expect(recovered.work.isEmpty && recovered.records.isEmpty)
    }
}

@Test(.actionCatalog) func signalInboxFusionOwnershipExpiryAndRoundBudgetAreBounded() throws {
    let session = UUID().uuidString
    let root = UUID().uuidString
    func input(_ text: String, rootID: String = UUID().uuidString) -> AgentInput {
        let payload = InputPayload.text(text)
        return AgentInput(
            id: UUID().uuidString,
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
    for _ in 0..<256 { try budget.reserveRequest() }
    for _ in 0..<2048 { try budget.reserveNativeCall() }
    #expect(budget.requests == 256 && budget.nativeCalls == 2048)
    try budget.validate()
    var explicit = try AgentTaskBudget(maximumRequests: 1, maximumNativeCalls: 2)
    try explicit.reserveRequest()
    #expect(throws: CommunicationError.capacityExceeded) { try explicit.reserveRequest() }
    try explicit.reserveNativeCall()
    try explicit.reserveNativeCall()
    #expect(throws: CommunicationError.capacityExceeded) { try explicit.reserveNativeCall() }
    var round = AgentRoundCoordinator(taskID: root)
    let call = UUID().uuidString
    try round.register(id: call)
    try round.seal()
    #expect(!round.complete)
    try round.accept(.init(callID: call, value: "actual", completion: .value("actual")), roundID: round.id)
    #expect(round.needsReasoning)
    #expect(throws: CommunicationError.unauthorized) {
        try round.accept(.init(callID: call, value: "actual", completion: .value("actual")), roundID: round.id)
    }
    round.cancel()
    #expect(!round.needsReasoning)
}

@Test(.actionCatalog) func rollingContextEvidenceRejectsDuplicatesBeforeEviction() throws {
    var context = AgentContext(agentID: .assistant, scopeID: UUID().uuidString, state: TaskFixtureState())
    let first = try AgentContext<TaskFixtureState>.Record(kind: "first")
    let second = try AgentContext<TaskFixtureState>.Record(kind: "second")
    try context.append(first, retainingLast: 2)
    try context.append(second, retainingLast: 2)
    #expect(throws: CommunicationError.outOfOrder) { try context.append(first, retainingLast: 2) }
    #expect(context.records == [first, second] && context.evictedRecordCount == nil)
    let third = try AgentContext<TaskFixtureState>.Record(kind: "third")
    try context.append(third, retainingLast: 2)
    #expect(context.records == [second, third] && context.evictedRecordCount == 1)
    let batch = try SignalBatch(
        taskID: UUID().uuidString, signalIDs: [UUID().uuidString], admissionSequence: 1)
    try context.consume(batch, retainingLast: 1)
    #expect(throws: CommunicationError.capacityExceeded) { try context.consume(batch, retainingLast: 1) }
    #expect(context.consumedBatches == [batch] && context.evictedBatchCount == nil)
    let next = try SignalBatch(
        taskID: UUID().uuidString, signalIDs: [UUID().uuidString], admissionSequence: 2)
    try context.consume(next, retainingLast: 1)
    #expect(context.consumedBatches == [next] && context.evictedBatchCount == 1)
}

@Test(.actionCatalog) func replyIdentitySurvivesNewRecognitionAndRequiresChildGrant() {
    let session = UUID().uuidString
    let old = AgentTurn(id: UUID().uuidString, ordinal: 1)
    let new = AgentTurn(id: UUID().uuidString, ordinal: 2)
    let round = UUID().uuidString
    let childTask = UUID().uuidString
    var presentation = ConversationPresentation()
    func context(_ source: String, _ turn: AgentTurn, _ seq: UInt64, task: Bool = false) -> ActionExecutionContext {
        ActionExecutionContext(
            source: source, sessionID: session, inputID: UUID().uuidString, sequence: seq,
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

extension LiveRuntimeTests {
    @Test(.actionCatalog) func boundOutputRejectsStoppedProducerAndTaskCancellationRejectsNewEffects() async throws {
        let configuration = try taskFixtureConfiguration(parent: true)
        let childConfiguration = try taskFixtureConfiguration(parent: false)
        let parent = try TaskFixtureAgent(configuration: configuration)
        let child = try TaskFixtureAgent(configuration: childConfiguration)
        let manager = AgentManager()
        try await manager.register(parent)
        try await manager.register(child)
        let session = UUID().uuidString
        let scope = AgentTaskScope(
            id: UUID().uuidString, requester: parent.descriptor.id, executor: child.descriptor.id,
            sessionID: session)
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
            try await manager.registerExecution(UUID().uuidString, scope: scope, agent: child.descriptor.id)
        }
        let gateway = OutputGateway(
            manager: manager, requests: InputGateway(manager: manager), tools: ToolRegistry(),
            sink: { _ in })
        let consumer = try await gateway.consumer(for: parent)
        let late = OutputEnvelope(
            source: parent.descriptor.id,
            context: AgentInput(id: UUID().uuidString, sessionID: session, payload: .text("late")).context,
            output: .control("agent.finished"), sequence: 1)
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
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func failedCommunicationReceiptDoesNotCompleteRemoteTask() async throws {
        let parentConfiguration = try taskFixtureConfiguration(parent: true)
        let childConfiguration = try taskFixtureConfiguration(parent: false)
        let parent = try TaskFixtureAgent(configuration: parentConfiguration)
        let manager = AgentManager()
        try await manager.register(parent)
        await parent.start()
        let policy = try CommunicationPolicy(
            contracts: AgentContracts.communication, configurations: [parentConfiguration, childConfiguration])
        let input = InputGateway(manager: manager, policy: policy)
        let gateway = OutputGateway(
            manager: manager, requests: input, tools: ToolRegistry(), policy: policy, sink: { _ in })
        let root = AgentInput(
            id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("delegation"))
        let scope = AgentTaskScope(
            id: UUID().uuidString,
            requester: parent.descriptor.id, executor: childConfiguration.agentID, sessionID: root.sessionID)
        try await parent.send(
            AgentTaskSignal(kind: .request, scope: scope, businessContract: "fixture.photo", data: Data()), parent: root
        )
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
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func communicationReceiptsAreBoundedDeduplicatedAndFailedWritesDoNotAcknowledge() async throws
    {
        let receipts = CommunicationReceipts()
        let ids = (0..<16).map { _ in UUID().uuidString }
        for id in ids { try await receipts.register(id) }
        await #expect(throws: CommunicationError.capacityExceeded) {
            try await receipts.register(UUID().uuidString)
        }
        let result = CommunicationReceipt(
            callID: ids[0], report: .init(delivered: [.assistant]),
            owner: ExecutionOwner(
                agent: .assistant, incarnation: UUID().uuidString, sessionID: UUID().uuidString),
            causality: .root())
        await #expect(throws: CommunicationError.invalidPayload) {
            try await receipts.accept(result) { throw CommunicationError.invalidPayload }
        }
        await #expect(throws: CommunicationError.unauthorized) { try await receipts.accept(result) }
        await #expect(throws: CommunicationError.invalidPayload) { _ = try await receipts.wait(ids[0]) }
        let next = UUID().uuidString
        try await receipts.register(next)
        let accepted = CommunicationReceipt(
            callID: next, report: .init(delivered: [.assistant]), owner: result.owner, causality: result.causality)
        try await receipts.accept(accepted)
        #expect(try await receipts.wait(next).delivered == [.assistant])
        await receipts.close()
        await #expect(throws: CommunicationError.scopeClosed) { _ = try await receipts.wait(ids[1]) }
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func contextRejectedCommitAndCorruptStateLeaveNoWritableFallback() async throws {
        let repository = try AgentContextRepository(
            agent: .assistant, scope: UUID().uuidString, state: AssistantContextState(),
            persistence: .init(load: { nil }, commit: { _, _ in throw CommunicationError.invalidPayload })
        )
        let input = AgentInput(
            id: UUID().uuidString, sessionID: UUID().uuidString,
            payload: .text("Persist before processing"))
        await #expect(throws: CommunicationError.invalidPayload) {
            try await repository.recordSignal(
                input, disposition: .enqueue(priority: 0), admissionSequence: 1, consumed: true
            ) { try $0.beginWork(input.id, sessionID: input.sessionID) }
        }
        let uncommitted = try await repository.snapshot()
        #expect(uncommitted.work.isEmpty && uncommitted.records.isEmpty && uncommitted.consumedBatches.isEmpty)
        #expect(uncommitted.revision == 0)
        let agent = AgentID.assistant
        let scope = UUID().uuidString
        let invalid = AgentContext(agentID: agent, scopeID: scope, state: AssistantContextState())
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(invalid)) as? [String: Any])
        object["version"] = 99
        let saved = try JSONDecoder().decode(
            AgentContext<AssistantContextState>.self, from: JSONSerialization.data(withJSONObject: object))
        let corrupt = try AgentContextRepository(
            agent: agent, scope: scope, state: AssistantContextState(),
            persistence: .init(load: { saved }, commit: { _, _ in Issue.record("Corrupt state must never commit") })
        )
        await #expect(throws: CommunicationError.invalidPayload) { _ = try await corrupt.snapshot() }
        await #expect(throws: CommunicationError.invalidPayload) { try await corrupt.update { _ in } }
    }
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
extension LiveRuntimeTests {
    @Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: [false, true])
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
        let input = InputGateway(manager: manager, policy: policy)
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
            manager: manager, requests: input, tools: ToolRegistry(), actions: scheduler, policy: policy, sink: { _ in }
        )
        let parentConsumer = try await gateway.consumer(for: parent)
        let childConsumer = try await gateway.consumer(for: child)
        let parentPump = Task {
            try await IndependentOutputWorkflow.consumeSignals(parent.outputs) {
                _ = try await parentConsumer.execute($0)
            }
        }
        let childPump = Task {
            try await IndependentOutputWorkflow.consumeGeneration(child.outputs) {
                _ = try await childConsumer.execute($0)
            }
        }
        let root = AgentInput(
            id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("stop child task"))
        let scope = AgentTaskScope(
            id: UUID().uuidString,
            parentID: root.id, requester: parent.descriptor.id, executor: child.descriptor.id, sessionID: root.sessionID
        )
        try await parent.send(
            AgentTaskSignal(kind: .request, scope: scope, businessContract: "fixture.photo", data: Data()), parent: root
        )
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
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func deletedHistoryErasesItsOwnedSignalEvidenceAndProtectsActiveWork() async throws {
        let store = ConversationHistoryStore()
        let repository = try AgentContextRepository(
            agent: .assistant, scope: UUID().uuidString, state: AssistantContextState()
        )
        try await AssistantHistoryContext.attach(repository: repository, store: store)
        let id = UUID().uuidString
        let token = try await store.readCurrent().token
        _ = try await store.begin(
            id: id, user: "private archived text", request: [.init(role: .user, content: "private archived text")],
            expecting: token, model: "fixture")
        try await repository.update {
            try $0.beginWork(id, sessionID: UUID().uuidString)
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
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func duplicateTaskRequestCannotRevokeThePreviouslyAcceptedGrant() async throws {
        let parentConfiguration = try taskFixtureConfiguration(parent: true)
        let childConfiguration = try taskFixtureConfiguration(parent: false)
        let parent = try TaskFixtureAgent(configuration: parentConfiguration)
        let child = try TaskFixtureAgent(configuration: childConfiguration)
        let manager = AgentManager()
        try await manager.register(parent)
        try await manager.register(child)
        await parent.start()
        await child.start()
        let root = AgentInput(
            id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("duplicate admission")
        )
        let scope = AgentTaskScope(
            id: UUID().uuidString,
            requester: parent.descriptor.id, executor: child.descriptor.id, sessionID: root.sessionID)
        try await manager.grantTask(scope, sender: parent.descriptor.id)
        try await parent.context.update { try $0.tasks.register(scope) }
        let policy = try CommunicationPolicy(
            contracts: AgentContracts.communication, configurations: [parentConfiguration, childConfiguration])
        let gateway = OutputGateway(
            manager: manager, requests: InputGateway(manager: manager, policy: policy),
            tools: ToolRegistry(),
            policy: policy, sink: { _ in })
        let duplicate = try AgentTaskSignal(
            kind: .request, scope: scope, businessContract: "fixture.photo", data: Data())
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

extension LiveRuntimeTests {
    @Test(.actionCatalog, .timeLimit(.minutes(1)))
    func concurrentEnvironmentFactsWaitForStateCommitInsteadOfRejectingAsCapacity() async throws {
        let session = UUID().uuidString
        let held = HeldAdmissionCommit()
        let context = try AgentContextRepository(
            agent: .applicationControl, scope: UUID().uuidString, state: ApplicationControlContextState(),
            persistence: .init(
                load: { nil },
                commit: { value, _ in
                    if value.records.contains(where: { $0.kind == AppEnvironmentFact.contract }) { await held.hold() }
                })
        )
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
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func admissionGateCancelsAndClosesWaitingInputsWithoutLeakingPermit() async throws {
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
}

@Test(.actionCatalog) func communicationCatalogDefinesRequestKindsAndExcludesTelemetryPublish() throws {
    let configuration = try AgentConfigurations.load(named: "Assistant")
    for role in try AgentConfigurations.all() {
        let catalog = try AgentCommunicationAdapter.catalog(role.capabilities, policy: role.communication)
        #expect(catalog.tools.map(\.path) == role.capabilities.tools.map(\.path))
        #expect(!catalog.tools.contains { $0.alias == "Agent.send" || $0.path.hasPrefix("Agent.Communication.") })
        #expect(
            catalog.actions.contains { $0.alias == "send" }
                == (role.capabilities.actions.contains { $0.path.description == "Agent.Communication.send" }
                    && role.communication.sends.contains { $0.contract.hasPrefix("task.") }))
    }
    let catalog = try AgentCommunicationAdapter.catalog(
        fixtureCatalogWithCommunication(configuration.capabilities), policy: configuration.communication)
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
            input: .init(
                id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("close")),
            policy: configuration.communication)
    }
}

@Test(.actionCatalog) func userSignalsHaveNoImplicitDeadline() throws {
    let text = InputMetadata(payload: .text("hello"), rootID: UUID().uuidString)
    #expect(text.deadline == nil && !text.expired)
    let audio = InputMetadata(payload: .event("voice-turn"), rootID: UUID().uuidString)
    #expect(audio.deadline == nil && !audio.expired)
    let explicit = InputMetadata(
        payload: .event("perception"), rootID: UUID().uuidString, deadline: .now.advanced(by: .seconds(-1)))
    #expect(explicit.expired)
}

@Test(.actionCatalog) func fixedTaskPayloadDecodingRequiresTrustedIdentityAndPreservesCausalMetadata() throws {
    let scope = AgentTaskScope(
        id: "task", requester: .assistant, executor: .memory, sessionID: "session")
    let signal = try AgentTaskSignal(
        kind: .request, scope: scope, businessContract: "fixture.work", data: Data("payload".utf8))
    let payload = InputPayload.observation(try signal.message())
    let deadline = ContinuousClock.now + .seconds(30)
    func input(origin: SignalOrigin, incarnation: String?) -> AgentInput {
        AgentInput(
            id: "delivery", sessionID: "session", payload: payload,
            metadata: InputMetadata(
                payload: payload, source: "assistant", incarnation: incarnation, origin: origin,
                capturedAt: 42, sequence: 7, rootID: "request", parentID: "parent", hops: 2, deadline: deadline),
            taskScope: scope)
    }
    var decoded = 0
    func decode(_ signal: AgentTaskSignal) throws -> AgentMessage {
        decoded += 1
        return AgentMessage(contract: signal.businessContract, content: "payload", maximumBytes: 64, validate: { _ in })
    }
    for untrusted in [
        input(origin: .local, incarnation: nil), input(origin: .runtime, incarnation: "runtime"),
        input(origin: .agent, incarnation: nil),
    ] {
        #expect(throws: CommunicationError.unauthorized) {
            try AgentFixedTaskInput.unwrap(signal, input: untrusted, executor: .memory, decode: decode)
        }
    }
    let trusted = input(origin: .agent, incarnation: "registered-assistant")
    #expect(throws: CommunicationError.unauthorized) {
        try AgentFixedTaskInput.unwrap(signal, input: trusted, executor: .photographer, decode: decode)
    }
    #expect(decoded == 0)
    let forwarded = try AgentFixedTaskInput.unwrap(signal, input: trusted, executor: .memory, decode: decode)
    #expect(decoded == 1 && forwarded.id == "request" && forwarded.taskScope == scope)
    #expect(forwarded.metadata.origin == .agent && forwarded.metadata.incarnation == "registered-assistant")
    #expect(forwarded.metadata.rootID == "request" && forwarded.metadata.parentID == "parent")
    #expect(forwarded.metadata.sequence == 7 && forwarded.metadata.hops == 2)
    #expect(forwarded.metadata.capturedAt == 42 && forwarded.metadata.deadline == deadline)
    #expect(throws: CommunicationError.unsupportedContract) {
        try AgentFixedTaskInput.unwrap(signal, input: trusted, executor: .memory) { _ in
            throw CommunicationError.unsupportedContract
        }
    }
}

@Test(.actionCatalog) func assistantOwnsItsControlSchemaWhileGenericChatStateDoesNotInterpretIt() throws {
    let message = AgentMessage(
        contract: AssistantSessionControl.contract, content: AssistantSessionControl.cancelSession,
        maximumBytes: 512, validate: { _ in })
    #expect(try AssistantContextState.sessionControl(message) == .close)
    #expect(try ControlAgnosticChatState.sessionControl(message) == nil)
    let forged = AgentMessage(
        contract: AssistantSessionControl.contract, content: "cancelSession", maximumBytes: 512, validate: { _ in })
    #expect(throws: CommunicationError.invalidPayload) { try AssistantContextState.sessionControl(forged) }
    #expect(try ControlAgnosticChatState.sessionControl(forged) == nil)
}

/// A separate role deliberately uses the shared default and declares no host-control schema.
private struct ControlAgnosticChatState: AgentChatContextState {
    static let agentID = AgentID(rawValue: "controlAgnostic")
    static let configurationName = "ControlAgnostic"
    static func preprocess(_ input: AgentInput, state: Self) throws -> SignalDisposition { .enqueue(priority: 0) }
    static func systemPrompt(_ capabilities: CapabilityRegistry) throws -> String { "fixture" }
    var history = ConversationArchive()
    var admissionSequence: UInt64 = 0
    var taskViews: [String: AgentTaskView]?
    init() {}
    func validateContextState() throws { try validateChatState() }
    mutating func recoverInterruptedWork() { recoverChatState() }
}

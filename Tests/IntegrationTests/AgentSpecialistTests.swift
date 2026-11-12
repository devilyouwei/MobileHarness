import Actions
import AgentCore
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
import UI

@testable import Agents

private actor SpecialistEffects {
    private(set) var owners: [String] = []
    private(set) var finished: Set<AgentID> = []
    func finish(_ agent: AgentID) { finished.insert(agent) }
    private(set) var failures: [String] = []
    func capture(_ owner: String) { owners.append(owner) }
    func fail(_ message: String) {
        failures.append(message)
        Issue.record("Output failed: \(message)")
    }
}
private func specialistEventually(_ predicate: @Sendable () async throws -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(8))
    while !(try await predicate()) {
        guard ContinuousClock.now < end else { throw CommunicationError.expired }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.actionCatalog) func specialistContextsPersistTaskStateWithoutChatSchema() throws {
    func verify<State: AgentTaskContextState>(_ state: State) throws {
        let data = try JSONEncoder().encode(state)
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fields["history"] == nil && fields["historyImported"] == nil && fields["chatSchemaVersion"] == nil)
        let restored = try JSONDecoder().decode(State.self, from: data)
        try restored.validateContextState()
    }
    try verify(MemoryContextState())
    try verify(PhotographerContextState())
    try verify(ApplicationControlContextState())
}

private struct SpecialistTools: ToolModule { let definitions: [ActionBinding] }
@Test(.actionCatalog, .timeLimit(.minutes(1)))
@MainActor func specialistTypedUIBypassesAssistantAndCompletesWithoutModels() async throws {
    let ui = UIContainer()
    try ui.start()
    let session = UUID().uuidString
    let manager = AgentManager()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication,
        configurations: AgentConfigurations.all())
    let input = InputGateway(manager: manager, policy: policy)
    let effects = SpecialistEffects()
    let definition = ActionBinding(
        path: .init(domain: "Camera", module: "Capture", function: "open"),
        displayName: "Synthetic open", kind: .finite, completion: "Synthetic camera.", protocols: [.tool],
        executionPolicy: .direct, directResultPolicy: .returning,
        completing: { invocation in
            await effects.capture(invocation.context.source)
            return .completed
        })
    let gateway = await OutputGateway(
        manager: manager, requests: input,
        tools: try ToolRegistry(modules: [SpecialistTools(definitions: [definition])]),
        actions: ChannelScheduler(registry: ActionRegistry()), policy: policy, sink: { _ in })
    let repository = try AgentContextRepository(
        agent: AgentID.assistant, scope: UUID().uuidString, state: AssistantContextState()
    )
    let parent = try AssistantAgent(stateContext: try publicStateFixture(), context: repository)
    let camera = PhotographerExecutionSession(
        manager: manager, output: gateway,
        agent: try PhotographerAgent(
            sessionID: session, uiCamera: ui.camera,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "photographer"), scope: UUID().uuidString, state: PhotographerContextState())
        ), report: { await effects.fail($0) })
    try await camera.prepareForInteraction()
    let root = AssistantExecutionSession(
        agent: parent, manager: manager, output: gateway,
        report: { await effects.fail($0) })
    try await root.start()
    let operation = Task { try await ui.camera.requests.submit(.init(.open)) }
    do {
        try await operation.value
        #expect(await effects.owners == ["photographer"])
        let state = try await repository.snapshot().state
        #expect(state.history.current.turns.isEmpty)
        #expect(state.taskViews?.isEmpty != false)
        var observation = try await input.observeSignals().makeAsyncIterator()
        let signals = try #require(await observation.next()).records
        #expect(
            !signals.contains { $0.contract == "photography.camera" })
        #expect(!signals.contains { $0.task?.kind == .request })
        #expect(await effects.failures == [])
    } catch {
        Issue.record(
            "UI routing: \(try await repository.snapshot().state.taskViews ?? [:]); effects: \(await effects.owners); executions: \(await gateway.executionResults())"
        )
        operation.cancel()
        await root.shutdown()
        await camera.shutdown()
        await gateway.shutdown()
        throw error
    }
    await root.shutdown()
    await camera.shutdown()
    await gateway.shutdown()
}

private actor SpecialistPendingModel: ChatCapability {
    nonisolated let availability: CapabilityAvailability = .available
    private(set) var requests = 0
    private var emitter: InferenceEmitter<ChatEvent>?
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        requests += 1
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        emitter = pair.emitter
        return pair.session
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) func specialistPauseJoinsInferenceWhenChildCancellationDeliveryFails()
    async throws
{
    let context = try AgentContextRepository(
        agent: .assistant, scope: UUID().uuidString, state: AssistantContextState()
    )
    let model = SpecialistPendingModel()
    let failing = try AssistantAgent(stateContext: try publicStateFixture(), chat: model, context: context)
    try await failing.bind(
        AgentMessaging { _, _, target in
            DeliveryReport(rejected: target.map { [$0: "Target unavailable"] } ?? [:])
        })
    try await failing.start()
    let session = UUID().uuidString
    let scope = AgentTaskScope(
        id: UUID().uuidString, requester: .assistant, executor: .photographer, sessionID: session)
    try await context.update {
        try $0.tasks.register(scope)
        $0.state.taskViews = [scope.id: AgentTaskView(scope: scope, content: try AgentTaskContent(text: "In progress"))]
    }
    let input = AgentInput(id: UUID().uuidString, sessionID: session, payload: .text("pending inference"))
    try await failing.receive(input)
    try await specialistEventually { await model.requests == 1 }
    await #expect(throws: CommunicationError.unavailableTarget) { try await failing.pause() }
    #expect(await failing.status().lifecycle == .paused)
    #expect(await failing.status().queuedInputs == 0)
    #expect(try await context.snapshot().state.history.current.turns.first?.state == .cancelled)
    await failing.stop()
}

private actor SpecialistRobotModel: ChatCapability {
    nonisolated let availability: CapabilityAvailability = .available
    var requests: [ChatRequest] = []
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        requests.append(request)
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        let text =
            requests.count == 1
            ? "<loadSkills skills='[\"robot-interaction\"]'/>" : "<dance cycles=\"1\"/>"
        try pair.emitter.yield(.text(text))
        try pair.emitter.yield(.finished(.stop))
        pair.emitter.finish()
        return pair.session
    }
}
private struct SpecialistTaskControls: TaskControlCapability {
    let agent: AssistantAgent
    func controlTask(_ operation: String, arguments: [String: String], invocation: any FunctionInput) async throws
        -> ActionCompletion
    {
        try await agent.controlTask(
            operation, arguments: arguments, source: invocation.context.source,
            sessionID: invocation.context.sessionID, inputID: invocation.context.inputID,
            decisionID: invocation.context.decisionID)
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) func assistantExecutesRobotActionWithoutDelegation() async throws {
    let context = try AgentContextRepository(
        agent: AgentID.assistant, scope: UUID().uuidString, state: AssistantContextState()
    )
    let model = SpecialistRobotModel()
    let assistant = try AssistantAgent(
        stateContext: try publicStateFixture(), chat: model, context: context)
    let manager = AgentManager()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication,
        configurations: AgentConfigurations.all())
    let input = InputGateway(manager: manager, policy: policy)
    let resource = ResourceID(rawValue: "nexarm.motor.1")
    let resources = try ResourceCoordinator(definitions: [
        ResourceDefinition(
            id: resource, allowedOwners: [.assistant, .applicationControl, .photographer],
            executionGroup: ResourceID(rawValue: "nexarm.writer"),
            preempts: [.assistant: [.photographer], .applicationControl: [.photographer]]
        ) {}
    ])
    let effects = SpecialistEffects()
    let binding = ActionBinding(
        path: .init(domain: "NexArm", module: "Gesture", function: "dance"),
        displayName: "Synthetic dance", kind: .finite, completion: "Synthetic effect.", resources: [resource],
        completing: { invocation in
            #expect(ResourceExecutionContext.owner?.agent == .assistant)
            await effects.capture(invocation.context.source)
            return .completed
        })
    let controls = TaskControlModule(capability: SpecialistTaskControls(agent: assistant))
    let assembly = try BehaviorAssembly(capabilityModules: [controls])
    let taskBindings = try controls.definitions.map { try assembly.actions.definition(for: $0.path) }
    let scheduler = ChannelScheduler(
        registry: try ActionRegistry(definitions: [binding] + taskBindings), resources: resources
    ) {
        await input.deliverActionResult($0)
    }
    let gateway = await OutputGateway(
        manager: manager, requests: input, tools: ToolRegistry(), actions: scheduler, policy: policy, sink: { _ in })
    try await manager.register(assistant)
    try await assistant.start()
    let consumer = try await gateway.consumer(for: assistant)
    let pump = Task {
        do {
            try await IndependentOutputWorkflow.consumeGeneration(assistant.outputs) { envelope in
                let result = try await consumer.execute(envelope)
                if case .control("agent.finished") = envelope.output { await effects.finish(envelope.source) }
                if let failure = result.failure { await effects.fail(failure) }
            }
        } catch is CancellationError {} catch { await effects.fail(String(describing: error)) }
    }
    do {
        try await manager.publishLocally(
            .init(id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("跳舞")), to: .assistant)
        try await specialistEventually { await effects.finished.contains(.assistant) }
        #expect(await effects.owners == ["assistant"])
        let requests = await model.requests
        #expect(requests.count == 2)
        #expect(requests.first?.messages.first?.content.contains("Action dance:") == false)
        #expect(requests.last?.messages.first?.content.contains("Action dance:") == true)
        #expect(await effects.failures.isEmpty)
        let snapshot = try await context.snapshot()
        #expect(snapshot.state.taskViews?.isEmpty != false)
        #expect(snapshot.records.contains { $0.kind == "action.result" })
        var observations = try await input.observeSignals().makeAsyncIterator()
        let signals = try #require(await observations.next()).records
        #expect(!signals.contains { $0.task?.kind == .request })
        #expect(signals.contains { $0.contract == "action.result" && $0.branches.first?.target == .assistant })
    } catch {
        await manager.stopAll()
        await gateway.shutdown()
        pump.cancel()
        await pump.value
        throw error
    }
    await manager.stopAll()
    await gateway.shutdown()
    await pump.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) func interactionSceneChangeOnlyControlsItsOwnRole() async throws {
    let manager = AgentManager()
    let input = InputGateway(manager: manager)
    let gateway = await OutputGateway(
        manager: manager, requests: input, tools: ToolRegistry(), actions: ChannelScheduler(registry: ActionRegistry()),
        sink: { _ in })
    let parent = try AssistantAgent(
        stateContext: try publicStateFixture(),
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "assistant"), scope: UUID().uuidString, state: AssistantContextState())
    )
    let child = try PhotographerAgent(
        sessionID: UUID().uuidString,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "photographer"), scope: UUID().uuidString, state: PhotographerContextState())
    )
    try await manager.register(child)
    try await child.start()
    let runtime = AssistantExecutionSession(agent: parent, manager: manager, output: gateway)
    try await runtime.setForeground(false)
    #expect(await parent.status().lifecycle == .paused)
    #expect(await child.status().lifecycle == .running)
    try await runtime.setForeground(true)
    #expect(await parent.status().lifecycle == .running)
    #expect(await child.status().lifecycle == .running)
    await runtime.shutdown()
    await manager.stopAll()
    await gateway.shutdown()
}

@Test(.actionCatalog) func photographerCameraFactsArePassiveRevisionedAndScoped() async throws {
    let session = UUID().uuidString
    let agent = try PhotographerAgent(
        sessionID: session,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "photographer"), scope: UUID().uuidString, state: PhotographerContextState())
    )
    try await agent.start()
    let first = CameraStateObservation(
        sequence: 1, enabled: true, visible: true, busy: false,
        needsSettings: false, facing: .front)
    try await agent.receive(first.input(sessionID: session))
    #expect(try await agent.contextSnapshot().state.cameraState == first)
    try await agent.pause()
    let second = CameraStateObservation(
        sequence: 3, enabled: false, visible: false, busy: false,
        needsSettings: true, facing: .back, failure: "permission denied")
    try await agent.receive(second.input(sessionID: session))
    await #expect(throws: CommunicationError.outOfOrder) { try await agent.receive(first.input(sessionID: session)) }
    await #expect(throws: CommunicationError.unauthorized) {
        try await agent.receive(second.input(sessionID: UUID().uuidString))
    }
    let payload = InputPayload.observation(second.message)
    let forged = AgentInput(
        id: UUID().uuidString,
        sessionID: session, payload: payload,
        metadata: InputMetadata(payload: payload, source: "user", sequence: 3, rootID: UUID().uuidString))
    await #expect(throws: CommunicationError.unauthorized) { try await agent.receive(forged) }
    let mismatched = AgentInput(
        id: UUID().uuidString,
        sessionID: session, payload: payload,
        metadata: InputMetadata(
            payload: payload, source: CameraStateObservation.source, sequence: 4, rootID: UUID().uuidString))
    await #expect(throws: CommunicationError.invalidPayload) { try await agent.receive(mismatched) }
    let expired = AgentInput(
        id: UUID().uuidString,
        sessionID: session, payload: payload,
        metadata: InputMetadata(
            payload: payload, source: CameraStateObservation.source, sequence: 3, rootID: UUID().uuidString,
            deadline: .now.advanced(by: .seconds(-1))))
    await #expect(throws: CommunicationError.expired) { try await agent.receive(expired) }
    let snapshot = try await agent.contextSnapshot()
    #expect(snapshot.state.cameraState == second)
    #expect(snapshot.work.isEmpty && snapshot.records.isEmpty)
    #expect(await agent.status().processedInputs == 2)
    var recovered = try JSONDecoder().decode(PhotographerContextState.self, from: JSONEncoder().encode(snapshot.state))
    recovered.recoverInterruptedWork()
    #expect(recovered.cameraState == nil)
    #expect(throws: CommunicationError.invalidPayload) {
        try CameraStateObservation(
            sequence: 0, enabled: true, visible: true, busy: false,
            needsSettings: false, facing: .front
        ).message.validatedSize()
    }
    #expect(throws: CommunicationError.invalidPayload) {
        try CameraStateObservation(
            sequence: 1, enabled: true, visible: true, busy: false,
            needsSettings: false, facing: .front, failure: String(repeating: "x", count: 513)
        ).message.validatedSize()
    }
    await agent.stop()
}

@Test(.actionCatalog) func photographerPhaseProjectsExistingTaskAndArtifactState() throws {
    let task = AgentTaskScope(
        id: UUID().uuidString, requester: .assistant, executor: .photographer,
        sessionID: UUID().uuidString)
    let input = AgentInput(
        id: UUID().uuidString, sessionID: task.sessionID, payload: .text("photo"), taskScope: task)
    var context = AgentContext(
        agentID: .photographer, scopeID: UUID().uuidString, state: PhotographerContextState())
    try context.tasks.register(task)
    try context.beginWork(input.id, sessionID: input.sessionID)
    #expect(PhotographerContextState.phase(context, input: input) == .preparing)
    try context.transitionWork(input.id, to: .running)
    try context.transitionWork(input.id, to: .awaitingFeedback)
    #expect(PhotographerContextState.phase(context, input: input) == .awaitingFeedback)
    try context.transitionWork(input.id, to: .continuation)
    let photo = UUID().uuidString
    try context.append(.init(taskID: task.id, kind: "user.text", data: JSONEncoder().encode(SignalEvidence(input))))
    context.state.photoOwners = [photo: input.id]
    #expect(PhotographerContextState.phase(context, input: input) == .reviewingPhoto)
    context.state.taskViews = [
        task.id: AgentTaskView(
            scope: task,
            content: try AgentTaskContent(
                text: "Save?", stage: .waitingUser, interactionID: UUID().uuidString, artifactID: photo))
    ]
    #expect(PhotographerContextState.phase(context, input: input) == .waitingUser)
    let failed = try AgentTaskContent(text: "failure").signal(.result, scope: task, status: .failed)
    try context.tasks.report(failed, agent: .photographer)
    #expect(PhotographerContextState.phase(context, input: input) == .failed)
    #expect(context.state.cameraState == nil)
    #expect(context.state.taskViews?[task.id]?.scope.id == task.id)
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func memoryOwnsItsInjectedHistoryContainerWithoutAnInputHost() async throws {
    let ui = UIContainer()
    try ui.start()
    let store = AssistantHistoryStore()
    let runtime = try await intentRuntime(
        sessionID: "history-ui",
        presentation: HistoryPresentationAdapter(state: ui.history.presentation, store: store, sessionID: "history-ui"),
        reads: HistoryReadFixture { _ in .archives([]) }, uiHistory: ui.history)
    try await runtime.prepareForInteraction()
    guard case .archives(let values) = try await ui.history.requests.submit(.archives(0)) else {
        Issue.record("Memory must return the protected typed read")
        await runtime.shutdown()
        return
    }
    #expect(values.isEmpty)
    #expect(await runtime.agent.status().processedInputs == 1)
    await runtime.shutdown()
    await ui.stop()
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func assistantOwnsHomeRequestsAndPreservesUIRequestGenerationAndTurn() async throws {
    let ui = UIContainer()
    try ui.start()
    let agent = try AssistantAgent(
        stateContext: publicStateFixture(), uiHome: ui.home, uiSessionID: "assistant-ui", chat: FixedTextChat(),
        context: AgentContextRepository(agent: .assistant, scope: UUID().uuidString, state: AssistantContextState()))
    try await agent.start()
    var outputs = agent.outputs.makeAsyncIterator()
    try await ui.home.requests.submit(.text("hello"))
    let first = try #require(await outputs.next())
    #expect(first.sessionID == "assistant-ui")
    #expect(first.inputMetadata.generation == ui.home.requests.generation.uuidString)
    #expect(first.turn?.id == first.inputID && first.turn?.ordinal == 1)
    await agent.stop()
    await #expect(throws: UIRequestError.unavailable) { try await ui.home.requests.submit(.text("late")) }
    await ui.stop()
}

private actor ReplyOccupancyBlockedModel: ChatCapability {
    nonisolated let availability: CapabilityAvailability = .available
    private var emitter: InferenceEmitter<ChatEvent>?
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        let pair = InferenceSession<ChatEvent>.make(limits: try .init(), estimatedBytes: { $0.estimatedBytes })
        emitter = pair.emitter
        return pair.session
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func directIslandResultMustNotBecomeAssistantInputDuringAReply() async throws {
    let session = UUID().uuidString
    let agent = try AssistantAgent(
        stateContext: publicStateFixture(), presentsReply: true, chat: ReplyOccupancyBlockedModel(),
        context: AgentContextRepository(agent: .assistant, scope: UUID().uuidString, state: AssistantContextState()))
    let manager = AgentManager()
    try await manager.register(agent)
    try await manager.start(.assistant)
    let path = ActionIdentifier(domain: "UI", module: "Island", function: "present")
    let binding = ActionBinding(
        path: path, displayName: "Island fixture", kind: .finite, completion: "Presentation acknowledged",
        protocols: [.tool], executionPolicy: .direct, directResultPolicy: .returning,
        completing: { _ in .value("presented") })
    let gateway = await OutputGateway(
        manager: manager, requests: InputGateway(manager: manager),
        tools: try ToolRegistry(modules: [SpecialistTools(definitions: [binding])]),
        actions: ChannelScheduler(registry: ActionRegistry()), sink: { _ in })
    let consumer = try await gateway.consumer(for: agent)
    try await agent.receive(.init(id: UUID().uuidString, sessionID: session, payload: .text("Photo review pending")))
    try await specialistEventually { await agent.status().queuedInputs == 0 }
    let result = try await consumer.executeInternal(
        .init(
            source: .assistant, context: .init(sessionID: "independent-island", source: "assistant"),
            output: .toolCall(
                .init(
                    id: UUID().uuidString, toolPath: path.description,
                    arguments: [
                        "activityID": UUID().uuidString, "revision": "1", "content": "{}",
                    ]))))
    #expect(!result.isError && result.tool?.value == "presented")
    #expect(await agent.status().queuedInputs == 0)
    await agent.stop()
    await gateway.shutdown()
    await manager.stopAll()
}

import Actions
import AgentCore
import AppLifecycle
import AppStorage
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import ModelKit
import PlatformKit
import Storage
import StorageCache
import StorageChat
import StorageCore
import StorageDatabase
import StorageDevices
import StorageFiles
import StorageMedia
import StorageSQLite
import StorageTasks
import Synchronization
import Testing

@testable import Agents
@testable import UI

private struct DiagnosticTools: ToolModule { let definitions: [ActionBinding] }

private enum InjectedContainerFailure: Error, Equatable {
    case operation(Int)
    case startup, cleanup, transport
}

@MainActor private func containerEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while !(try await predicate()) {
        guard ContinuousClock.now < deadline else { throw CommunicationError.expired }
        try await Task.sleep(for: .milliseconds(5))
    }
}
private actor DiagnosticChat: ChatCapability {
    let availability: CapabilityAvailability = .available
    private(set) var calls = 0
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        calls += 1
        throw InjectedContainerFailure.operation(0)
    }
}
private actor DiagnosticPublicationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    func wait() async {
        entered.continuation.yield(())
        guard !opened else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
private actor FailedDiagnosticDatabase: DatabaseStorage {
    nonisolated var chat: any ChatRepository { get throws { throw RecordStorageError.notReady } }
    nonisolated var tasks: any TaskRepository { get throws { throw RecordStorageError.notReady } }
    nonisolated var media: any MediaRepository { get throws { throw RecordStorageError.notReady } }
    nonisolated var devices: any DeviceRepository { get throws { throw RecordStorageError.notReady } }
    func start() throws { throw InjectedContainerFailure.startup }
    func stop() throws { throw InjectedContainerFailure.cleanup }
}

@MainActor struct RuntimeFailurePresentationFixture {
    let ui = UIContainer()
    let manager: AgentManager
    let input: InputGateway
    let output: OutputGateway
    let runtime: ApplicationControlExecutionSession
    let context: AgentContextRepository<ApplicationControlContextState>
    let sessionID: String
    init(activity: ActionActivityWorkflow, rejectPresentation: Bool = false) async throws {
        sessionID = UUID().uuidString
        manager = AgentManager()
        let configurations = try [
            "Assistant", "SpeechPerception", "SpeechSynthesis", "VisionPerception", "Photographer", "Memory",
            "ApplicationControl", "Writer",
        ].map { try AgentConfigurations.load(named: $0) }
        let policy = try CommunicationPolicy(
            contracts: AgentContracts.communication, configurations: configurations)
        input = InputGateway(manager: manager, policy: policy)
        context = try AgentContextRepository(
            agent: .applicationControl, scope: sessionID, state: ApplicationControlContextState())
        let agent = try ApplicationControlAgent(sessionID: sessionID, context: context)
        let presentation = RuntimePresentation(
            rootSessionID: sessionID, activity: activity.state,
            effects: ui.home.effects, expressions: ui.home.expressions,
            homeBluetooth: ui.home.conversation, deviceBluetooth: ui.devices.state)
        let function = UIActions.recordFailureDefinition(completing: { invocation in
            if rejectPresentation { throw InjectedContainerFailure.operation(99) }
            return .value(try await UIActions.recordFailure(invocation: invocation, using: presentation))
        })
        output = await OutputGateway(
            manager: manager, requests: input,
            tools: try ToolRegistry(modules: [
                DiagnosticTools(
                    definitions: try [
                        function,
                        UIActions.setLoadingDefinition(handler: { invocation in
                            try await UIActions.setLoading(invocation: invocation, using: presentation)
                        }),
                        UIActions.showBluetoothHomeDefinition(completing: { invocation in
                            .value(try await UIActions.showBluetoothHome(invocation: invocation, using: presentation))
                        }),
                        UIActions.showBluetoothSettingsDefinition(completing: { invocation in
                            .value(
                                try await UIActions.showBluetoothSettings(invocation: invocation, using: presentation))
                        }),
                    ].map(BehaviorProtocolBindings.bind))
            ]),
            policy: policy, sink: { _ in })
        runtime = ApplicationControlExecutionSession(
            manager: manager, output: output, agent: agent)
    }
    func start(activity: ActionActivityWorkflow) async throws {
        try ui.start()
        try await runtime.prepareForInteraction()
        activity.startFailures { try await output.observeFailures() }
        activity.connectFailures { event in try await runtime.agent.observeFailure(event) }
    }
    func stop(activity: ActionActivityWorkflow) async {
        await activity.stopFailureObservations()
        await runtime.shutdown()
        await output.shutdown()
        await input.shutdown()
        await ui.stop()
    }
}

@Test(.actionCatalog) @MainActor func homePreparationValidationFailureReachesBusinessToastWithOriginalError()
    async throws
{
    let state = ActionActivityState()
    let activity = ActionActivityWorkflow(state: state)
    let fixture = try await RuntimeFailurePresentationFixture(activity: activity)
    try await fixture.start(activity: activity)
    let channel = ContainerFailureChannel()
    channel.start()
    channel.connect { event in try await fixture.runtime.agent.observeFailure(event) }
    let preparation = ForegroundPreparation(
        steps: { [.init(id: "language", isReady: { false }, prepare: { _ in })] },
        canPrepare: { true }, project: { _ in },
        onValidationFailure: { component, error in
            channel.report(module: "app", component: "homePreparation", operation: "verify." + component, error: error)
        })

    preparation.setActive(true)
    try await containerEventually { state.errorToast != nil }
    #expect(state.backgroundIssues.count == 1)
    #expect(state.visibleNotice?.text == "基础能力发生异常，请查看运行异常")
    #expect(state.backgroundIssues.first?.message.contains("notReady") == true)
    #expect(channel.snapshot().records.first?.error as? ForegroundPreparation.ValidationError == .notReady)
    #expect(channel.snapshot().records.count == 1)

    await preparation.stop()
    await channel.stop()
    await fixture.stop(activity: activity)
}

@Test @MainActor func containerFailureRegistrySharesNativeReportersAndIsolatesRoots() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let registry = ApplicationContainer(root: root)
    let other = ApplicationContainer(root: root.appendingPathComponent("other"))
    let channel = registry.containerFailures()
    #expect(channel === registry.containerFailures())
    #expect(channel !== other.containerFailures())
    let storage = registry.storage()
    #expect(!FileManager.default.fileExists(atPath: root.path))
    #expect(throws: StorageError.missing) { try storage.cache.buffers.get("missing") }
    #expect(throws: StorageError.forbidden) { try storage.files.file(other.storage().files.photos) }
    #expect(throws: RecordStorageError.notReady) { try storage.database.chat }
    let display = registry.ui()
    display.camera.state.presentRendererFailure(
        "synthetic renderer failure", generation: display.camera.state.videoGeneration)
    let snapshot = channel.snapshot()
    #expect(
        Set(snapshot.records.map { $0.event.component }).isSuperset(of: [
            "cache.buffers", "files", "database", "camera.renderer",
        ]))
    #expect(snapshot.records.allSatisfy { $0.event.scopeID == channel.scopeID })
    #expect(other.containerFailures().snapshot().records.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    await display.stop()
    await channel.stop()
    await other.containerFailures().stop()
}

@Test(.actionCatalog) @MainActor func containerFailureBroadcastReachesAssistantAndToastWithoutInferenceOrPersistence()
    async throws
{
    let manager = AgentManager()
    let configurations = try [
        "Assistant", "SpeechPerception", "SpeechSynthesis", "VisionPerception", "Photographer", "Memory",
        "ApplicationControl", "Writer",
    ].map {
        try AgentConfigurations.load(named: $0)
    }
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication,
        configurations: configurations)
    let input = InputGateway(manager: manager, policy: policy)
    let context = try AgentContextRepository(
        agent: .assistant, scope: "diagnostic-root", state: AssistantContextState())
    let chat = DiagnosticChat()
    let agent = try AssistantAgent(stateContext: try publicStateFixture(), chat: chat, context: context)
    try await manager.register(agent, sessionID: "diagnostic-session")
    try await agent.start()
    let channel = ContainerFailureChannel()
    let activity = ActionActivityWorkflow(state: ActionActivityState())
    let controlContext = try AgentContextRepository(
        agent: .applicationControl, scope: "diagnostic-root", state: ApplicationControlContextState())
    let control = try ApplicationControlAgent(sessionID: "diagnostic-session", context: controlContext)
    let display = UIContainer()
    try display.start()
    let presentation = RuntimePresentation(
        rootSessionID: "diagnostic-session", activity: activity.state,
        effects: display.home.effects, expressions: display.home.expressions,
        homeBluetooth: display.home.conversation, deviceBluetooth: display.devices.state)
    let function = UIActions.recordFailureDefinition(completing: { invocation in
        .value(try await UIActions.recordFailure(invocation: invocation, using: presentation))
    })
    let output = await OutputGateway(
        manager: manager, requests: input,
        tools: try ToolRegistry(modules: [DiagnosticTools(definitions: [try BehaviorProtocolBindings.bind(function)])]),
        policy: policy, sink: { _ in })
    let runtime = ApplicationControlExecutionSession(
        manager: manager, output: output, agent: control)
    try await runtime.prepareForInteraction()
    channel.report(
        module: "storage", component: "database", operation: "read", error: InjectedContainerFailure.operation(1))
    #expect(channel.snapshot().records.first?.delivery == .pending)
    channel.start()
    channel.connect { event in
        try await control.observeFailure(event)
        try await agent.observeFailure(event)
    }
    try await containerEventually {
        await agent.receivedContainerFailures().count == 1 && activity.state.backgroundIssues.count == 1
    }
    let first = try #require(await agent.receivedContainerFailures().first)
    #expect(first.scopeID == channel.scopeID)
    #expect(first.component == "database")
    #expect(activity.state.errorToast?.failureCode == "container.failure")
    let toastID = try #require(activity.state.errorToast?.id)
    activity.state.dismissErrorToast(id: toastID)
    for _ in 0..<100 {
        channel.report(
            module: "storage", component: "database", operation: "read", error: InjectedContainerFailure.operation(1))
    }
    try await containerEventually { await agent.receivedContainerFailures().first?.occurrences == 101 }
    try await containerEventually {
        guard let presented = activity.state.backgroundIssues.first?.time,
            let reported = channel.snapshot().records.first?.event.lastOccurred
        else { return false }
        return abs(presented.timeIntervalSince(reported)) < 0.001
    }
    #expect(activity.state.backgroundIssues.count == 1)
    #expect(activity.state.errorToast == nil)
    #expect(await chat.calls == 0)
    #expect(try await context.snapshot().state.history.current.turns.isEmpty)
    #expect(try await context.snapshot().state.admissionSequence == 0)
    #expect(try await controlContext.snapshot().revision == 0)
    #expect(await control.failurePresentationErrors().isEmpty)
    var traces = try await input.observeSignals().makeAsyncIterator()
    let records = try #require(await traces.next()).records
    #expect(
        !records.contains { $0.contract == ContainerFailureEvent.contract })
    channel.disconnect()
    await runtime.shutdown()
    await output.shutdown()
    await channel.stop()
    await input.shutdown()
    await manager.stopAll()
    await display.stop()
}

@Test @MainActor func containerFailureJournalBoundsCoalescesAndRetainsShutdownEvidence() async throws {
    let channel = ContainerFailureChannel()
    for index in 0..<130 {
        channel.report(
            module: "platform", component: "audio", operation: "capture",
            error: InjectedContainerFailure.operation(index))
    }
    let snapshot = channel.snapshot()
    #expect(snapshot.records.count == 128)
    #expect(snapshot.evictedRecords == 2)
    #expect(snapshot.droppedPending == 66)
    #expect(snapshot.records.filter { $0.delivery == .pending }.count == 64)
    var observers: [AsyncStream<ContainerFailureSnapshot>] = []
    for _ in 0..<8 { observers.append(try channel.observe()) }
    #expect(throws: CommunicationError.capacityExceeded) { try channel.observe() }
    #expect(!channel.report(module: "ui", component: "camera", operation: "stop", error: CancellationError()))
    #expect(channel.snapshot().records.count == 128)
    await channel.stop()
    #expect(
        !channel.report(
            module: "ui", component: "camera", operation: "late", error: InjectedContainerFailure.operation(999)))
    #expect(channel.snapshot().rejectedAfterStop == 1)
    #expect(channel.snapshot().records.count == 128)
    var retained = observers[0].makeAsyncIterator()
    #expect(await retained.next()?.records.count == 128)
    #expect(await retained.next() == nil)
}

@Test @MainActor func containerFailureTransportFailureDoesNotRecurseAndCanReconnect() async throws {
    let channel = ContainerFailureChannel()
    channel.start()
    channel.connect { _ in throw InjectedContainerFailure.transport }
    channel.report(module: "ui", component: "camera", operation: "render", error: InjectedContainerFailure.operation(1))
    try await containerEventually { channel.snapshot().records.first?.delivery == .failed }
    #expect(channel.snapshot().records.count == 1)
    #expect(channel.snapshot().records.first?.deliveryFailure?.contains("transport") == true)
    let count = Mutex(0)
    channel.connect { _ in count.withLock { $0 += 1 } }
    try await containerEventually { channel.snapshot().records.first?.delivery == .published }
    #expect(count.withLock { $0 } == 1)
    #expect(channel.snapshot().records.first?.event.occurrences == 1)
    channel.disconnect()
    channel.report(module: "ui", component: "camera", operation: "render", error: InjectedContainerFailure.operation(1))
    #expect(channel.snapshot().records.first?.delivery == .pending)
    #expect(count.withLock { $0 } == 1)
    await channel.stop()
}

@Test @MainActor func containerFailureStopJoinsNonCooperativePublisherAndCoalescesPendingRepeats() async throws {
    let channel = ContainerFailureChannel()
    let gate = DiagnosticPublicationGate()
    let sent = Mutex<[UInt64]>([])
    channel.connect { event in
        sent.withLock { $0.append(event.occurrences) }
        await gate.wait()
    }
    channel.start()
    channel.report(
        module: "platform", component: "camera", operation: "capture", error: InjectedContainerFailure.operation(1))
    var entered = await gate.entered.stream.makeAsyncIterator()
    _ = await entered.next()
    for _ in 0..<100 {
        channel.report(
            module: "platform", component: "camera", operation: "capture", error: InjectedContainerFailure.operation(1))
    }
    #expect(channel.snapshot().records.count == 1)
    #expect(channel.snapshot().records.first?.event.occurrences == 101)
    let finished = Mutex(false)
    let stopping = Task {
        await channel.stop()
        finished.withLock { $0 = true }
    }
    try await Task.sleep(for: .milliseconds(20))
    #expect(!finished.withLock { $0 })
    await gate.release()
    await stopping.value
    #expect(finished.withLock { $0 })
    #expect(sent.withLock { $0 } == [1])
}

@Test @MainActor func containerFailureStorageRollbackPreservesPrimaryAndCleanupBeforeAgentStartup() async throws {
    let channel = ContainerFailureChannel()
    let reporter = StorageFailureReporter(
        receive: channel.sink(module: "storage", details: ApplicationContainer.failureDetails))
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: path) }
    let files = FilesContainer(settings: path, photos: path, models: path, failures: reporter)
    let storage = StorageContainer(database: FailedDiagnosticDatabase(), files: files, failures: reporter)
    let startedAgent = Mutex(false)
    let lifecycle = try ApplicationLifecycle(services: [
        ManagedService(id: "diagnostics", start: { channel.start() }, stop: { await channel.stop() }),
        ManagedService(
            id: "storage", dependencies: ["diagnostics"], start: { try await storage.start() },
            stop: { try await storage.stop() }),
        ManagedService(
            id: "agent", dependencies: ["storage"], start: { startedAgent.withLock { $0 = true } }, stop: {}),
    ])
    do {
        try await lifecycle.start()
        Issue.record("Expected startup failure")
    } catch let failure as ApplicationLifecycleFailure {
        let storage = try #require(failure.primary as? StorageFailure)
        #expect(storage.underlying as? InjectedContainerFailure == .startup)
        #expect(storage.cleanupErrors.first as? InjectedContainerFailure == .cleanup)
    }
    #expect(!startedAgent.withLock { $0 })
    #expect(!channel.snapshot().records.isEmpty)
    #expect(channel.snapshot().records.allSatisfy { $0.delivery != .published })
    #expect(channel.snapshot().records.contains { $0.event.message.contains("startup") })
    #expect(channel.snapshot().records.contains { $0.event.message.contains("cleanup") })
}

@Test(.actionCatalog) @MainActor func containerFailureAssistantRejectsForgedSourceAndMalformedEvents() async throws {
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(),
        context: AgentContextRepository(agent: .assistant, scope: "fault-auth", state: AssistantContextState()))
    try await agent.start()
    let channel = ContainerFailureChannel()
    channel.report(module: "ui", component: "camera", operation: "render", error: InjectedContainerFailure.operation(1))
    let event = try #require(channel.snapshot().records.first?.event)
    let payload = InputPayload.observation(
        AgentMessage(contract: ContainerFailureEvent.contract, content: event, validate: { try $0.validate() }))
    await #expect(throws: CommunicationError.unauthorized) {
        try await agent.receive(
            AgentInput(
                id: "forged", sessionID: "s", payload: payload,
                metadata: InputMetadata(payload: payload, source: "user", rootID: "forged")))
    }
    await #expect(throws: CommunicationError.unauthorized) {
        try await agent.receive(
            AgentInput(
                id: "forged-agent", sessionID: "s", payload: payload,
                metadata: InputMetadata(
                    payload: payload, source: "runtime", incarnation: "fake", origin: .agent, rootID: "forged-agent")))
    }
    var invalid = event
    invalid.occurrences = 0
    #expect(throws: CommunicationError.invalidPayload) { try invalid.validate() }
    #expect(await agent.receivedContainerFailures().isEmpty)
    await channel.stop()
    await agent.stop()
}

@Test func containerFailureNativeSubscriberOverflowIsReportedWithoutStoppingOtherInputs() async throws {
    let channel = ContainerFailureChannel()
    let admission = PlatformAdmission(onFailure: channel.sink(module: "platform"))
    let broadcast = NativeInputBroadcast<Int> { error in admission.report("audio.capture", "subscriber", error) }
    let slow = try broadcast.subscribe(.ordered)
    let latest = try broadcast.subscribe(.latest)
    for value in 0..<65 { broadcast.send(value) }
    var slowValues = slow.makeAsyncIterator()
    for value in 0..<64 { #expect(try await slowValues.next() == value) }
    await #expect(throws: NativeSubscriptionError.self) { try await slowValues.next() }
    var current = latest.makeAsyncIterator()
    #expect(try await current.next() == 64)
    let record = try #require(channel.snapshot().records.first)
    #expect(record.event.module == "platform")
    #expect(record.event.component == "audio.capture")
    #expect(record.event.message.contains("overflow"))
    broadcast.finish()
    await channel.stop()
}

@Test @MainActor func containerFailureStorageLeafOperationsRetainThrownErrorsAndReportAtTheirOwner() async throws {
    let channel = ContainerFailureChannel()
    let reporter = StorageFailureReporter(
        receive: channel.sink(module: "storage", details: ApplicationContainer.failureDetails))
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: path) }
    let files = FilesContainer(settings: path, photos: path, models: path, failures: reporter)
    try files.start()
    let document = try files.document(String.self, in: files.settings, name: "limited.json", maximumBytes: 16)
    await #expect(throws: DocumentStorageError.capacityExceeded) {
        try await document.replace(String(repeating: "x", count: 100))
    }
    let bytes = try files.file(files.photos)
    await #expect(throws: FileStorageError.invalidPath) { try await bytes.read("../outside", maximumBytes: 64) }
    let cache = CacheContainer(failures: reporter)
    let audio = try await cache.audioScope("session")
    let owner = AudioCache.Owner(source: "synthetic", session: "session", input: "input")
    try await audio.register("stream", owner: owner, cancel: {})
    let stream = try await audio.begin("stream")
    await stream.fail(InjectedContainerFailure.operation(3))
    await #expect(throws: InjectedContainerFailure.operation(3)) { try await stream.next() }
    let components = Set(channel.snapshot().records.map { $0.event.component })
    #expect(components.isSuperset(of: ["files.document", "files.bytes", "cache.audio.stream"]))
    await cache.close()
    await files.close()
    await channel.stop()
}

@Test func containerFailureExplicitLifecycleCancellationIsBroadcastButNormalCancellationIsRetained() async {
    let channel = ContainerFailureChannel()
    #expect(!channel.report(module: "storage", component: "lifecycle", operation: "start", error: CancellationError()))
    #expect(channel.snapshot().records.count == 1)
    #expect(channel.snapshot().records.first?.delivery == .suppressed)
    #expect(channel.snapshot().records.first?.error is CancellationError)
    #expect(
        channel.report(
            module: "storage", component: "lifecycle", operation: "start", phase: .startup, error: CancellationError(),
            includeCancellation: true))
    #expect(channel.snapshot().records.count == 2)
    #expect(channel.snapshot().records.last?.event.phase == .startup)
    await channel.stop()
}

@Test(.actionCatalog) @MainActor func applicationControlOwnsRuntimeFailurePolicyAndKeepsCorrelation() async throws {
    let activity = ActionActivityWorkflow(state: ActionActivityState())
    let fixture = try await RuntimeFailurePresentationFixture(activity: activity)
    activity.recordFailure(
        title: "Model", source: "assistant", message: "native transport cause", failureCode: "agent.model.transport",
        context: .init(workerID: "worker", sessionID: "business", inputID: "input", roundID: "round"),
        diagnostic: .init(category: .modelTransport, code: "agent.model.transport", detail: "native transport cause"))
    #expect(activity.state.backgroundIssues.isEmpty && activity.state.errorToast == nil)
    try await fixture.start(activity: activity)
    try await containerEventually { activity.state.backgroundIssues.count == 1 }
    let issue = try #require(activity.state.backgroundIssues.first)
    #expect(issue.category == "模型连接异常")
    #expect(issue.userMessage == "模型连接失败，请检查网络后重试")
    #expect(issue.context?.sessionID == "business" && issue.context?.inputID == "input")
    #expect(issue.context?.workerID == "worker" && issue.context?.roundID == "round")
    #expect(try await fixture.context.snapshot().revision == 0)
    await fixture.stop(activity: activity)
}

@Test(.actionCatalog) @MainActor func applicationControlRecordsStaleEvidenceWhilePausedWithoutToast() async throws {
    let activity = ActionActivityWorkflow(state: ActionActivityState())
    let fixture = try await RuntimeFailurePresentationFixture(activity: activity)
    try await fixture.start(activity: activity)
    try await fixture.runtime.agent.pause()
    let event = RuntimeFailureEvent(
        id: "stale", source: "visionPerception", title: "Vision", message: "old native failure",
        time: Date().addingTimeInterval(-60), failureCode: "vision.pose.failed", category: "runtime")
    try await fixture.runtime.agent.observeFailure(event)
    try await containerEventually { activity.state.backgroundIssues.count == 1 }
    #expect(activity.state.errorToast == nil)
    #expect(activity.state.backgroundIssues.first?.category == "Agent 运行异常")
    let processed = await fixture.runtime.agent.status().processedInputs
    try await fixture.runtime.agent.observeFailure(event)
    // Joining publication shutdown below also joins the duplicate delivery.
    await fixture.input.shutdown()
    #expect(await fixture.runtime.agent.status().processedInputs == processed)
    #expect(activity.state.backgroundIssues.count == 1)
    await fixture.stop(activity: activity)
}

@Test(.actionCatalog) @MainActor func applicationControlPresentationFailureDoesNotFeedBackOrStopBusiness() async throws
{
    let activity = ActionActivityWorkflow(state: ActionActivityState())
    let fixture = try await RuntimeFailurePresentationFixture(activity: activity, rejectPresentation: true)
    try await fixture.start(activity: activity)
    activity.recordFailure(
        title: "Vision", source: "visionPerception", message: "inference failed", failureCode: "vision.pose.failed")
    try await containerEventually { await fixture.runtime.agent.failurePresentationErrors().count == 1 }
    #expect(activity.state.backgroundIssues.isEmpty && activity.state.errorToast == nil)
    #expect(await fixture.runtime.agent.status().lifecycle == .running)
    #expect(await fixture.runtime.agent.status().processedInputs == 1)
    // Barrier: observe and forward the failed presentation snapshot, then close the forwarding owner.
    var snapshots = try await fixture.output.observeFailures().makeAsyncIterator()
    #expect(await snapshots.next()?.records.count == 1)
    await activity.stopFailureObservations()
    #expect(await fixture.runtime.agent.status().processedInputs == 1)
    #expect(try await fixture.context.snapshot().revision == 0)
    await fixture.stop(activity: activity)
}

@Test @MainActor func runtimeFailureForwardingIsBoundedAndRejectsAfterStop() async {
    let activity = ActionActivityWorkflow(state: ActionActivityState())
    for index in 0..<101 {
        activity.recordFailure(title: "runtime", source: "runtime", message: "failure \(index)")
    }
    #expect(activity.rejectedFailureEvents == 1)
    #expect(activity.state.observationUnavailable)
    #expect(activity.state.backgroundIssues.isEmpty)
    await activity.stopFailureObservations()
    activity.recordFailure(title: "runtime", source: "runtime", message: "late")
    #expect(activity.rejectedFailureEvents == 2)
}

private func diagnosticInput(
    _ event: RuntimeFailureEvent, session: String, source: String = "runtime",
    deadline: ContinuousClock.Instant? = nil
) -> AgentInput {
    let payload = InputPayload.observation(
        AgentMessage(
            contract: RuntimeFailureEvent.contract, content: event, maximumBytes: 16_384,
            validate: { try $0.validate() }))
    let id = UUID().uuidString
    return AgentInput(
        id: id, sessionID: session, payload: payload,
        metadata: .init(payload: payload, source: source, rootID: id, deadline: deadline))
}

@Test(.actionCatalog) func applicationControlRejectsForgedExpiredAndStoppedDiagnostics() async throws {
    let session = UUID().uuidString
    let agent = try ApplicationControlAgent(
        sessionID: session,
        context: AgentContextRepository(
            agent: .applicationControl, scope: session, state: ApplicationControlContextState()))
    try await agent.start()
    let event = RuntimeFailureEvent(source: "assistant", title: "Model", message: "failed")
    await #expect(throws: CommunicationError.unauthorized) {
        try await agent.receive(diagnosticInput(event, session: session, source: "user"))
    }
    await #expect(throws: CommunicationError.unauthorized) {
        try await agent.receive(diagnosticInput(event, session: "other"))
    }
    await #expect(throws: CommunicationError.expired) {
        try await agent.receive(diagnosticInput(event, session: session, deadline: .now - .seconds(1)))
    }
    #expect(await agent.status().processedInputs == 0)
    await agent.stop()
    await #expect(throws: HarnessError.notRunning) {
        try await agent.receive(diagnosticInput(event, session: session))
    }
}

@Test(.actionCatalog) func applicationControlBoundsPendingDiagnosticPresentationCalls() async throws {
    let session = UUID().uuidString
    let agent = try ApplicationControlAgent(
        sessionID: session,
        context: AgentContextRepository(
            agent: .applicationControl, scope: session, state: ApplicationControlContextState()))
    try await agent.start()
    for index in 0..<128 {
        let event = RuntimeFailureEvent(id: "error-\(index)", source: "assistant", title: "Model", message: "failed")
        try await agent.receive(diagnosticInput(event, session: session))
    }
    await #expect(throws: CommunicationError.capacityExceeded) {
        try await agent.receive(
            diagnosticInput(
                RuntimeFailureEvent(source: "assistant", title: "Model", message: "overflow"), session: session))
    }
    #expect(await agent.status().processedInputs == 128)
    await agent.stop()
}

@Test(.actionCatalog) @MainActor func executionFailureObservationIsIndependentAndBounded() async throws {
    let state = ActionActivityState()
    let workflow = ActionActivityWorkflow(state: state)
    let fixture = try await RuntimeFailurePresentationFixture(activity: workflow)
    try await fixture.runtime.prepareForInteraction()
    workflow.connectFailures { event in try await fixture.runtime.agent.observeFailure(event) }
    let pair = AsyncStream<OutputFailureSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
    workflow.startFailures { pair.stream }
    let issue = OutputFailureRecord(source: .assistant, title: "Fixture.Control.tool", message: "Resource rejected")
    pair.continuation.yield(.init(revision: 1, records: [issue], evictedCount: 2))
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while state.backgroundIssues.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
    #expect(state.backgroundIssues.first?.message == "Resource rejected")
    #expect(state.items.isEmpty && state.hasRecords)
    for index in 0..<105 {
        workflow.recordFailure(title: "Worker", source: "Fixture", message: "Business failure \(index)")
        try await containerEventually { await fixture.runtime.agent.status().processedInputs >= index + 2 }
    }
    try await containerEventually { state.backgroundIssues.last?.message == "Business failure 104" }
    #expect(state.backgroundIssues.count == 100)
    #expect(state.issueEvictions == 6)
    pair.continuation.yield(.init(revision: 0, records: [], evictedCount: 0))
    pair.continuation.finish()
    await fixture.stop(activity: workflow)
}

@Test(.actionCatalog) @MainActor func speechRecognitionToastIsFriendlyAndDirectFailureDetailsStayInLog() async throws {
    let state = ActionActivityState()
    let workflow = ActionActivityWorkflow(state: state)
    let fixture = try await RuntimeFailurePresentationFixture(activity: workflow)
    try await fixture.start(activity: workflow)
    let raw = "agent.error: speech perception: Error Domain=SFSpeechErrorDomain Code=1 RecogRejected"
    workflow.recordFailure(title: "Output", source: "speechPerception", message: raw)
    try await containerEventually { state.backgroundIssues.count == 1 }
    #expect(state.visibleNotice?.text == "我没听清")
    #expect(state.backgroundIssues.first?.message == raw)
    #expect(state.errorToast?.message == raw)
    workflow.recordFailure(title: "Output", source: "assistant", message: "agent.error: Fixture failure")
    try await containerEventually { state.backgroundIssues.count == 2 }
    #expect(state.visibleNotice?.text == "Fixture failure")
    #expect(state.backgroundIssues.last?.message == "agent.error: Fixture failure")
    await fixture.stop(activity: workflow)
}

@Test(.actionCatalog) @MainActor func speechRecognitionSnapshotToastPreservesDetailedRecordAndInput() async throws {
    let state = ActionActivityState()
    let workflow = ActionActivityWorkflow(state: state)
    let fixture = try await RuntimeFailurePresentationFixture(activity: workflow)
    try await fixture.runtime.prepareForInteraction()
    workflow.connectFailures { event in try await fixture.runtime.agent.observeFailure(event) }
    let pair = AsyncStream<OutputFailureSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
    workflow.startFailures { pair.stream }
    let inputID = UUID().uuidString
    let raw = "agent.error: speech perception: Error Domain=SFSpeechErrorDomain Code=1 RecogRejected"
    let issue = OutputFailureRecord(source: .speechPerception, title: "Output", message: raw, inputID: inputID)
    pair.continuation.yield(.init(revision: 1, records: [issue], evictedCount: 0))
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while state.backgroundIssues.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
    #expect(state.visibleNotice?.text == "我没听清")
    #expect(state.visibleNotice?.id == "runtime:" + issue.id)
    #expect(state.backgroundIssues.first?.message == raw && state.backgroundIssues.first?.inputID == inputID)
    #expect(state.errorToast?.message == raw)
    pair.continuation.finish()
    await fixture.stop(activity: workflow)
}

@Test(.actionCatalog) @MainActor func agentProtocolFailureProjectsShortToastFullDetailAndCorrelation() async throws {
    let state = ActionActivityState()
    let workflow = ActionActivityWorkflow(state: state)
    let fixture = try await RuntimeFailurePresentationFixture(activity: workflow)
    try await fixture.runtime.prepareForInteraction()
    workflow.connectFailures { event in try await fixture.runtime.agent.observeFailure(event) }
    let pair = AsyncStream<OutputFailureSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
    workflow.startFailures { pair.stream }
    let detail =
        "stage=toolStart\nevent=response.output_item.added\ntool=loadSkills\n" + String(repeating: "x", count: 900)
    let fault = AgentFailureDiagnostic(
        category: .modelResponse, code: "agent.model.tool.undeclaredName", detail: detail)
    let record = OutputFailureRecord(
        source: .assistant, title: "modelResponse", message: detail,
        failureCode: fault.code, inputID: "input-1", diagnostic: fault, sessionID: "session-1", roundID: "round-1")
    pair.continuation.yield(.init(revision: 1, records: [record], evictedCount: 0))
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while state.backgroundIssues.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
    let issue = try #require(state.backgroundIssues.first)
    #expect(state.visibleNotice?.text == "模型调用了未声明的工具，本次回复已中止")
    #expect(issue.message == detail && issue.message.count > 512)
    #expect(issue.category == "模型响应异常" && issue.failureCode == fault.code)
    #expect(issue.context?.sessionID == "session-1" && issue.context?.roundID == "round-1")
    #expect(issue.inputID == "input-1" && state.errorToast?.id == "runtime:" + record.id)
    state.dismissErrorToast(id: "runtime:" + record.id)
    pair.continuation.yield(.init(revision: 2, records: [record], evictedCount: 0))
    while state.backgroundIssues.first?.id != "runtime:" + record.id && ContinuousClock.now < deadline {
        await Task.yield()
    }
    #expect(state.errorToast == nil && state.backgroundIssues.first?.message == detail)
    pair.continuation.finish()
    await fixture.stop(activity: workflow)
}

@Test @MainActor func normalAudioReleaseDoesNotReportFailureButRealMissingStillDoes() async throws {
    let channel = ContainerFailureChannel()
    let cache = CacheContainer(
        failures: StorageFailureReporter(
            receive: channel.sink(module: "storage", details: ApplicationContainer.failureDetails)))
    let audio = try await cache.audioScope("playback")
    let owner = AudioCache.Owner(source: "synthesis", session: "playback", input: "reply")
    let cancellations = Mutex(0)
    try await audio.register("finished", owner: owner) {
        await Task.yield()
        cancellations.withLock { $0 += 1 }
    }
    let produced = try await audio.begin("finished")
    let frame = try StorageCache.AudioFrame(
        data: Data(repeating: 0, count: 16),
        format: .init(sampleRate: 16000, channels: 1, encoding: .signedInt16), sequence: 0, timestamp: 0)
    try await produced.append(frame)
    await audio.complete("finished")
    let playback = try await audio.checkout("finished", owner: owner)
    #expect(try await playback.next() == frame)
    #expect(try await playback.next() == nil)
    try await audio.release("finished", owner: owner)
    #expect(cancellations.withLock { $0 } == 1)
    #expect(channel.snapshot().records.isEmpty)

    // A genuinely invalid access must still fail and report; do not globally filter missing.
    await #expect(throws: AudioCacheError.missingAudio) { try await audio.validate("finished", owner: owner) }
    #expect(channel.snapshot().records.contains { $0.event.operation == "validate" })
    try await audio.register("failed", owner: owner, cancel: {})
    let failed = try await audio.begin("failed")
    await failed.fail(StorageError.missing)
    await #expect(throws: AudioCacheError.missingAudio) { try await failed.next() }
    #expect(
        channel.snapshot().records.contains {
            $0.event.component == "cache.audio.stream" && $0.event.operation == "fail"
        })
    await cache.close()
    await channel.stop()
}

@Test func audioCacheAdmissionFailureReportsOnlyItsPublicOperation() async throws {
    let reports = Mutex<[(String, String)]>([])
    let cache = CacheContainer(
        failures: StorageFailureReporter { component, operation, _ in
            reports.withLock { $0.append((component, operation)) }
        })
    let audio = try await cache.audioScope("closed-scope")
    await cache.close()
    await #expect(throws: AudioCacheError.closed) { _ = try await audio.begin("late") }
    let cancelled = Mutex(false)
    await #expect(throws: AudioCacheError.closed) {
        try await audio.register("late", owner: .init(source: "test", session: "s", input: "i")) {
            cancelled.withLock { $0 = true }
        }
    }
    let recorded = reports.withLock { $0 }
    #expect(recorded.count == 2)
    #expect(recorded.map(\.0) == ["cache.audio", "cache.audio"])
    #expect(recorded.map(\.1) == ["begin", "register"])
    #expect(!cancelled.withLock { $0 })
}

@Test func bluetoothConnectionConditionsKeepNativeEvidenceAndDoNotMaskTransportFaults() async {
    let channel = ContainerFailureChannel()
    channel.report(
        module: "platform", component: "connectivity.bluetooth", operation: "scan",
        error: NexArmBluetoothError.unavailable)
    channel.report(
        module: "platform", component: "connectivity.bluetooth", operation: "connect",
        error: NexArmBluetoothFailure.timeout(.connecting))
    channel.report(
        module: "platform", component: "connectivity.bluetooth", operation: "write",
        error: NexArmBluetoothFailure.sendBlocked)
    let records = channel.snapshot().records
    #expect(records[0].event.code == "bluetooth.unavailable")
    #expect(records[0].event.message == "unavailable")
    #expect(records[1].event.code == "bluetooth.connectionUnavailable")
    #expect(records[2].event.code != "bluetooth.connectionUnavailable")
    await channel.stop()
}

@Test func bluetoothRawConnectionTimeoutKeepsEvidenceWithoutMaskingOtherTimeouts() async throws {
    let channel = ContainerFailureChannel()
    let wrapped = PlatformFailure(
        component: "connectivity.bluetooth", operation: "connect", underlying: NexArmError.timeout)
    let cleanup = PlatformFailure(
        component: "connectivity.bluetooth", operation: "connect", underlying: NexArmError.timeout,
        cleanupErrors: [NexArmBluetoothFailure.disconnectUnconfirmed])
    for (operation, error) in [
        ("connect", NexArmError.timeout as any Error), ("connect", wrapped), ("write", NexArmError.timeout),
        ("exchange", NexArmError.timeout), ("connect", cleanup),
    ] {
        channel.report(module: "platform", component: "connectivity.bluetooth", operation: operation, error: error)
    }
    let records = channel.snapshot().records
    #expect(records.count == 5)
    #expect(records.prefix(2).allSatisfy { $0.event.code == "bluetooth.connectionUnavailable" })
    #expect(records.dropFirst(2).allSatisfy { $0.event.code != "bluetooth.connectionUnavailable" })
    #expect(records[0].error as? NexArmError == .timeout)
    #expect((records[1].error as? PlatformFailure)?.underlying as? NexArmError == .timeout)
    #expect((records[4].error as? PlatformFailure)?.cleanupErrors.count == 1)
    await channel.stop()
}

private func bluetoothEnvironment(
    connection: String, availability: String = "available", recovery: String = "idle", sequence: UInt64
) throws -> AppEnvironmentFact {
    let facts = try JSONSerialization.data(withJSONObject: [
        "connection": connection, "availability": availability, "recovery": recovery,
    ])
    let value = try JSONSerialization.data(withJSONObject: ["bluetooth": String(decoding: facts, as: UTF8.self)])
    return .init(category: .devices, sequence: sequence, value: String(decoding: value, as: UTF8.self))
}

@Test(.actionCatalog) @MainActor func bluetoothUnavailabilityIsPresentedAsStateWithoutFailureToast() async throws {
    let activity = ActionActivityWorkflow(state: ActionActivityState())
    let fixture = try await RuntimeFailurePresentationFixture(activity: activity)
    try await fixture.start(activity: activity)
    let channel = ContainerFailureChannel()
    channel.start()
    channel.connect { event in try await fixture.runtime.agent.observeFailure(event) }
    channel.report(
        module: "platform", component: "connectivity.bluetooth", operation: "scan",
        error: NexArmBluetoothError.unavailable)
    try await containerEventually { await fixture.runtime.agent.status().processedInputs >= 1 }
    try await fixture.runtime.prepareForInteraction()
    try await fixture.runtime.agent.observeEnvironment(bluetoothEnvironment(connection: "connecting", sequence: 1))
    try await containerEventually {
        fixture.ui.home.conversation.bluetoothStatus == .connecting
            && fixture.ui.devices.state.connectionPresentation == .connecting
    }
    #expect(activity.state.errorToast == nil && activity.state.backgroundIssues.isEmpty)
    try await fixture.runtime.prepareForInteraction()
    try await fixture.runtime.agent.observeEnvironment(bluetoothEnvironment(connection: "connected", sequence: 2))
    try await containerEventually {
        fixture.ui.home.conversation.bluetoothStatus == .connected
            && fixture.ui.devices.state.connectionPresentation == .connected
    }
    let processedBeforeLateCondition = await fixture.runtime.agent.status().processedInputs
    channel.report(
        module: "platform", component: "connectivity.bluetooth", operation: "scan",
        error: NexArmBluetoothError.unavailable)
    try await containerEventually {
        await fixture.runtime.agent.status().processedInputs > processedBeforeLateCondition
    }
    #expect(fixture.ui.home.conversation.bluetoothStatus == .connected)
    try await fixture.runtime.prepareForInteraction()
    try await fixture.runtime.agent.observeEnvironment(
        bluetoothEnvironment(connection: "idle", recovery: "waiting", sequence: 3))
    try await containerEventually { fixture.ui.home.conversation.bluetoothStatus == .connecting }
    try await fixture.runtime.prepareForInteraction()
    try await fixture.runtime.agent.observeEnvironment(
        bluetoothEnvironment(connection: "idle", availability: "poweredOff", sequence: 4))
    try await containerEventually {
        fixture.ui.home.conversation.bluetoothStatus == .disconnected
            && fixture.ui.devices.state.connectionPresentation == .disconnected
    }
    #expect(activity.state.errorToast == nil && activity.state.backgroundIssues.isEmpty)
    let processedBeforeTimeout = await fixture.runtime.agent.status().processedInputs
    channel.report(
        module: "platform", component: "connectivity.bluetooth", operation: "connect",
        error: PlatformFailure(
            component: "connectivity.bluetooth", operation: "connect", underlying: NexArmError.timeout))
    try await containerEventually { await fixture.runtime.agent.status().processedInputs > processedBeforeTimeout }
    #expect(fixture.ui.home.conversation.bluetoothStatus == .disconnected)
    #expect(activity.state.errorToast == nil && activity.state.backgroundIssues.isEmpty)
    #expect(channel.snapshot().records.contains { $0.event.code == "bluetooth.connectionUnavailable" })
    channel.report(
        module: "platform", component: "connectivity.bluetooth", operation: "write",
        error: NexArmError.timeout)
    try await containerEventually { activity.state.errorToast != nil }
    #expect(channel.snapshot().records.contains { $0.event.code == "bluetooth.unavailable" })
    await channel.stop()
    await fixture.stop(activity: activity)
}

@Test(.actionCatalog) @MainActor func bluetoothPresentationActionsRejectForeignSessionsAndStaleRevisions() async throws
{
    let root = UIContainer()
    try root.start()
    let presentation = RuntimePresentation(
        rootSessionID: "bluetooth-root", activity: root.home.activity,
        effects: root.home.effects, expressions: root.home.expressions,
        homeBluetooth: root.home.conversation, deviceBluetooth: root.devices.state)
    func invocation(
        source: String = "applicationControl", session: String = "bluetooth-root", revision: String = "2",
        extra: Bool = false
    ) -> FunctionInvocation {
        var parameters = ["phase": "connected", "revision": revision]
        if extra { parameters["unknown"] = "value" }
        return FunctionInvocation(
            call: FunctionRequest(
                actionPath: ActionIdentifier(domain: "UI", module: "BluetoothStatus", function: "showBluetoothHome"),
                parameters: parameters),
            context: ActionExecutionContext(source: source, sessionID: session, inputID: UUID().uuidString),
            executionID: UUID().uuidString, results: ActionReportStore())
    }
    for value in [invocation(session: "retired-root"), invocation(extra: true)] {
        await #expect(throws: (any Error).self) {
            _ = try await UIActions.showBluetoothHome(invocation: value, using: presentation)
        }
    }
    _ = try await UIActions.showBluetoothHome(invocation: invocation(), using: presentation)
    #expect(root.home.conversation.bluetoothStatus == .connected)
    await #expect(throws: UIContainerError.stale) {
        _ = try await UIActions.showBluetoothHome(invocation: invocation(revision: "1"), using: presentation)
    }
    #expect(!root.devices.state.controlReady)
    await root.stop()
    await #expect(throws: UIContainerError.stale) {
        _ = try await UIActions.showBluetoothHome(invocation: invocation(revision: "3"), using: presentation)
    }
}

private struct DetailedContainerError: Error, CustomStringConvertible {
    let detail: String
    let underlying: NSError
    var description: String { detail }
}

@Test func containerFailureRetainsOriginalErrorAndDistinguishesLongSharedPrefixes() async {
    let channel = ContainerFailureChannel()
    let prefix = String(repeating: "x", count: 700)
    let native = NSError(domain: "native.test", code: 42, userInfo: ["detail": "original"])
    for suffix in ["first", "second"] {
        channel.report(
            module: "storage", component: "files", operation: "read",
            error: DetailedContainerError(detail: prefix + suffix, underlying: native))
    }
    let records = channel.snapshot().records
    #expect(records.count == 2)
    #expect(records[0].event.message == records[1].event.message)
    #expect(records[0].fullMessage == prefix + "first")
    #expect(records[1].fullMessage == prefix + "second")
    #expect((records[0].error as? DetailedContainerError)?.underlying === native)
    await channel.stop()
}

@Test @MainActor func foundationalLifecycleErrorsRetainEvidenceWithoutBusinessPublication() async throws {
    let registry = ApplicationContainer(
        root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let channel = registry.containerFailures()
    let publications = Mutex(0)
    channel.connect { _ in publications.withLock { $0 += 1 } }
    channel.start()
    let platform = registry.platform()
    await #expect(throws: PlatformFailure.self) { try await platform.setForeground(true) }
    let model = registry.model()
    await #expect(throws: ModelFailure.self) { try await model.setForeground(true) }
    let reporter = StorageFailureReporter(
        receive: channel.sink(module: "storage", details: ApplicationContainer.failureDetails))
    reporter.report("root", "stop", CancellationError())
    let records = channel.snapshot().records
    #expect(records.count == 3)
    #expect(records.allSatisfy { $0.delivery == .suppressed })
    #expect(records.contains { ($0.error as? PlatformFailure)?.underlying is PlatformError })
    #expect(records.contains { ($0.error as? ModelFailure)?.underlying is InferenceAdmissionError })
    #expect(records.contains { ($0.error as? StorageFailure)?.underlying is CancellationError })
    await channel.stop()
    #expect(publications.withLock { $0 } == 0)
}

@Test(.actionCatalog) @MainActor func modelPreparationLoadingEyesCrossGatewayAgentAndExpressionAction() async throws {
    let ui = UIContainer()
    let activity = ActionActivityWorkflow(state: ui.home.activity)
    let fixture = try await RuntimeFailurePresentationFixture(activity: activity)
    try await fixture.start(activity: activity)
    fixture.ui.home.presentModelPreparation(.preparing("language"))
    #expect(!fixture.ui.home.conversation.isVoiceActive)
    try await fixture.runtime.prepareForInteraction()
    try await fixture.runtime.agent.observeEnvironment(
        .init(category: .modelPreparation, sequence: 1, value: "loading"))
    try await containerEventually { fixture.ui.home.conversation.displayedExpression == .loading }
    #expect(fixture.ui.home.activity.errorToast == nil)
    fixture.ui.invalidate()
    try fixture.ui.setForeground(true)
    fixture.ui.home.presentModelPreparation(.preparing("language"))
    try await fixture.runtime.prepareForInteraction()
    try await fixture.runtime.agent.observeEnvironment(
        .init(category: .modelPreparation, sequence: 2, value: "loading"))
    try await containerEventually { fixture.ui.home.conversation.displayedExpression == .loading }
    fixture.ui.home.presentModelPreparation(.ready)
    try await fixture.runtime.prepareForInteraction()
    try await fixture.runtime.agent.observeEnvironment(.init(category: .modelPreparation, sequence: 3, value: "idle"))
    try await containerEventually { !fixture.ui.home.conversation.loadingExpression }
    #expect(fixture.ui.home.conversation.displayedExpression == .closed)
    #expect(!fixture.ui.home.conversation.isVoiceActive)
    await fixture.stop(activity: activity)
}

private struct UnusedLoadingHistory: HistoryPresentationCapability {
    func showHistory(invocation: any FunctionInput) async throws { throw InjectedContainerFailure.operation(404) }
}

@Test(.actionCatalog) @MainActor func loadingExpressionStateCompletionPassesRealExecutorAndReturningTool() async throws
{
    let root = UIContainer()
    try root.start()
    root.home.presentModelPreparation(.preparing("language"))
    let presentation = RuntimePresentation(
        rootSessionID: "loading-root", activity: root.home.activity,
        effects: root.home.effects, expressions: root.home.expressions,
        homeBluetooth: root.home.conversation, deviceBluetooth: root.devices.state)
    let module = UIModule(
        expression: presentation, pose: presentation, updates: presentation, history: UnusedLoadingHistory(),
        loading: presentation)
    let definition = try #require(module.definitions.first { $0.path.description == "UI.Expression.setLoading" })
    let binding = try BehaviorProtocolBindings.bind(definition)
    let registry = try ToolRegistry(modules: [DiagnosticTools(definitions: [binding])])
    let cases: [(HomeModelPreparation, String, String, String, Bool, Bool)] = [
        (.preparing("language"), "true", "1", "applicationControl", false, true),
        (.preparing("language"), "false", "2", "applicationControl", false, false),
        (.checking, "true", "3", "applicationControl", false, false),
        (.preparing("language"), "true", "3", "applicationControl", false, false),
        (.preparing("language"), "true", "4", "applicationControl", false, true),
        (.ready, "true", "5", "applicationControl", false, false),
        (.preparing("language"), "false", "6", "applicationControl", false, false),
        (.preparing("language"), "true", "4", "applicationControl", false, false),
        (.preparing("language"), "true", "7", "applicationControl", false, true),
        (.preparing("language"), "false", "7", "applicationControl", true, true),
        (.preparing("language"), "false", "0", "applicationControl", true, true),
        (.preparing("language"), "false", "8", "assistant", false, false),
    ]
    for (preparation, enabled, revision, source, rejected, showing) in cases {
        root.home.presentModelPreparation(preparation)
        let call = ToolRequest(
            id: UUID().uuidString, toolPath: "UI.Expression.setLoading",
            arguments: ["enabled": enabled, "revision": revision])
        let response = try #require(
            try await ToolExecutor(registry: registry).execute(
                call,
                context: ActionExecutionContext(
                    source: source, sessionID: "loading-root", inputID: UUID().uuidString),
                returning: true))
        #expect(response.isError == rejected)
        if !rejected {
            #expect(response.failureCode == nil)
            #expect(response.value == "completed")
            #expect(response.completion == .completed)
        }
        #expect(root.home.conversation.loadingExpression == showing)
    }
    await root.stop()
}

@Test func modelCleanupFailureIsNotSuppressedAsAdmissionControl() async throws {
    let channel = ContainerFailureChannel()
    channel.report(module: "model", component: "root", operation: "prepare", error: InferenceAdmissionError.inactive)
    channel.report(
        module: "model", component: "root", operation: "stop",
        error: ModelFailure(
            component: "root", operation: "stop", underlying: InferenceAdmissionError.stopped,
            cleanupErrors: [CancellationError()]))
    let records = channel.snapshot().records
    #expect(records.count == 2)
    #expect(records.first?.delivery == .suppressed)
    #expect(records.last?.delivery != .suppressed)
    #expect((records.last?.error as? ModelFailure)?.cleanupErrors.count == 1)
    await channel.stop()
}

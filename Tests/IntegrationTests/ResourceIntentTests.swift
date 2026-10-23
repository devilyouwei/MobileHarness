import Actions
import AgentCore
import Agents
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import PlatformKit
import StorageCore
import StorageState
import Testing
import UI

struct UnusedModelResourceCapability: ModelResourceCapability {
    func configureSpeech(recognition: Bool, synthesis: Bool) async throws { throw CancellationError() }
    func download(_ id: String, endpoint: String, allowsCellular: Bool) async throws { throw CancellationError() }
    func cancel(_ id: String) async throws { throw CancellationError() }
    func remove(_ id: String) async throws { throw CancellationError() }
}
struct UnusedModelResourcePreferencesCapability: ModelResourcePreferencesCapability {
    func restoreSource() async throws -> ModelResourcePreferences { throw CancellationError() }
    func saveSource(_ preferences: ModelResourcePreferences) async throws -> ModelResourcePreferences {
        throw CancellationError()
    }
}
struct UnusedResourceInventory: ModelResourceInventoryCapability {
    func snapshotResources() async throws -> [ModelResourceFact] { throw CancellationError() }
}
struct UnusedResourcePresentation: ResourcePresentationCapability {
    func presentResources(_ inventory: ModelResourceInventory, generation: UInt64, invocation: any FunctionInput)
        async throws
    { throw CancellationError() }
    func presentResourcePreferenceFailure(
        _ reason: ResourcePreferenceFailureReason, message: String, invocation: any FunctionInput
    ) async throws {
        throw CancellationError()
    }
    func presentResourceOperationFailure(_ message: String, invocation: any FunctionInput) async throws {
        throw CancellationError()
    }
    func presentResourceFailure(_ message: String, generation: UInt64, invocation: any FunctionInput) async throws {
        throw CancellationError()
    }
}
private actor ResourceFixture: ModelResourceCapability {
    private var failSpeech = false
    func failNextSpeech() { failSpeech = true }
    func configureSpeech(recognition: Bool, synthesis: Bool) async throws {
        if failSpeech {
            failSpeech = false
            throw ApplicationControlIntentFailure.execution("binding fixture failed")
        }
        calls.append("speech:\(recognition):\(synthesis)")
    }
    var calls: [String] = []
    func download(_ id: String, endpoint: String, allowsCellular: Bool) async throws {
        calls.append("download:\(id):\(allowsCellular)")
        if id == "failure" { throw ApplicationControlIntentFailure.execution("fixture failure") }
    }
    func cancel(_ id: String) async throws { calls.append("cancel:\(id)") }
    func remove(_ id: String) async throws { calls.append("remove:\(id)") }
}
private struct ResourceTools: ToolModule { let definitions: [ActionBinding] }
func resourceFixturePolicy() throws -> CommunicationPolicy {
    return try CommunicationPolicy(
        contracts: AgentContracts.communication,
        configurations: AgentConfigurations.all())
}
@MainActor func resourceRuntime(
    _ resources: any ModelResourceCapability,
    preferences: any ModelResourcePreferencesCapability = ResourceTestPreferences(),
    inventory: any ModelResourceInventoryCapability = UnusedResourceInventory(),
    presentation: any ResourcePresentationCapability = UnusedResourcePresentation(),
    includeFailurePresentation: Bool = true,
    includeOperationFailurePresentation: Bool = true,
    includePreferenceFailurePresentation: Bool = true,
    nonReturningPaths: Set<String> = [],
    providerDiscovery: any ProviderDiscoveryCapability = UnusedProviderDiscovery(),
    providerSettings: any ProviderSettingsCapability = UnusedProviderSettings(),
    device: any DeviceControlCapability = UnusedDeviceControl(),
    camera: any CameraControlCapability = UnusedCameraControl(),
    uiResources: UIModelResourcesContainer? = nil, uiSettings: UISettingsContainer? = nil,
    resourceChanges: (@MainActor @Sendable () async throws -> AsyncStream<UInt64>)? = nil,
    observationFailure: @escaping @Sendable (any Error) -> Void = { _ in },
    uiProviderSettings: ProviderSettingsRequests? = nil, uiProviderDiscovery: ProviderDiscoveryRequests? = nil,
    uiProviderPresentation: ProviderPresentationAdapter? = nil,
    sessionID: String = UUID().uuidString, manager: AgentManager = AgentManager(),
    suppliedInput: InputGateway? = nil,
    suppliedContext: AgentContextRepository<ApplicationControlContextState>? = nil,
    outputSink: @escaping @Sendable (OutputEnvelope) async -> Void = { _ in }
) throws -> ResourceTestRuntime {
    let ui = UIContainer()
    try ui.start()
    let resourceUI = uiResources ?? ui.modelResources
    let settingsUI = uiSettings ?? ui.settings
    let inventoryProbe = ResourceInventoryProbe(inventory)
    let settingsRequests =
        uiProviderSettings ?? (providerSettings as? ProviderSettingsRequests)
        ?? ProviderSettingsRequests(service: ResourceProviderPersistence().service())
    let discoveryRequests =
        uiProviderDiscovery ?? (providerDiscovery as? ProviderDiscoveryRequests)
        ?? ProviderDiscoveryRequests { _ in [] }
    let providerPresentation =
        uiProviderPresentation
        ?? ProviderPresentationAdapter(
            state: settingsUI.presentation, sessionID: sessionID, settings: settingsRequests,
            discovery: discoveryRequests)
    let actualPresentation: any ResourcePresentationCapability =
        presentation is UnusedResourcePresentation
        ? ResourcePresentationAdapter(
            state: resourceUI.presentation, sessionID: sessionID, provider: providerPresentation,
            navigation: ui.navigation.presentation, acknowledge: {}) : presentation
    let session = sessionID
    let policy = try resourceFixturePolicy()
    let input = suppliedInput ?? InputGateway(manager: manager, policy: policy)
    let functions =
        ModelResourcesModule(resources: resources, preferences: preferences, inventory: inventoryProbe).definitions
        + ResourcePresentationModule(inventory: inventoryProbe, presentation: actualPresentation).definitions
        + ProviderModule(discovery: providerDiscovery, settings: providerSettings).definitions
        + DeviceModule(device: device).definitions + NavigationModule(presentation: actualPresentation).definitions
        + CameraModule(camera: camera).definitions
    let bindings = functions.filter {
        (includeFailurePresentation || $0.path.function != "showResourceFailure")
            && (includeOperationFailurePresentation || $0.path.function != "showResourceOperationFailure")
            && (includePreferenceFailurePresentation || $0.path.function != "showResourcePreferenceFailure")
    }.map {
        ActionBinding(
            function: $0, protocols: [.tool], executionPolicy: .direct,
            directResultPolicy: nonReturningPaths.contains($0.path.description) ? .completionOnly : .returning)
    }
    let output = OutputGateway(
        manager: manager, requests: input,
        tools: try ToolRegistry(modules: [ResourceTools(definitions: bindings)]),
        actions: ChannelScheduler(registry: ActionRegistry()), policy: policy, sink: outputSink)
    let host = ApplicationControlExecutionSession(
        manager: manager, output: output,
        agent: try ApplicationControlAgent(
            sessionID: session, uiSettings: settingsUI, uiResources: resourceUI, uiDevices: ui.devices,
            resourceChanges: resourceChanges, observationFailure: observationFailure,
            uiProviderSettings: settingsRequests, uiProviderDiscovery: discoveryRequests,
            uiProviderPresentation: providerPresentation,
            context: suppliedContext
                ?? AgentContextRepository(
                    agent: .applicationControl, scope: UUID().uuidString, state: ApplicationControlContextState())))
    return ResourceTestRuntime(
        host: host, ui: ui, resources: resourceUI, settings: settingsUI, inventoryProbe: inventoryProbe)
}
@Test(.actionCatalog) func modelResourceCommandsCrossGatewaysAndRecoverAfterNativeFailure() async throws {
    let fixture = ResourceFixture()
    let runtime = try await resourceRuntime(fixture)
    try await runtime.perform(.download(id: "model", endpoint: "https://example.invalid/model", allowsCellular: false))
    await #expect(throws: ApplicationControlIntentFailure.self) {
        try await runtime.perform(
            .download(id: "failure", endpoint: "https://example.invalid/model", allowsCellular: true))
    }
    try await runtime.perform(.cancel("model"))
    try await runtime.perform(.remove("model"))
    #expect(await fixture.calls == ["download:model:false", "download:failure:true", "cancel:model", "remove:model"])
    #expect(await runtime.agent.status().queuedInputs == 0)
    await runtime.shutdown()
    await #expect(throws: CommunicationError.scopeClosed) { try await runtime.perform(.cancel("model")) }
}
@Test(.actionCatalog) func modelResourceAgentRejectsDuplicateAndOverflowAndRetiresFailedDispatch() async throws {
    let session = UUID().uuidString
    let agent = try ApplicationControlAgent(
        sessionID: session,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "applicationControl"), scope: UUID().uuidString,
            state: ApplicationControlContextState())
    )
    try await agent.start()
    let first = try ModelResourceIntent.cancel("model").input(sessionID: session)
    try await agent.receive(first)
    await #expect(throws: CommunicationError.capacityExceeded) { try await agent.receive(first) }
    for _ in 1..<32 { try await agent.receive(ModelResourceIntent.cancel("model").input(sessionID: session)) }
    await #expect(throws: CommunicationError.capacityExceeded) {
        try await agent.receive(ModelResourceIntent.cancel("model").input(sessionID: session))
    }
    try await agent.receive(ModelResourceIntent.retire(first.id).input(sessionID: session))
    #expect(await agent.status().queuedInputs == 31)
    try await agent.receive(ModelResourceIntent.remove("model").input(sessionID: session))
    await agent.stop()
}

private actor HeldResourceFixture: ModelResourceCapability {
    func configureSpeech(recognition: Bool, synthesis: Bool) async throws {}
    nonisolated let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    nonisolated let cancelled = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private var release: CheckedContinuation<Void, Never>?
    func download(_ id: String, endpoint: String, allowsCellular: Bool) async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation {
                release = $0
                started.continuation.yield(())
            }
        } onCancel: {
            self.cancelled.continuation.yield(())
        }
        try Task.checkCancellation()
    }
    func cancel(_ id: String) async throws { finish() }
    func remove(_ id: String) async throws {}
    func finish() {
        release?.resume()
        release = nil
    }
}
@Test(.actionCatalog) func resourcePageCancellationCancelsWorkAndExplicitControlStillJoins() async throws {
    let fixture = HeldResourceFixture()
    let runtime = try await resourceRuntime(fixture)
    var started = fixture.started.stream.makeAsyncIterator()
    let download = Task {
        try await runtime.perform(.download(id: "model", endpoint: "https://example.invalid", allowsCellular: true))
    }
    await started.next()
    download.cancel()
    try await runtime.perform(.cancel("model"))
    await #expect(throws: CancellationError.self) { try await download.value }
    #expect(await runtime.agent.status().queuedInputs == 0)
    await runtime.shutdown()
}
@Test(.actionCatalog) func resourceShutdownCancelsAndJoinsWorkersBeforeReturning() async throws {
    let fixture = HeldResourceFixture()
    let runtime = try await resourceRuntime(fixture)
    var started = fixture.started.stream.makeAsyncIterator()
    var cancelled = fixture.cancelled.stream.makeAsyncIterator()
    let download = Task {
        try await runtime.perform(.download(id: "model", endpoint: "https://example.invalid", allowsCellular: true))
    }
    await started.next()
    let shutdown = Task { await runtime.shutdown() }
    await cancelled.next()
    await fixture.finish()
    await shutdown.value
    await #expect(throws: (any Error).self) { try await download.value }
    #expect(await runtime.agent.status().lifecycle == .stopped)
    await runtime.shutdown()
}

@Test(.actionCatalog) func pausedApplicationControlRetainsEnvironmentAdmissionWithoutStartingBusiness() async throws {
    let session = UUID().uuidString
    let agent = try ApplicationControlAgent(
        sessionID: session,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "applicationControl"), scope: UUID().uuidString,
            state: ApplicationControlContextState())
    )
    try await agent.start()
    try await agent.pause()
    let fact = AppEnvironmentFact(category: .devices, sequence: 1, value: "camera: available")
    try await agent.receive(fact.input(sessionID: session))
    #expect(try await agent.environmentSnapshot().contains("camera: available"))
    await #expect(throws: HarnessError.notRunning) {
        try await agent.receive(ModelResourceIntent.cancel("model").input(sessionID: session))
    }
    #expect(await agent.status().lifecycle == .paused)
    try await agent.resume()
    try await agent.receive(
        AppEnvironmentFact(category: .devices, sequence: 2, value: "camera: closed").input(sessionID: session))
    #expect(try await agent.environmentSnapshot().contains("camera: closed"))
    await agent.stop()
}

@Test(.actionCatalog) func resourceIntentRejectsForeignSessionAndMalformedResourceBeforeEffects() async throws {
    let session = UUID().uuidString
    let agent = try ApplicationControlAgent(
        sessionID: session,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "applicationControl"), scope: UUID().uuidString,
            state: ApplicationControlContextState())
    )
    try await agent.start()
    await #expect(throws: CommunicationError.unauthorized) {
        try await agent.receive(ModelResourceIntent.cancel("model").input(sessionID: UUID().uuidString))
    }
    await #expect(throws: CommunicationError.invalidPayload) {
        try await agent.receive(ModelResourceIntent.remove("../model").input(sessionID: session))
    }
    #expect(await agent.status().queuedInputs == 0)
    await agent.stop()
}

@Test(.actionCatalog) func speechModelPreferenceTravelsThroughResourceAgentAndReturningFeedback() async throws {
    let fixture = ResourceFixture()
    let runtime = try await resourceRuntime(fixture)
    try await runtime.perform(.configureSpeech(recognition: true, synthesis: false))
    try await runtime.perform(.configureSpeech(recognition: false, synthesis: true))
    #expect(await fixture.calls == ["speech:true:false", "speech:false:true"])
    #expect(await runtime.agent.status().queuedInputs == 0)
    await runtime.shutdown()
}
@Test(.actionCatalog) func speechBindingOverlapIsRejectedWithoutBlockingOtherResourceIntentsAndRetirementReleasesIt()
    async throws
{
    let session = UUID().uuidString
    let agent = try ApplicationControlAgent(
        sessionID: session,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "applicationControl"), scope: UUID().uuidString,
            state: ApplicationControlContextState())
    )
    try await agent.start()
    let request = try ModelResourceIntent.configureSpeech(recognition: true, synthesis: false).input(sessionID: session)
    try await agent.receive(request)
    await #expect(throws: CommunicationError.capacityExceeded) {
        try await agent.receive(
            ModelResourceIntent.configureSpeech(recognition: false, synthesis: true).input(sessionID: session))
    }
    try await agent.receive(ModelResourceIntent.cancel("model").input(sessionID: session))
    try await agent.receive(ModelResourceIntent.retire(request.id).input(sessionID: session))
    try await agent.receive(
        ModelResourceIntent.configureSpeech(recognition: false, synthesis: true).input(sessionID: session))
    #expect(await agent.status().queuedInputs == 2)
    await agent.stop()
}

@Test(.actionCatalog) func speechBindingFailureIsInvocationLocalAndNextPreferenceCanExecute() async throws {
    let fixture = ResourceFixture()
    let runtime = try await resourceRuntime(fixture)
    await fixture.failNextSpeech()
    await #expect(throws: ApplicationControlIntentFailure.self) {
        try await runtime.perform(.configureSpeech(recognition: true, synthesis: true))
    }
    try await runtime.perform(.configureSpeech(recognition: false, synthesis: true))
    #expect(await fixture.calls == ["speech:false:true"])
    #expect(await runtime.agent.status().queuedInputs == 0)
    await runtime.shutdown()
}
@Test(.actionCatalog) func speechFunctionRejectsInvalidBooleansBeforeCallingNativeCapability() async throws {
    let fixture = ResourceFixture()
    let invocation = ActionInvocation(
        source: .applicationControl,
        input: AgentInput(
            id: UUID().uuidString, sessionID: UUID().uuidString, payload: .event("fixture")),
        call: ActionCall(
            actionPath: ActionPath(domain: "System", module: "ModelResources", function: "configureSpeech"),
            channel: "fixture", parameters: ["recognition": "TRUE", "synthesis": "false"]))
    await #expect(throws: ActionArguments.ValidationError.self) {
        _ = try await SystemActions.configureSpeech(invocation: invocation, using: fixture)
    }
    #expect(await fixture.calls.isEmpty)
}

struct UnusedProviderDiscovery: ProviderDiscoveryCapability {
    func discoverModels(requestID: String, sessionID: String) async throws -> [String] { throw CancellationError() }
}

struct UnusedProviderSettings: ProviderSettingsCapability {
    func restoreSettings(requestID: String, sessionID: String) async throws { throw CancellationError() }
    func saveSettings(requestID: String, sessionID: String) async throws { throw CancellationError() }
}

struct UnusedCameraControl: CameraControlCapability {
    func setEnabled(_ enabled: Bool, invocation: any FunctionInput) async throws {
        throw CameraControlError.unavailable
    }
    func flip(_ facing: CameraActions.Facing, invocation: any FunctionInput) async throws {
        throw CameraControlError.unavailable
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func environmentPublicationHasNoCompletionWaitAndReceiverErrorsStayIndependent()
    async throws
{
    let session = UUID().uuidString
    let manager = AgentManager()
    let policy = try resourceFixturePolicy()
    let input = InputGateway(manager: manager, policy: policy)
    let errors = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(8))
    let runtime = try await resourceRuntime(
        UnusedModelResourceCapability(), sessionID: session,
        manager: manager, suppliedInput: input,
        outputSink: { errors.continuation.yield($0) })
    try await runtime.prepareForInteraction()
    let start = ContinuousClock.now
    try await runtime.prepareForInteraction()
    try await runtime.agent.observeEnvironment(.init(category: .devices, sequence: 1, value: "camera open"))
    #expect(start.duration(to: .now) < .seconds(2))
    await input.flushPublications()
    #expect(try await runtime.agent.environmentSnapshot().contains("camera open"))
    // Duplicate sequence is receiver-owned rejection; publication still completes successfully.
    await #expect(throws: CommunicationError.invalidPayload) {
        try await runtime.prepareForInteraction()
        try await runtime.agent.observeEnvironment(.init(category: .devices, sequence: 1, value: "camera closed"))
    }
    await input.flushPublications()
    var iterator = errors.stream.makeAsyncIterator()
    let error = try #require(await iterator.next())
    #expect(error.source == .applicationControl)
    if case .control(let message) = error.output {
        #expect(message.contains("agent.inputRejected:") || message.contains("invalidPayload"))
    } else {
        Issue.record("Expected receiver-owned error, no environment completion acknowledgment")
    }
    await input.shutdown()
    await runtime.shutdown()
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func resourcesContainerIsConsumedByItsAgentAndResubscribesAfterPause() async throws {
    let ui = UIContainer()
    try ui.start()
    let native = ResourceFixture()
    let host = try await resourceRuntime(native, uiResources: ui.modelResources)
    await #expect(throws: UIRequestError.unavailable) {
        _ = try await ui.modelResources.requests.submit(.cancel("before-start"))
    }
    try await host.prepareForInteraction()
    _ = try await ui.modelResources.requests.submit(
        .download("model", .init(endpoint: "https://example.invalid/model", allowsCellular: false)))
    #expect(await native.calls == ["download:model:false"])
    try await host.agent.pause()
    await #expect(throws: UIRequestError.unavailable) {
        _ = try await ui.modelResources.requests.submit(.remove("paused"))
    }
    try await host.agent.resume()
    _ = try await ui.modelResources.requests.submitControl(.cancel("model"))
    #expect(await native.calls == ["download:model:false", "cancel:model"])
    await host.shutdown()
    await #expect(throws: UIRequestError.unavailable) {
        _ = try await ui.modelResources.requests.submit(.remove("stopped"))
    }
    await ui.stop()
}

private actor HeldUIResource: ModelResourceCapability {
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private var pending: CheckedContinuation<Void, any Error>?
    private(set) var cancelled = false
    private(set) var joined = false
    func configureSpeech(recognition: Bool, synthesis: Bool) {}
    func download(_ id: String, endpoint: String, allowsCellular: Bool) async throws {
        defer { joined = true }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                entered.continuation.yield(())
            }
        } onCancel: {
            Task { await self.finish(cancelled: true) }
        }
    }
    func cancel(_ id: String) { finish(cancelled: false) }
    func remove(_ id: String) {}
    private func finish(cancelled: Bool) {
        self.cancelled = cancelled
        if cancelled { pending?.resume(throwing: CancellationError()) } else { pending?.resume() }
        pending = nil
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func agentUIControlBypassesAnOutstandingOrdinaryRequest() async throws {
    let ui = UIContainer()
    try ui.start()
    let native = HeldUIResource()
    let host = try await resourceRuntime(native, uiResources: ui.modelResources)
    try await host.prepareForInteraction()
    var entered = native.entered.stream.makeAsyncIterator()
    let downloading = Task { try await ui.modelResources.requests.submit(.download("model", .init())) }
    await entered.next()
    #expect(ui.modelResources.requests.acceptedCount == 1)
    _ = try await ui.modelResources.requests.submitControl(.cancel("model"))
    _ = try await downloading.value
    #expect(await native.joined)
    #expect(await !native.cancelled)
    await host.shutdown()
    await ui.stop()
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func agentStopClosesUIWaitersAndJoinsItsAcceptedAction() async throws {
    let ui = UIContainer()
    try ui.start()
    let native = HeldUIResource()
    let host = try await resourceRuntime(native, uiResources: ui.modelResources)
    try await host.prepareForInteraction()
    var entered = native.entered.stream.makeAsyncIterator()
    let downloading = Task { try await ui.modelResources.requests.submit(.download("model", .init())) }
    await entered.next()
    await host.shutdown()
    await #expect(throws: (any Error).self) { _ = try await downloading.value }
    #expect(await native.cancelled)
    #expect(await native.joined)
    #expect(ui.modelResources.requests.outstanding == 0)
    await ui.stop()
}

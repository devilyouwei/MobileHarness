import Actions
import AgentCore
import Agents
import AppWorkflows
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import Storage
import Testing

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
        externalSources: [
            "phone.microphone", "phone.camera",
            "user", "runtime", ModelResourceObservation.source, ModelResourceHostFailure.source,
            AppEnvironmentFact.source,
        ],
        configurations: AgentConfigurations.all())
}
func resourceRuntime(
    _ resources: any ModelResourceCapability,
    preferences: any ModelResourcePreferencesCapability = UnusedModelResourcePreferencesCapability(),
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
    sessionID: String = UUID().uuidString, manager: AgentManager = AgentManager(),
    suppliedInput: InputGateway? = nil,
    suppliedContext: AgentContextRepository<ApplicationControlContextState>? = nil,
    outputSink: @escaping @Sendable (OutputEnvelope) async -> Void = { _ in }
) throws -> ApplicationControlIntentRuntime {
    let session = sessionID
    let policy = try resourceFixturePolicy()
    let input = suppliedInput ?? InputGateway(manager: manager, policy: policy, allowsExternalSend: true)
    let functions =
        ModelResourcesModule(resources: resources, preferences: preferences, inventory: inventory).definitions
        + ResourcePresentationModule(inventory: inventory, presentation: presentation).definitions
        + ProviderModule(discovery: providerDiscovery, settings: providerSettings).definitions
        + DeviceModule(device: device).definitions + NavigationModule(presentation: presentation).definitions
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
    return ApplicationControlIntentRuntime(
        sessionID: session, manager: manager, input: input, output: output,
        agent: try ApplicationControlAgent(sessionID: session, context: suppliedContext))
}
@Test(.actionCatalog) func modelResourceCommandsCrossGatewaysAndRecoverAfterNativeFailure() async throws {
    let fixture = ResourceFixture()
    let runtime = try resourceRuntime(fixture)
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
    let agent = try ApplicationControlAgent(sessionID: session)
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
@Test(.actionCatalog) func resourcePageCancellationPreservesAdmissionAndExplicitCancelIsIndependent() async throws {
    let fixture = HeldResourceFixture()
    let runtime = try resourceRuntime(fixture)
    var started = fixture.started.stream.makeAsyncIterator()
    let download = Task {
        try await runtime.perform(.download(id: "model", endpoint: "https://example.invalid", allowsCellular: true))
    }
    await started.next()
    download.cancel()
    try await runtime.perform(.cancel("model"))
    try await download.value
    #expect(await runtime.agent.status().queuedInputs == 0)
    await runtime.shutdown()
}
@Test(.actionCatalog) func resourceShutdownCancelsAndJoinsWorkersBeforeReturning() async throws {
    let fixture = HeldResourceFixture()
    let runtime = try resourceRuntime(fixture)
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
    let agent = try ApplicationControlAgent(sessionID: session)
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
    let agent = try ApplicationControlAgent(sessionID: session)
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
    let runtime = try resourceRuntime(fixture)
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
    let agent = try ApplicationControlAgent(sessionID: session)
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
    let runtime = try resourceRuntime(fixture)
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
    let runtime = try resourceRuntime(
        UnusedModelResourceCapability(), sessionID: session,
        manager: manager, suppliedInput: input,
        outputSink: { errors.continuation.yield($0) })
    try await runtime.prepareForInteraction()
    let start = ContinuousClock.now
    try await runtime.observeEnvironment(.init(category: .devices, sequence: 1, value: "camera open"))
    #expect(start.duration(to: .now) < .seconds(2))
    await input.flushPublications()
    #expect(try await runtime.agent.environmentSnapshot().contains("camera open"))
    // Duplicate sequence is receiver-owned rejection; publication still completes successfully.
    try await runtime.observeEnvironment(.init(category: .devices, sequence: 1, value: "camera closed"))
    await input.flushPublications()
    var iterator = errors.stream.makeAsyncIterator()
    let error = try #require(await iterator.next())
    #expect(error.source == .applicationControl)
    if case .control(let message) = error.output {
        #expect(message.contains("agent.error:") && message.contains("outOfOrder"))
    } else {
        Issue.record("Expected receiver-owned error, no environment completion acknowledgment")
    }
    await input.shutdown()
    await runtime.shutdown()
}

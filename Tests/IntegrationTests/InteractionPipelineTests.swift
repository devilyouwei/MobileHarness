import Actions
import AgentCore
import Agents
import CallRuntime
import Foundation
import FunctionContracts
import Gateway
import PlatformKit
import StorageCore
import StorageState
import Testing

private actor InteractionDevice: DeviceControlCapability {
    var calls: [DeviceControlRequest.Operation] = []
    var requests: [DeviceControlRequest] = []
    func control(_ request: DeviceControlRequest, invocation: any FunctionInput) throws {
        calls.append(request.operation)
        requests.append(request)
        if request.operation == .refresh { throw DeviceControlError.unavailable }
    }
    func readStatus() -> String { "{}" }
}

@Test(.actionCatalog) func xmlDisconnectIgnoresExtraParametersWithoutForwardingThemToDevice() async throws {
    let device = InteractionDevice()
    let capabilities = try AgentSkillLoader.registry(
        ["application-control"], fixed: AgentConfigurations.load(named: "Assistant").capabilities)
    var parser = AgentGenerator(capabilities: capabilities)
    let events =
        try parser.append(
            "<Bluetooth.control operation='disconnect' id='device_17' value='invalid' action='wave' extra='ignored'/>")
        + parser.finish()
    let call = try #require(events.first?.actionCall)
    let invocation = ActionInvocation(
        source: .assistant,
        input: AgentInput(id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("断开机械臂")),
        call: call)
    let result = try await SystemActions.control(invocation: invocation, using: device)
    #expect(result.contains("accepted"))
    let requests = await device.requests
    let request = try #require(requests.first)
    #expect(requests.count == 1 && request.operation == .disconnect)
    #expect(request.id == nil && request.value == nil && request.action == nil)
}

@Test(.actionCatalog) func deviceArgumentsIgnoreInapplicableFieldsButValidateApplicableValues() async throws {
    let device = InteractionDevice()
    func invoke(_ parameters: [String: String]) async throws {
        let invocation = ActionInvocation(
            source: .assistant,
            input: AgentInput(id: UUID().uuidString, sessionID: UUID().uuidString, payload: .event("fixture")),
            call: ActionCall(
                actionPath: .init(domain: "System", module: "Device", function: "control"), channel: "System",
                parameters: parameters))
        _ = try await SystemActions.control(invocation: invocation, using: device)
    }
    try await invoke(["operation": "disconnect", "id": "", "value": "invalid", "action": "invalid"])
    try await invoke(["operation": "motorVelocity", "id": "1", "value": "0.5", "action": "irrelevant"])
    for parameters in [
        ["operation": "connect", "value": "ignored"],
        ["operation": "reconnect", "id": "invalid"],
        ["operation": "motorVelocity", "id": "7", "value": "0.5"],
        ["operation": "motorVelocity", "id": "1", "value": "invalid"],
        ["operation": "motorVelocity", "id": "1", "value": "nan"],
        ["operation": "motorVelocity", "id": "1", "value": "1.1"],
        ["operation": "preset", "action": "invalid"],
        ["operation": "disconnect", "fence": "invalid"],
        ["operation": "invalid"],
    ] {
        await #expect(throws: DeviceControlError.invalidRequest) { try await invoke(parameters) }
    }
    let requests = await device.requests
    #expect(requests.count == 2)
    #expect(requests.first?.id == nil && requests.first?.value == nil && requests.first?.action == nil)
    #expect(requests.last?.id == "1" && requests.last?.value == 0.5 && requests.last?.action == nil)
}
private actor InteractionPresentation: ResourcePresentationCapability {
    var destinations: [String] = []
    func navigate(_ destination: String, invocation: any FunctionInput) { destinations.append(destination) }
    func presentResources(_ inventory: ModelResourceInventory, generation: UInt64, invocation: any FunctionInput) {}
    func presentResourcePreferenceFailure(
        _ reason: ResourcePreferenceFailureReason, message: String, invocation: any FunctionInput
    ) {}
    func presentResourceOperationFailure(_ message: String, invocation: any FunctionInput) {}
    func presentResourceFailure(_ message: String, generation: UInt64, invocation: any FunctionInput) {}
}
@Test(.actionCatalog) func deviceContainerRequestsUseRegisteredFunctionsAndRecover() async throws {
    let device = InteractionDevice()
    let presentation = InteractionPresentation()
    let runtime = try await resourceRuntime(UnusedModelResourceCapability(), presentation: presentation, device: device)
    try await runtime.controlDevice(["operation": "scan"])
    await #expect(throws: ApplicationControlIntentFailure.self) {
        try await runtime.controlDevice(["operation": "refresh"])
    }
    await #expect(throws: ApplicationControlIntentFailure.self) {
        try await runtime.controlDevice(["operation": "motorVelocity", "id": "7", "value": "1"])
    }
    try await runtime.controlDevice(["operation": "stopScan"])
    #expect(await device.calls == [.scan, .refresh, .stopScan])
    #expect(await presentation.destinations.isEmpty)
    #expect(await runtime.agent.status().queuedInputs == 0)
    await runtime.shutdown()
}
@Test(.actionCatalog) func environmentFactsAreBoundedOrderedAndDoNotInvokeDeviceCommands() async throws {
    let device = InteractionDevice()
    let manager = AgentManager()
    let input = InputGateway(manager: manager, policy: try resourceFixturePolicy())
    let runtime = try await resourceRuntime(
        UnusedModelResourceCapability(), device: device,
        manager: manager, suppliedInput: input)
    try await runtime.prepareForInteraction()
    try await runtime.agent.observeEnvironment(.init(category: .scene, sequence: 1, value: "active"))
    await input.flushPublications()
    // Subscriber rejects stale state independently; the publishing API returns no acknowledgment.
    await #expect(throws: CommunicationError.invalidPayload) {
        try await runtime.prepareForInteraction()
        try await runtime.agent.observeEnvironment(.init(category: .scene, sequence: 1, value: "replay"))
    }
    await input.flushPublications()
    await #expect(throws: CommunicationError.self) {
        try await runtime.prepareForInteraction()
        try await runtime.agent.observeEnvironment(
            .init(category: .devices, sequence: 2, value: String(repeating: "x", count: 16385)))
    }
    try await runtime.prepareForInteraction()
    try await runtime.agent.observeEnvironment(.init(category: .scene, sequence: 3, value: "background"))
    await input.flushPublications()
    let snapshot = try await runtime.agent.environmentSnapshot()
    #expect(snapshot.contains("background"))
    #expect(!snapshot.contains("replay"))
    #expect(await device.calls.isEmpty)
    await input.shutdown()
    await runtime.shutdown()
}

@Test(.actionCatalog) func environmentSnapshotsSupersedeLateDeliveryWithoutReplayingLoading() async throws {
    let session = UUID().uuidString
    let agent = try ApplicationControlAgent(
        sessionID: session,
        context: try AgentContextRepository(
            agent: .applicationControl, scope: UUID().uuidString, state: ApplicationControlContextState()))
    try await agent.start()
    let loading = AppEnvironmentFact(category: .modelPreparation, sequence: 2, value: "loading")
    let idle = AppEnvironmentFact(category: .modelPreparation, sequence: 4, value: "idle")
    try await agent.receive(loading.input(sessionID: session))
    try await agent.receive(idle.input(sessionID: session))
    try await agent.receive(loading.input(sessionID: session))
    try await agent.receive(idle.input(sessionID: session))
    // Versions are per category, so an independent category may have a lower number.
    try await agent.receive(
        AppEnvironmentFact(category: .scene, sequence: 1, value: "active").input(sessionID: session))
    await #expect(throws: CommunicationError.invalidPayload) {
        try await agent.receive(
            AppEnvironmentFact(category: .modelPreparation, sequence: 4, value: "loading").input(sessionID: session))
    }
    // Supersession never bypasses payload or session validation.
    await #expect(throws: CommunicationError.invalidPayload) {
        try await agent.receive(
            AppEnvironmentFact(category: .modelPreparation, sequence: 1, value: "invalid").input(sessionID: session))
    }
    await #expect(throws: CommunicationError.unauthorized) {
        try await agent.receive(loading.input(sessionID: UUID().uuidString))
    }
    let snapshot = try await agent.environmentSnapshot()
    #expect(snapshot.contains("idle") && snapshot.contains("active"))
    #expect(!snapshot.contains("loading"))
    await agent.stop()
    var emitted = 0
    for await envelope in agent.outputs {
        if case .toolCall = envelope.output { emitted += 1 }
    }
    #expect(emitted == 2)
}

@Test(.actionCatalog) func independentManualTerminalResultIsRetainedWithoutSchedulingAnotherAction() async throws {
    let session = UUID().uuidString
    let agent = try ApplicationControlAgent(
        sessionID: session,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "applicationControl"), scope: UUID().uuidString,
            state: ApplicationControlContextState())
    )
    try await agent.start()
    let owner = ExecutionOwner(
        agent: agent.descriptor.id, incarnation: UUID().uuidString, sessionID: session)
    let root = UUID().uuidString
    let report = ActionReport.empty.recordingFailure(DeviceControlError.unavailable)
    let result = ActionResult(
        executionID: UUID().uuidString, owner: owner,
        path: .init(domain: "System", module: "Device", function: "control"),
        causality: .root(id: root), status: .failed, effect: .unknown,
        completion: .report(report.agentValue), failure: .handlerFailed)
    let payload = InputPayload.actionResult(result)
    let feedback = AgentInput(
        id: UUID().uuidString,
        sessionID: session, payload: payload,
        metadata: InputMetadata(
            payload: payload, source: "runtime", origin: .runtime,
            rootID: root, parentID: root))
    try await agent.receive(feedback)
    try await agent.receive(feedback)
    #expect(await agent.manualResults().count == 1)
    #expect(await agent.status().queuedInputs == 0)
    #expect(try await agent.environmentSnapshot().contains("device.unavailable"))
    let forged = AgentInput(
        id: UUID().uuidString,
        sessionID: session, payload: payload,
        metadata: InputMetadata(
            payload: payload, source: "user", origin: .local, rootID: UUID().uuidString))
    await #expect(throws: CommunicationError.unauthorized) { try await agent.receive(forged) }
    try await agent.receive(
        AppEnvironmentFact(category: .scene, sequence: 1, value: "active").input(sessionID: session))
    #expect(try await agent.environmentSnapshot().contains("active"))
    await agent.stop()
}

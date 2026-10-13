import Actions
import AgentCore
import Agents
import AppWorkflows
import Foundation
import FunctionContracts
import Gateway
import Testing

private actor InteractionDevice: DeviceControlCapability {
    var calls: [DeviceControlRequest.Operation] = []
    func control(_ request: DeviceControlRequest, invocation: any FunctionInput) throws {
        calls.append(request.operation)
        if request.operation == .refresh { throw DeviceControlError.unavailable }
    }
    func readStatus() -> String { "{}" }
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
@Test(.actionCatalog) func deviceAndNavigationIntentsUseRegisteredFunctionsAndRecover() async throws {
    let device = InteractionDevice()
    let presentation = InteractionPresentation()
    let runtime = try resourceRuntime(UnusedModelResourceCapability(), presentation: presentation, device: device)
    try await runtime.interact(.init(kind: .device, parameters: ["operation": "scan"]))
    await #expect(throws: ApplicationControlIntentFailure.self) {
        try await runtime.interact(.init(kind: .device, parameters: ["operation": "refresh"]))
    }
    await #expect(throws: ApplicationControlIntentFailure.self) {
        try await runtime.interact(
            .init(kind: .device, parameters: ["operation": "motorVelocity", "id": "7", "value": "1"]))
    }
    try await runtime.interact(.init(kind: .navigation, parameters: ["destination": "bluetooth"]))
    try await runtime.interact(.init(kind: .device, parameters: ["operation": "stopScan"]))
    #expect(await device.calls == [.scan, .refresh, .stopScan])
    #expect(await presentation.destinations == ["bluetooth"])
    #expect(await runtime.agent.status().queuedInputs == 0)
    await runtime.shutdown()
}
@Test(.actionCatalog) func environmentFactsAreBoundedOrderedAndDoNotInvokeDeviceCommands() async throws {
    let device = InteractionDevice()
    let manager = AgentManager()
    let input = InputGateway(manager: manager, policy: try resourceFixturePolicy())
    let runtime = try resourceRuntime(
        UnusedModelResourceCapability(), device: device,
        manager: manager, suppliedInput: input)
    try await runtime.observeEnvironment(.init(category: .scene, sequence: 1, value: "active"))
    await input.flushPublications()
    // Subscriber rejects stale state independently; the publishing API returns no acknowledgment.
    try await runtime.observeEnvironment(.init(category: .scene, sequence: 1, value: "replay"))
    await input.flushPublications()
    await #expect(throws: CommunicationError.self) {
        try await runtime.observeEnvironment(
            .init(category: .devices, sequence: 2, value: String(repeating: "x", count: 16385)))
    }
    try await runtime.observeEnvironment(.init(category: .scene, sequence: 3, value: "background"))
    await input.flushPublications()
    let snapshot = try await runtime.agent.environmentSnapshot()
    #expect(snapshot.contains("background"))
    #expect(!snapshot.contains("replay"))
    #expect(await device.calls.isEmpty)
    await input.shutdown()
    await runtime.shutdown()
}

@Test(.actionCatalog) func independentManualTerminalResultIsRetainedWithoutSchedulingAnotherAction() async throws {
    let session = UUID()
    let agent = try ApplicationControlAgent(sessionID: session)
    try await agent.start()
    let owner = ExecutionOwner(agent: agent.descriptor.id, incarnation: UUID(), sessionID: session)
    let root = UUID()
    let report = ActionReport.empty.recordingFailure(DeviceControlError.unavailable)
    let result = ActionResult(
        executionID: UUID(), owner: owner,
        path: .init(domain: "System", module: "Device", function: "control"),
        causality: .root(id: root), status: .failed, effect: .unknown,
        completion: .report(report.agentValue), failure: .handlerFailed)
    let payload = InputPayload.actionResult(result)
    let feedback = AgentInput(
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
        sessionID: session, payload: payload,
        metadata: InputMetadata(payload: payload, source: "user", origin: .external))
    await #expect(throws: CommunicationError.unauthorized) { try await agent.receive(forged) }
    try await agent.receive(
        AppEnvironmentFact(category: .scene, sequence: 1, value: "active").input(sessionID: session))
    #expect(try await agent.environmentSnapshot().contains("active"))
    await agent.stop()
}

import Actions
import AgentCore
import Agents
import AppWorkflows
import Foundation
import FunctionContracts
import Testing

private actor ObservationInventory: ModelResourceInventoryCapability {
    var reads = 0
    var progress: Int64 = 10
    func setProgress(_ value: Int64) { progress = value }
    func snapshotResources() -> [ModelResourceFact] {
        reads += 1
        return [.init(id: "nemotron", name: "ASR", bytes: 100, completedBytes: progress, phase: .downloading)]
    }
}
private actor ObservationPresentation: ResourcePresentationCapability {
    var progress: [Double] = []
    var failures: [String] = []
    func presentResources(_ inventory: ModelResourceInventory, generation: UInt64, invocation: any FunctionInput) {
        progress.append(inventory.items[0].progress)
    }
    func presentResourcePreferenceFailure(
        _ reason: ResourcePreferenceFailureReason, message: String, invocation: any FunctionInput
    ) async throws {
        throw CancellationError()
    }
    func presentResourceOperationFailure(_ message: String, invocation: any FunctionInput) async throws {
        throw CancellationError()
    }
    func presentResourceFailure(_ message: String, generation: UInt64, invocation: any FunctionInput) {
        failures.append(message)
    }
}
@Test func nativeResourceObservationsReuseRegisteredActionsAndFailedFactsDoNotQuery() async throws {
    let inventory = ObservationInventory()
    let presentation = ObservationPresentation()
    let runtime = try resourceRuntime(UnusedModelResourceCapability(), inventory: inventory, presentation: presentation)
    try await runtime.observe(.changed(generation: 1), sequence: 1)
    try await runtime.observe(.failed(generation: 2, message: "native sampling failed"), sequence: 2)
    #expect(await inventory.reads == 1)
    #expect(await presentation.failures == ["native sampling failed"])
    await inventory.setProgress(80)
    try await runtime.observe(.changed(generation: 3), sequence: 3)
    #expect(await presentation.progress == [0.1, 0.8])
    #expect(await runtime.agent.status().queuedInputs == 0)
    await runtime.shutdown()
}
@Test func resourceStateRejectsReplayAndWrongProvenanceWithoutBlockingLaterSample() async throws {
    let inventory = ObservationInventory()
    let presentation = ObservationPresentation()
    let runtime = try resourceRuntime(UnusedModelResourceCapability(), inventory: inventory, presentation: presentation)
    try await runtime.observe(.changed(generation: 1), sequence: 1)
    await #expect(throws: ApplicationControlIntentFailure.self) {
        try await runtime.observe(.changed(generation: 2), sequence: 1)
    }
    try await runtime.observe(.changed(generation: 3), sequence: 2)
    #expect(await inventory.reads == 2)
    await runtime.shutdown()
    let session = UUID()
    let agent = try ApplicationControlAgent(sessionID: session)
    try await agent.start()
    let native = ModelResourceObservation.changed(generation: 1).input(sessionID: session, sequence: 1)
    let forged = AgentInput(
        sessionID: session, payload: native.payload,
        metadata: InputMetadata(payload: native.payload, source: "user", sequence: 1))
    await #expect(throws: CommunicationError.self) { try await agent.receive(forged) }
    try await agent.receive(native)
    #expect(await agent.status().queuedInputs == 1)
    await agent.stop()
}
@Test func invalidResourceFailureFactsRejectBeforeEffects() async throws {
    let inventory = ObservationInventory()
    let presentation = ObservationPresentation()
    let runtime = try resourceRuntime(UnusedModelResourceCapability(), inventory: inventory, presentation: presentation)
    await #expect(throws: CommunicationError.self) { try await runtime.observe(.changed(generation: 0), sequence: 1) }
    await #expect(throws: CommunicationError.self) {
        try await runtime.observe(.failed(generation: 1, message: String(repeating: "x", count: 2049)), sequence: 1)
    }
    await #expect(throws: CommunicationError.self) { try await runtime.observe(.changed(generation: 1), sequence: 0) }
    #expect(await inventory.reads == 0)
    #expect(await presentation.failures.isEmpty)
    await runtime.shutdown()
}

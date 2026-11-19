import Actions
import AgentCore
import Foundation
import FunctionContracts
import Gateway
import PlatformKit
import StorageCore
import Synchronization
import Testing
import UI

@testable import Agents

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
private func waitForResourceFacts(_ runtime: ResourceTestRuntime, processed: Int) async throws {
    for _ in 0..<300 {
        let status = await runtime.agent.status()
        if status.processedInputs >= processed, status.queuedInputs == 0 { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Resource fact did not finish independent processing")
}
@Test(.actionCatalog) @MainActor
func roleOwnedArtifactSubscriptionUsesObservationProvenanceAndPresentsEachRevision() async throws {
    let ui = UIContainer()
    try ui.start()
    let changes = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let resumedChanges = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let sources = Mutex([changes.stream, resumedChanges.stream])
    let failures = Mutex<[String]>([])
    let inventory = ObservationInventory()
    let presentation = ObservationPresentation()
    let runtime = try await resourceRuntime(
        UnusedModelResourceCapability(), inventory: inventory, presentation: presentation,
        uiResources: ui.modelResources,
        resourceChanges: {
            try sources.withLock {
                guard !$0.isEmpty else { throw UIRequestError.unavailable }
                return $0.removeFirst()
            }
        },
        observationFailure: { error in failures.withLock { $0.append(String(describing: error)) } })
    try await runtime.prepareForInteraction()
    await runtime.agent.setResourceObservationForeground(true)
    changes.continuation.yield(1)
    try await waitForResourceFacts(runtime, processed: 2)
    #expect(await inventory.reads == 1)
    #expect(await presentation.progress == [0.1])
    #expect(failures.withLock { $0.isEmpty })
    await inventory.setProgress(80)
    changes.continuation.yield(2)
    try await waitForResourceFacts(runtime, processed: 4)
    #expect(await inventory.reads == 2)
    #expect(await presentation.progress == [0.1, 0.8])
    #expect(failures.withLock { $0.isEmpty })
    try await runtime.agent.pause()
    try await runtime.agent.resume()
    resumedChanges.continuation.yield(1)
    try await waitForResourceFacts(runtime, processed: 6)
    #expect(await inventory.reads == 3)
    #expect(await presentation.progress == [0.1, 0.8, 0.8])
    #expect(failures.withLock { $0.isEmpty })
    await runtime.shutdown()
    changes.continuation.finish()
    resumedChanges.continuation.finish()
    await ui.stop()
}

@Test(.actionCatalog) func nativeResourceObservationsReuseRegisteredActionsAndFailedFactsDoNotQuery() async throws {
    let inventory = ObservationInventory()
    let presentation = ObservationPresentation()
    let runtime = try await resourceRuntime(
        UnusedModelResourceCapability(), inventory: inventory, presentation: presentation)
    try await runtime.prepareForInteraction()
    try await runtime.agent.observeResource(.changed(generation: 1), sequence: 1)
    try await waitForResourceFacts(runtime, processed: 2)
    try await runtime.prepareForInteraction()
    try await runtime.agent.observeResource(.failed(generation: 2, message: "native sampling failed"), sequence: 2)
    try await waitForResourceFacts(runtime, processed: 4)
    #expect(await inventory.reads == 1)
    #expect(await presentation.failures == ["native sampling failed"])
    await inventory.setProgress(80)
    try await runtime.prepareForInteraction()
    try await runtime.agent.observeResource(.changed(generation: 3), sequence: 3)
    try await waitForResourceFacts(runtime, processed: 6)
    #expect(await presentation.progress == [0.1, 0.8])
    #expect(await runtime.agent.status().queuedInputs == 0)
    await runtime.shutdown()
}
@Test(.actionCatalog) func resourceStateRejectsReplayAndWrongProvenanceWithoutBlockingLaterSample() async throws {
    let inventory = ObservationInventory()
    let presentation = ObservationPresentation()
    let runtime = try await resourceRuntime(
        UnusedModelResourceCapability(), inventory: inventory, presentation: presentation)
    try await runtime.prepareForInteraction()
    try await runtime.agent.observeResource(.changed(generation: 1), sequence: 1)
    try await waitForResourceFacts(runtime, processed: 2)
    await #expect(throws: CommunicationError.invalidPayload) {
        try await runtime.prepareForInteraction()
        try await runtime.agent.observeResource(.changed(generation: 2), sequence: 1)
    }
    try await runtime.prepareForInteraction()
    try await runtime.agent.observeResource(.changed(generation: 3), sequence: 2)
    try await waitForResourceFacts(runtime, processed: 4)
    #expect(await inventory.reads == 2)
    await runtime.shutdown()
    let session = UUID().uuidString
    let agent = try ApplicationControlAgent(
        sessionID: session,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "applicationControl"), scope: UUID().uuidString,
            state: ApplicationControlContextState())
    )
    try await agent.start()
    let native = try ModelResourceObservation.changed(generation: 1).input(sessionID: session, sequence: 1)
    let forged = AgentInput(
        id: UUID().uuidString,
        sessionID: session, payload: native.payload,
        metadata: InputMetadata(
            payload: native.payload, source: "user", sequence: 1, rootID: UUID().uuidString))
    await #expect(throws: CommunicationError.self) { try await agent.receive(forged) }
    try await agent.receive(native)
    #expect(await agent.status().queuedInputs == 1)
    await agent.stop()
}
@Test(.actionCatalog) func invalidResourceFailureFactsRejectBeforeEffects() async throws {
    let inventory = ObservationInventory()
    let presentation = ObservationPresentation()
    let runtime = try await resourceRuntime(
        UnusedModelResourceCapability(), inventory: inventory, presentation: presentation)
    await #expect(throws: CommunicationError.self) {
        try await runtime.prepareForInteraction()
        try await runtime.agent.observeResource(.changed(generation: 0), sequence: 1)
    }
    await #expect(throws: CommunicationError.self) {
        try await runtime.prepareForInteraction()
        try await runtime.agent.observeResource(
            .failed(generation: 1, message: String(repeating: "x", count: 2049)), sequence: 1)
    }
    await #expect(throws: CommunicationError.self) {
        try await runtime.prepareForInteraction()
        try await runtime.agent.observeResource(.changed(generation: 1), sequence: 0)
    }
    #expect(await inventory.reads == 0)
    #expect(await presentation.failures.isEmpty)
    await runtime.shutdown()
}

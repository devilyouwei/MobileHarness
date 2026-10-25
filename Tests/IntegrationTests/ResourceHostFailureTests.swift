import Actions
import AgentCore
import Agents
import Foundation
import FunctionContracts
import Gateway
import PlatformKit
import StorageCore
import Testing
import UI

private actor HostResourceFixture: ModelResourceCapability {
    var calls: [String] = []
    func configureSpeech(recognition: Bool, synthesis: Bool) async throws { calls.append("speech") }
    func download(_ id: String, endpoint: String, allowsCellular: Bool) async throws { calls.append("download") }
    func cancel(_ id: String) async throws { calls.append("cancel") }
    func remove(_ id: String) async throws { calls.append("remove") }
}
private actor HostPresentationFixture: ResourcePresentationCapability {
    var calls: [String] = []
    let failing: Bool
    var pausedAgent: ApplicationControlAgent?
    func pauseAfterCommit(_ agent: ApplicationControlAgent) { pausedAgent = agent }
    init(failing: Bool = false) { self.failing = failing }
    func presentResources(_ inventory: ModelResourceInventory, generation: UInt64, invocation: any FunctionInput)
        async throws
    { throw CancellationError() }
    func presentResourcePreferenceFailure(
        _ reason: ResourcePreferenceFailureReason, message: String, invocation: any FunctionInput
    ) async throws {
        calls.append("preference:\(reason.rawValue)")
        if failing { throw ApplicationControlIntentFailure.execution("diagnostic fixture failed") }
    }
    func presentResourceOperationFailure(_ message: String, invocation: any FunctionInput) async throws {
        calls.append("operation")
        if let pausedAgent { try await pausedAgent.pause() }
        if failing { throw ApplicationControlIntentFailure.execution("diagnostic fixture failed") }
    }
    func presentResourceFailure(_ message: String, generation: UInt64, invocation: any FunctionInput) async throws {
        calls.append("refresh:\(generation)")
        if failing { throw ApplicationControlIntentFailure.execution("diagnostic fixture failed") }
    }
}
@Test(.actionCatalog) func resourceHostDispatchPresentsWithoutReplayingNativeEffect() async throws {
    let native = HostResourceFixture()
    let ui = HostPresentationFixture()
    let runtime = try await resourceRuntime(
        native, presentation: ui, nonReturningPaths: ["System.ModelResources.download"])
    do {
        try await runtime.perform(.download(id: "model", endpoint: "https://example.com", allowsCellular: false))
        Issue.record("Non-returning dispatch must fail")
    } catch ApplicationControlIntentFailure.presented(let message) {
        #expect(message.contains("returning feedback"))
    }
    #expect(await native.calls.isEmpty)
    #expect(await ui.calls == ["operation"])
    try await runtime.perform(.cancel("model"))
    #expect(await native.calls == ["cancel"])
    #expect(await runtime.agent.status().queuedInputs == 0)
    await runtime.shutdown()
}
@Test(.actionCatalog, arguments: [false, true]) func resourceHostDiagnosticFailureDoesNotRecurse(missing: Bool)
    async throws
{
    let native = HostResourceFixture()
    let ui = HostPresentationFixture(failing: true)
    let runtime = try await resourceRuntime(
        native, presentation: ui, includeOperationFailurePresentation: !missing,
        nonReturningPaths: ["System.ModelResources.download"])
    do {
        try await runtime.perform(.download(id: "model", endpoint: "https://example.com", allowsCellular: false))
        Issue.record("Failed diagnostic must retain original failure")
    } catch let error as NativeCleanupFailure {
        #expect(error.errors.count == 2)
        let message = String(describing: error)
        #expect(message.contains("returning feedback"))
        #expect(message.contains(missing ? "Unknown tool" : "diagnostic fixture failed"))
    }
    #expect(await native.calls.isEmpty)
    #expect(await ui.calls.count == (missing ? 0 : 1))
    #expect(await runtime.agent.status().queuedInputs == 0)
    await runtime.shutdown()
}
@Test(.actionCatalog) func resourceHostFailureSchemaAndScopeAreValidated() async throws {
    let session = UUID().uuidString
    let agent = try ApplicationControlAgent(
        sessionID: session,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "applicationControl"), scope: UUID().uuidString,
            state: ApplicationControlContextState())
    )
    try await agent.start()
    let invalid = ModelResourceHostFailure(
        requestID: UUID().uuidString, phase: .admission, scope: .refresh(generation: 0), message: "error")
    #expect(throws: (any Error).self) { try invalid.validate() }
    let oversized = ModelResourceHostFailure(
        requestID: UUID().uuidString, phase: .dispatch, scope: .operation,
        message: String(repeating: "界", count: 683))
    #expect(throws: (any Error).self) { try oversized.validate() }
    let fact = ModelResourceHostFailure(
        requestID: UUID().uuidString, phase: .dispatch, scope: .refresh(generation: 7),
        message: "transport failed")
    let input = try fact.input(sessionID: session)
    #expect(input.metadata.rootID == input.id)
    #expect(input.metadata.parentID == fact.requestID)
    let spoofed = AgentInput(
        id: input.id, sessionID: session, payload: input.payload,
        metadata: InputMetadata(
            payload: input.payload, source: "user", rootID: input.id, parentID: fact.requestID, hops: 1))
    await #expect(throws: (any Error).self) { try await agent.receive(spoofed) }
    try await agent.receive(input)
    var iterator = agent.outputs.makeAsyncIterator()
    let envelope = await iterator.next()
    guard case .toolCall(let call) = envelope?.output else {
        Issue.record("Missing diagnostic call")
        return
    }
    #expect(call.toolPath == "UI.ResourcePresentation.showResourceFailure")
    #expect(call.arguments["generation"] == "7")
    await agent.stop()
}

private actor HostPreferencesFixture: ModelResourcePreferencesCapability {
    var malformed = true
    func restoreSource() async throws -> ModelResourcePreferences {
        ModelResourcePreferences(endpoint: malformed ? "" : "https://example.com")
    }
    func saveSource(_ preferences: ModelResourcePreferences) async throws -> ModelResourcePreferences { preferences }
    func repair() { malformed = false }
}
@Test(.actionCatalog) func resourceHostMalformedFeedbackReleasesGateBeforeDiagnostic() async throws {
    let native = HostResourceFixture()
    let ui = HostPresentationFixture()
    let preferences = HostPreferencesFixture()
    let runtime = try await resourceRuntime(native, preferences: preferences, presentation: ui)
    do {
        _ = try await runtime.preferences(.restoreSource)
        Issue.record("Malformed preference feedback must fail")
    } catch ApplicationControlIntentFailure.presented(let message) {
        #expect(!message.isEmpty)
    }
    #expect(await native.calls.isEmpty)
    #expect(await ui.calls == ["preference:execution"])
    await preferences.repair()
    _ = try await runtime.preferences(.restoreSource)
    #expect(await native.calls == ["speech"])
    #expect(await runtime.agent.status().queuedInputs == 0)
    await runtime.shutdown()
}

private actor HeldHostBinding: ModelResourceCapability {
    nonisolated let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var waiter: CheckedContinuation<Void, Never>?
    var count = 0
    func configureSpeech(recognition: Bool, synthesis: Bool) async throws {
        count += 1
        entered.continuation.yield(())
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        waiter?.resume()
        waiter = nil
    }
    func download(_ id: String, endpoint: String, allowsCellular: Bool) async throws { throw CancellationError() }
    func cancel(_ id: String) async throws { throw CancellationError() }
    func remove(_ id: String) async throws { throw CancellationError() }
}
@Test(.actionCatalog) func resourceUIQueuesBindingWithoutReleasingActiveOwner() async throws {
    let native = HeldHostBinding()
    let ui = HostPresentationFixture()
    let runtime = try await resourceRuntime(native, presentation: ui)
    var entries = native.entered.stream.makeAsyncIterator()
    let original = Task { try await runtime.perform(.configureSpeech(recognition: true, synthesis: false)) }
    _ = await entries.next()
    let next = Task { try await runtime.perform(.configureSpeech(recognition: false, synthesis: true)) }
    #expect(await native.count == 1)
    #expect(await ui.calls.isEmpty)
    await native.release()
    try await original.value
    _ = await entries.next()
    #expect(await native.count == 2)
    await native.release()
    try await next.value
    #expect(await runtime.agent.status().queuedInputs == 0)
    await runtime.shutdown()
}

@Test(.actionCatalog) func resourceUIPauseClosesAdmissionAfterCommittedDiagnostic() async throws {
    let native = HostResourceFixture()
    let ui = HostPresentationFixture()
    let runtime = try await resourceRuntime(
        native, presentation: ui, nonReturningPaths: ["System.ModelResources.download"])
    await #expect(throws: ApplicationControlIntentFailure.self) {
        try await runtime.perform(.download(id: "model", endpoint: "https://example.com", allowsCellular: false))
    }
    try await runtime.agent.pause()
    await #expect(throws: UIRequestError.unavailable) { try await runtime.perform(.cancel("model")) }
    #expect(await runtime.agent.status().lifecycle == .paused)
    #expect(await runtime.agent.status().queuedInputs == 0)
    #expect(await ui.calls == ["operation"])
    #expect(await native.calls.isEmpty)
    await runtime.shutdown()
}

@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
func uiOwnedResourceDispatchChecksReturningFeedbackBeforeEffectsAndKeepsDiagnostics(failing: Bool) async throws {
    let root = UIContainer()
    try root.start()
    let native = HostResourceFixture()
    let presentation = HostPresentationFixture(failing: failing)
    let host = try await resourceRuntime(
        native, presentation: presentation, nonReturningPaths: ["System.ModelResources.download"],
        uiResources: root.modelResources)
    try await host.prepareForInteraction()
    do {
        _ = try await root.modelResources.requests.submit(.download("model", .init()))
        Issue.record("A missing result contract must fail before native admission")
    } catch ApplicationControlIntentFailure.presented(let message) {
        #expect(!failing && message.contains("returning feedback"))
    } catch let failure as NativeCleanupFailure {
        #expect(failing && failure.errors.count == 2)
        #expect(String(describing: failure.errors[0]).contains("returning feedback"))
    }
    #expect(await native.calls.isEmpty)
    #expect(await presentation.calls == ["operation"])
    _ = try await root.modelResources.requests.submitControl(.cancel("model"))
    #expect(await native.calls == ["cancel"])
    await host.shutdown()
    await root.stop()
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func uiActionCanPauseItsOwnAgentAndResumeAfterJoinedCleanup() async throws {
    let root = UIContainer()
    try root.start()
    let native = HostResourceFixture()
    let presentation = HostPresentationFixture()
    let host = try await resourceRuntime(
        native, presentation: presentation, nonReturningPaths: ["System.ModelResources.download"],
        uiResources: root.modelResources)
    try await host.prepareForInteraction()
    await presentation.pauseAfterCommit(host.agent)
    await #expect(throws: (any Error).self) {
        _ = try await root.modelResources.requests.submit(.download("model", .init()))
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while await host.agent.status().lifecycle != .paused {
        guard ContinuousClock.now < deadline else { throw CommunicationError.expired }
        await Task.yield()
    }
    try await host.agent.resume()
    _ = try await root.modelResources.requests.submitControl(.cancel("model"))
    #expect(await native.calls == ["cancel"])
    #expect(root.modelResources.requests.outstanding == 0)
    await host.shutdown()
    await root.stop()
}

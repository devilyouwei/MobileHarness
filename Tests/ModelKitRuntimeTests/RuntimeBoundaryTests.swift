import Foundation
import ModelKit
@_spi(ModelAssembly) import ModelKitRuntime
import Testing

@Test func managerRejectsInvalidRuntimeLimitsWithoutCoreDefaults() throws {
    for invalid in [0, -1] {
        #expect(throws: CapabilityError.self) { try ModelManager(maximumConcurrentLoads: invalid) }
        #expect(throws: CapabilityError.self) { try ModelManager(maximumLoadWaiters: invalid) }
    }
}

private actor RuntimeLoadLatch {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    private(set) var entered = false
    func wait() async {
        entered = true
        guard !opened else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

private struct ResourceFixtureChat: ChatCapability {
    let resource: ModelResource<Int>
    var availability: CapabilityAvailability { .available }
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        let pair = InferenceSession<ChatEvent>.make(
            context: request.context, limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        pair.emitter.finish()
        return pair.session
    }
}

@Test(.timeLimit(.minutes(1))) func managerInjectsLoadAndWaiterLimitsAndMapsResourceStates() async throws {
    let manager = try ModelManager(maximumConcurrentLoads: 1, maximumLoadWaiters: 1)
    let latch = RuntimeLoadLatch()
    let first = ModelID("first")
    let second = ModelID("second")
    try await manager.register(
        ModelRegistration(id: first, capabilities: [.chat]) { context in
            ProvidedCapabilities(
                chat: ResourceFixtureChat(
                    resource: try context.resource {
                        await latch.wait()
                        return 1
                    }))
        })
    try await manager.register(
        ModelRegistration(id: second, capabilities: [.chat]) { context in
            ProvidedCapabilities(chat: ResourceFixtureChat(resource: try context.resource { 2 }))
        })
    #expect(try await manager.status(first) == ModelState.registered)
    let pending = Task { try await manager.load(first) }
    while !(await latch.entered) { await Task.yield() }
    #expect(try await manager.status(first) == ModelState.loading)
    await #expect(throws: CapabilityError.inputBusy) { try await manager.load(first) }
    await #expect(throws: CapabilityError.inputBusy) { try await manager.load(second) }
    #expect(try await manager.status(second) == ModelState.unloaded)
    await latch.release()
    try await pending.value
    try await manager.load(second)
    #expect(try await manager.status(first) == ModelState.ready)
    #expect(try await manager.status(second) == ModelState.ready)
    try await manager.unload(first)
    #expect(try await manager.status(first) == ModelState.unloaded)
    await manager.shutdown()
    #expect(try await manager.status(first) == ModelState.closed)
}

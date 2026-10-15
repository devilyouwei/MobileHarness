import Foundation
@_spi(ModelManagement) import ModelKit
import Testing

@Test func inferenceScopeIsOpaqueAndPreservedWithoutConversationPolicy() async throws {
    let request = UUID().uuidString
    let scope = UUID().uuidString
    let context = InferenceContext(requestID: request, scopeID: scope)
    let pair = InferenceSession<Int>.make(
        context: context, limits: try StreamLimits(capacity: 1), estimatedBytes: { _ in 8 })
    try pair.emitter.yield(7)
    pair.emitter.finish()
    #expect(pair.session.context.requestID == request)
    #expect(pair.session.context.scopeID == scope)
    #expect(pair.session.context == context)
    var values = pair.session.events.makeAsyncIterator()
    #expect(try await values.next() == 7)
    #expect(try await values.next() == nil)
}

@Test func coreRejectsInvalidInjectedLoadLimits() throws {
    for invalid in [0, -1] {
        #expect(throws: CapabilityError.self) { try ModelLoadGate(maximumConcurrentLoads: invalid) }
        let gate = try ModelLoadGate(maximumConcurrentLoads: 1)
        #expect(throws: CapabilityError.self) { try ModelContext(loadGate: gate, maximumLoadWaiters: invalid) }
    }
}

private actor CoreLoadLatch {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
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

@Test(.timeLimit(.minutes(1))) func injectedCoreLoaderGateRejectsExcessAndAllowsExplicitRetry() async throws {
    let gate = try ModelLoadGate(maximumConcurrentLoads: 1)
    let first = try ModelContext(loadGate: gate, maximumLoadWaiters: 1)
    let second = try ModelContext(loadGate: gate, maximumLoadWaiters: 1)
    let latch = CoreLoadLatch()
    let _: ModelResource<Int> = try first.resource {
        await latch.wait()
        return 1
    }
    let _: ModelResource<Int> = try second.resource { 2 }
    let pending = Task { try await first.load() }
    while !(await latch.entered) { await Task.yield() }
    #expect(await first.status == ModelResourceState.loading)
    await #expect(throws: CapabilityError.inputBusy) { try await second.load() }
    #expect(await second.status == ModelResourceState.unloaded)
    await latch.release()
    try await pending.value
    try await second.load()
    #expect(await first.status == ModelResourceState.ready)
    #expect(await second.status == ModelResourceState.ready)
    await first.shutdown()
    await second.shutdown()
}

@Test(.timeLimit(.minutes(1))) func injectedCoreWaiterLimitDoesNotCancelAdmittedLoading() async throws {
    let gate = try ModelLoadGate(maximumConcurrentLoads: 2)
    let context = try ModelContext(loadGate: gate, maximumLoadWaiters: 1)
    let latch = CoreLoadLatch()
    let _: ModelResource<Int> = try context.resource {
        await latch.wait()
        return 1
    }
    let pending = Task { try await context.load() }
    while !(await latch.entered) { await Task.yield() }
    await #expect(throws: CapabilityError.inputBusy) { try await context.load() }
    #expect(await context.status == ModelResourceState.loading)
    await latch.release()
    try await pending.value
    try await context.load()
    #expect(await context.status == ModelResourceState.ready)
    await context.shutdown()
}

import Foundation
@_spi(ModelManagement) import ModelKit
@_spi(ModelAssembly) import ModelKitRuntime
import Testing

private actor LoadCounter {
    var loads = 0
    var factories = 0
    func constructed() { factories += 1 }
    func load() -> Int {
        loads += 1
        return loads
    }
}

private actor ManagedChat: ChatCapability {
    let availability: CapabilityAvailability = .available
    let resource: ModelResource<Int>
    init(_ resource: ModelResource<Int>) { self.resource = resource }
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        let lease = try await resource.acquire()
        let resource = resource
        let pair = InferenceSession<ChatEvent>.make(
            limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes },
            onTermination: { _ in Task { await resource.release(lease.id) } })
        await resource.setCancellation(lease.id) { [weak session = pair.session] in session?.cancel() }
        if request.messages.last?.content != "hold" {
            try pair.emitter.yield(.text("load \(lease.model)"))
            try pair.emitter.yield(.finished(.stop))
            pair.emitter.finish()
        }
        return pair.session
    }
}

private func registeredManager(_ counter: LoadCounter) async throws -> ModelManager {
    let manager = try ModelManager()
    try await manager.register(
        ModelRegistration(id: ModelID("model"), capabilities: [.chat]) { context in
            await counter.constructed()
            return ProvidedCapabilities(chat: ManagedChat(try context.resource { await counter.load() }))
        })
    return manager
}

@Test(.timeLimit(.minutes(1))) func getSharesInstanceAndLoadAndOldHandleSurvivesUnload() async throws {
    let counter = LoadCounter()
    let manager = try await registeredManager(counter)
    let id = ModelID("model")
    let deferred = try await manager.get(id, as: .chat, load: false)
    #expect(await counter.loads == 0)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<16 {
            group.addTask {
                let handle = try await manager.get(id, as: .chat)
                #expect((handle as? ManagedChat) === (deferred as? ManagedChat))
            }
        }
        try await group.waitForAll()
    }
    #expect(await counter.factories == 1)
    #expect(await counter.loads == 1)
    try await manager.unload(id)
    #expect(try await manager.status(id) == .unloaded)
    let session = try await deferred.chat(ChatRequest(messages: [.init(role: .user, content: "again")]))
    var text = ""
    for try await event in session.events { if case .text(let delta) = event { text += delta } }
    #expect(text == "load 2")
    #expect(await counter.factories == 1)
    await manager.shutdown()
    #expect(try await manager.status(id) == .closed)
    await #expect(throws: CapabilityError.sessionClosed) {
        _ = try await deferred.chat(ChatRequest(messages: [.init(role: .user, content: "after shutdown")]))
    }
}

@Test(.timeLimit(.minutes(1))) func unloadWaitsForSessionAndRejectsNewWork() async throws {
    let manager = try await registeredManager(LoadCounter())
    let id = ModelID("model")
    let chat = try await manager.get(id, as: .chat)
    let active = try await chat.chat(ChatRequest(messages: [.init(role: .user, content: "hold")]))
    let unload = Task { try await manager.unload(id) }
    while try await manager.status(id) != .unloading { await Task.yield() }
    await #expect(throws: (any Error).self) { _ = try await manager.get(id, as: .chat) }
    // The resource transition may start after the manager marks its entry unloading.
    let resource = try #require(chat as? ManagedChat).resource
    var refused = false
    for _ in 0..<1000 {
        do { _ = try await resource.acquire() } catch {
            refused = true
            break
        }
        await Task.yield()
    }
    #expect(refused)
    #expect(try await manager.status(id) == .unloading)
    active.cancel()
    try await unload.value
    #expect(try await manager.status(id) == .unloaded)
}

@Test(.timeLimit(.minutes(1))) func shutdownCancelsAnActiveStreamAndJoinsRelease() async throws {
    let manager = try await registeredManager(LoadCounter())
    let chat = try await manager.get(ModelID("model"), as: .chat)
    let active = try await chat.chat(ChatRequest(messages: [.init(role: .user, content: "hold")]))
    await manager.shutdown()
    await #expect(throws: CancellationError.self) { for try await _ in active.events {} }
    await manager.shutdown()
    await #expect(throws: CapabilityError.sessionClosed) { _ = try await manager.get(ModelID("model"), as: .chat) }
}

@Test(.timeLimit(.minutes(1))) func failedLoadRetriesWithoutReconstructingProvider() async throws {
    let counter = LoadCounter()
    let manager = try ModelManager()
    let id = ModelID("retry-load")
    try await manager.register(
        ModelRegistration(id: id, capabilities: [.chat]) { context in
            await counter.constructed()
            let resource = try context.resource {
                let count = await counter.load()
                if count == 1 { throw CapabilityError.unavailable("load failed") }
                return count
            }
            return ProvidedCapabilities(chat: ManagedChat(resource))
        })
    await #expect(throws: CapabilityError.unavailable("load failed")) { _ = try await manager.get(id, as: .chat) }
    _ = try await manager.get(id, as: .chat)
    #expect(await counter.factories == 1)
    #expect(await counter.loads == 2)
    await manager.shutdown()
}

@Test func registrationCapacityIsExplicit() async throws {
    let manager = try ModelManager()
    for index in 0..<32 {
        try await manager.register(
            ModelRegistration(id: ModelID("model-\(index)"), capabilities: [.chat]) { context in
                ProvidedCapabilities(chat: ManagedChat(try context.resource { 1 }))
            })
    }
    await #expect(throws: CapabilityError.inputBusy) {
        try await manager.register(
            ModelRegistration(id: ModelID("overflow"), capabilities: [.chat]) { _ in
                ProvidedCapabilities()
            })
    }
    await manager.shutdown()
}

private actor LoadLatch {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var entered = 0
    func wait() async {
        entered += 1
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

@Test(.timeLimit(.minutes(1))) func cancelledGetDoesNotCancelSharedWeightLoad() async throws {
    let manager = try ModelManager()
    let latch = LoadLatch()
    let counter = LoadCounter()
    let id = ModelID("shared-load")
    try await manager.register(
        ModelRegistration(id: id, capabilities: [.chat]) { context in
            ProvidedCapabilities(
                chat: ManagedChat(
                    try context.resource {
                        let value = await counter.load()
                        await latch.wait()
                        return value
                    }))
        })
    let first = Task { try await manager.get(id, as: .chat) }
    while await latch.entered == 0 { await Task.yield() }
    first.cancel()
    let second = Task { try await manager.get(id, as: .chat) }
    await latch.release()
    await #expect(throws: CancellationError.self) { _ = try await first.value }
    _ = try await second.value
    #expect(await counter.loads == 1)
    await manager.shutdown()
}

@Test(.timeLimit(.minutes(1))) func managerBoundsConcurrentWeightLoadsAcrossModels() async throws {
    let manager = try ModelManager()
    let latch = LoadLatch()
    for index in 0..<5 {
        let id = ModelID("load-\(index)")
        try await manager.register(
            ModelRegistration(id: id, capabilities: [.chat]) { context in
                ProvidedCapabilities(
                    chat: ManagedChat(
                        try context.resource {
                            await latch.wait()
                            return index
                        }))
            })
        _ = try await manager.get(id, as: .chat, load: false)
    }
    let loading = (0..<4).map { index in Task { try await manager.load(ModelID("load-\(index)")) } }
    while await latch.entered < 4 { await Task.yield() }
    await #expect(throws: CapabilityError.inputBusy) { try await manager.load(ModelID("load-4")) }
    #expect(await latch.entered == 4)
    await latch.release()
    for task in loading { try await task.value }
    try await manager.load(ModelID("load-4"))
    #expect(await latch.entered == 5)
    await manager.shutdown()
}

@Test(.timeLimit(.minutes(1))) func shutdownWaitsForActualBackendCleanup() async throws {
    let context = try ModelContext(loadGate: ModelLoadGate(maximumConcurrentLoads: 4), maximumLoadWaiters: 32)
    let resource = try context.resource { 42 }
    let lease = try await resource.acquire()
    let cleanup = LoadLatch()
    let requested = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    await resource.setCancellation(lease.id) {
        requested.continuation.yield(())
        Task {
            await cleanup.wait()
            await resource.release(lease.id)
        }
    }
    let finished = LoadCounter()
    let shutdown = Task {
        await context.shutdown()
        _ = await finished.load()
    }
    var events = requested.stream.makeAsyncIterator()
    _ = await events.next()
    #expect(await finished.loads == 0)
    await cleanup.release()
    await shutdown.value
    #expect(await finished.loads == 1)
    requested.continuation.finish()
}

@Test(.timeLimit(.minutes(1))) func shutdownCancelsLoadingEvenWhileUnloadIsWaiting() async throws {
    let context = try ModelContext(loadGate: ModelLoadGate(maximumConcurrentLoads: 4), maximumLoadWaiters: 32)
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let _: ModelResource<Int> = try context.resource {
        entered.continuation.yield(())
        try await Task.sleep(for: .seconds(120))
        return 1
    }
    let load = Task { try await context.load() }
    var events = entered.stream.makeAsyncIterator()
    _ = await events.next()
    let unload = Task { try await context.unload() }
    while await context.status != .unloading { await Task.yield() }
    await context.shutdown()
    await #expect(throws: CancellationError.self) { try await load.value }
    try await unload.value
    #expect(await context.status == .closed)
    entered.continuation.finish()
}

@Test func memoryPressureReleasesOnlyEligibleIdleResources() async throws {
    let manager = try ModelManager()
    let counter = LoadCounter()
    let eligible = ModelID("eligible")
    let retained = ModelID("retained")
    for (id, policy) in [(eligible, ModelMemoryPolicy.releaseWhenIdle), (retained, .retain)] {
        try await manager.register(
            ModelRegistration(id: id, capabilities: [.chat], memoryPolicy: policy) { context in
                ProvidedCapabilities(chat: ManagedChat(try context.resource { await counter.load() }))
            })
    }
    let chat = try await manager.get(eligible, as: .chat)
    _ = try await manager.get(retained, as: .chat)
    let provider = try #require(chat as? ManagedChat)
    let lease = try await provider.resource.acquire()
    #expect(await manager.handleMemoryPressure().isEmpty)
    #expect(try await manager.status(eligible) == .ready)
    await provider.resource.release(lease.id)
    #expect(await manager.handleMemoryPressure() == [eligible])
    #expect(try await manager.status(eligible) == .unloaded)
    #expect(try await manager.status(retained) == .ready)
    #expect(await manager.handleMemoryPressure().isEmpty)
    let same = try await manager.get(eligible, as: .chat)
    #expect((same as? ManagedChat) === provider)
    #expect(await counter.loads == 3)
    await manager.shutdown()
    #expect(await manager.handleMemoryPressure().isEmpty)
}

private struct UnavailableChat: ChatCapability {
    var availability: CapabilityAvailability { .unavailable(reason: "Unsupported test platform") }
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        throw CapabilityError.unavailable("Unsupported test platform")
    }
}

@Test func availabilityIsSeparateFromResidencyAndNeverLoadsWeights() async throws {
    let manager = try ModelManager()
    let id = ModelID("unsupported")
    try await manager.register(
        ModelRegistration(id: id, capabilities: [.chat]) { _ in
            ProvidedCapabilities(chat: UnavailableChat())
        })
    #expect(try await manager.status(id) == .registered)
    #expect(try await manager.availability(id, for: .chat) == .unavailable(reason: "Unsupported test platform"))
    #expect(try await manager.status(id) == .unmanaged)
    let counter = LoadCounter()
    let managed = try await registeredManager(counter)
    #expect(try await managed.availability(ModelID("model"), for: .chat) == .available)
    #expect(await counter.loads == 0)
    #expect(try await managed.status(ModelID("model")) == .unloaded)
    await manager.shutdown()
    await managed.shutdown()
}

@Test(.timeLimit(.minutes(1))) func memoryPressureSkipsLoadingWithoutWaitingOrCancelling() async throws {
    let manager = try ModelManager()
    let latch = LoadLatch()
    let id = ModelID("loading")
    try await manager.register(
        ModelRegistration(id: id, capabilities: [.chat], memoryPolicy: .releaseWhenIdle) { context in
            ProvidedCapabilities(
                chat: ManagedChat(
                    try context.resource {
                        await latch.wait()
                        return 1
                    }))
        })
    let loading = Task { try await manager.load(id) }
    while await latch.entered == 0 { await Task.yield() }
    #expect(await manager.handleMemoryPressure().isEmpty)
    #expect(try await manager.status(id) == .loading)
    await latch.release()
    try await loading.value
    #expect(try await manager.status(id) == .ready)
    #expect(await manager.handleMemoryPressure() == [id])
    await manager.shutdown()
}

@Test func modelLeaseRejectsOverlapUntilReleasedAndReusesWeights() async throws {
    let counter = LoadCounter()
    let context = try ModelContext(loadGate: ModelLoadGate(maximumConcurrentLoads: 4), maximumLoadWaiters: 32)
    let resource = try context.resource { await counter.load() }
    let first = try await resource.acquire()
    await #expect(throws: CapabilityError.inputBusy) { _ = try await resource.acquire() }
    #expect(await counter.loads == 1)
    await resource.release(first.id)
    let next = try await resource.acquire()
    #expect(next.model == first.model)
    #expect(await counter.loads == 1)
    await resource.release(next.id)
    await context.shutdown()
}

@Test(.timeLimit(.minutes(1))) func staleLeaseCallbacksCannotReleaseOrReplaceCurrentLease() async throws {
    let context = try ModelContext(loadGate: ModelLoadGate(maximumConcurrentLoads: 4), maximumLoadWaiters: 32)
    let resource = try context.resource { 1 }
    let old = try await resource.acquire()
    await resource.release(old.id)
    let current = try await resource.acquire()
    await resource.release(old.id)
    await #expect(throws: CapabilityError.inputBusy) { _ = try await resource.acquire() }
    await resource.setCancellation(current.id) { Task { await resource.release(current.id) } }
    await resource.setCancellation(old.id) { Issue.record("Stale cancellation must not replace the current callback") }
    await context.shutdown()
    #expect(await context.status == .closed)
}

@Test(.timeLimit(.minutes(1))) func modelSuspensionCancelsJoinsAndKeepsLoadedWeights() async throws {
    let admission = InferenceAdmission()
    let manager = try ModelManager(admission: admission)
    let counter = LoadCounter()
    let id = ModelID("suspend")
    try await manager.register(
        ModelRegistration(id: id, capabilities: [.chat]) { context in
            ProvidedCapabilities(chat: ManagedChat(try context.resource { await counter.load() }))
        })
    let handle = try await manager.get(id, as: .chat)
    let session = try await handle.chat(ChatRequest(messages: [.init(role: .user, content: "hold")]))
    admission.close()
    await manager.suspend()
    #expect(await counter.loads == 1)
    #expect(try await manager.status(id) == .ready)
    await #expect(throws: CancellationError.self) {
        for try await _ in session.events {}
    }
    await #expect(throws: InferenceAdmissionError.self) {
        _ = try await handle.chat(ChatRequest(messages: [.init(role: .user, content: "late")]))
    }
    try admission.resume()
    let next = try await handle.chat(ChatRequest(messages: [.init(role: .user, content: "again")]))
    for try await _ in next.events {}
    #expect(await counter.loads == 1)
    admission.close(terminal: true)
    await manager.shutdown()
    #expect(try await manager.status(id) == .closed)
    #expect(throws: InferenceAdmissionError.self) { try admission.resume() }
}

@Test(.timeLimit(.minutes(1))) func modelPauseJoinsUncooperativeLoadingAndRejectsItsLateWaiter() async throws {
    let admission = InferenceAdmission()
    let manager = try ModelManager(admission: admission)
    let latch = LoadLatch()
    let id = ModelID("paused-load")
    try await manager.register(
        ModelRegistration(id: id, capabilities: [.chat]) { context in
            ProvidedCapabilities(
                chat: ManagedChat(
                    try context.resource {
                        await latch.wait()
                        return 1
                    }))
        })
    let loading = Task { try await manager.get(id, as: .chat) }
    while await latch.entered == 0 { await Task.yield() }
    admission.close()
    let pausing = Task { await manager.suspend() }
    // Native loading can ignore cancellation; pause must join it rather than fabricate completion.
    await latch.release()
    await pausing.value
    await #expect(throws: (any Error).self) { _ = try await loading.value }
    try admission.resume()
    _ = try await manager.get(id, as: .chat)
    await manager.shutdown()
}

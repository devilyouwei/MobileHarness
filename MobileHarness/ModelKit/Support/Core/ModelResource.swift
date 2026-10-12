import Foundation
import Synchronization

public enum ModelResourceState: Sendable, Equatable {
    case unmanaged, unloaded, loading, ready, unloading, closed
}

/// A manager shares one gate across its contexts. Capacity exhaustion never queues work.
@_spi(ModelManagement) public actor ModelLoadGate {
    private var active = 0
    private let maximumConcurrentLoads: Int
    public init(maximumConcurrentLoads: Int) throws {
        guard maximumConcurrentLoads > 0 else { throw CapabilityError.invalidRequest("Invalid concurrent load limit") }
        self.maximumConcurrentLoads = maximumConcurrentLoads
    }
    fileprivate func run<Value: Sendable>(_ work: @Sendable () async throws -> Value) async throws -> Value {
        guard active < maximumConcurrentLoads else { throw CapabilityError.inputBusy }
        active += 1
        defer { active -= 1 }
        return try await work()
    }
}

/// Adapter-facing resource access. The composition manager owns its context and lifecycle.
public actor ModelResource<Model: Sendable>: ModelResourceLifecycle {
    private let loader: @Sendable () async throws -> Model
    private var model: Model?
    private var loading: Task<Model, Error>?
    private var loadID: UUID?
    private var waiters = 0
    private let maximumLoadWaiters: Int
    private struct ActiveLease {
        let id: UUID
        var cancel: (@Sendable () -> Void)?
    }
    private var activeLease: ActiveLease?
    private var unloading = false
    private var maintenance = false
    private var closed = false
    private var unloadFinished: CheckedContinuation<Void, Never>?
    private var drained: CheckedContinuation<Void, Never>?

    fileprivate init(maximumLoadWaiters: Int, loader: @escaping @Sendable () async throws -> Model) {
        self.maximumLoadWaiters = maximumLoadWaiters
        self.loader = loader
    }

    public func acquire() async throws -> (id: UUID, model: Model) {
        try Task.checkCancellation()
        guard !closed else { throw CapabilityError.sessionClosed }
        guard !unloading, !maintenance else { throw CapabilityError.unavailable("Model is under maintenance") }
        guard activeLease == nil else { throw CapabilityError.inputBusy }
        let id = UUID()
        activeLease = ActiveLease(id: id)
        do {
            let model = try await ensureLoaded()
            try Task.checkCancellation()
            guard !closed, !unloading, !maintenance else { throw CancellationError() }
            return (id, model)
        } catch {
            release(id)
            throw error
        }
    }

    /// Install after creating the session/worker; handles shutdown-before-install races.
    public func setCancellation(_ id: UUID, _ cancel: @escaping @Sendable () -> Void) {
        guard activeLease?.id == id else { return }
        activeLease?.cancel = cancel
        if closed { cancel() }
    }

    public func release(_ id: UUID) {
        guard activeLease?.id == id else { return }
        activeLease = nil
        drained?.resume()
        drained = nil
    }

    private func ensureLoaded() async throws -> Model {
        guard !closed else { throw CapabilityError.sessionClosed }
        guard !unloading, !maintenance else { throw CapabilityError.unavailable("Model is under maintenance") }
        if let model { return model }
        guard waiters < maximumLoadWaiters else { throw CapabilityError.inputBusy }
        waiters += 1
        defer { waiters -= 1 }
        if loading == nil {
            loadID = UUID()
            loading = Task { try await loader() }
        }
        let id = loadID
        let task = loading!
        do {
            let value = try await task.value
            // Never let an old waiter resurrect a resource after unload or a later retry.
            if loadID == id {
                model = value
                loading = nil
                loadID = nil
            }
            try Task.checkCancellation()
            guard !closed, !unloading, !maintenance, let model else { throw CancellationError() }
            return model
        } catch {
            if loadID == id {
                loading = nil
                loadID = nil
            }
            throw error
        }
    }

    fileprivate func beginMaintenance() throws {
        guard !closed, !unloading, !maintenance else { throw CapabilityError.inputBusy }
        maintenance = true
    }
    fileprivate func endMaintenance() { maintenance = false }

    fileprivate var state: ModelResourceState {
        if closed { return .closed }
        if unloading || maintenance { return .unloading }
        if loading != nil { return .loading }
        return model == nil ? .unloaded : .ready
    }

    fileprivate func load() async throws { _ = try await ensureLoaded() }

    fileprivate func unload() async throws {
        guard !closed else { throw CapabilityError.sessionClosed }
        guard !unloading else { throw CapabilityError.inputBusy }
        unloading = true
        defer {
            unloading = false
            unloadFinished?.resume()
            unloadFinished = nil
        }
        await drain(cancel: false)
    }

    fileprivate func shutdown() async {
        closed = true
        loading?.cancel()
        activeLease?.cancel?()
        // An in-progress unload already owns the sole drain continuation.
        if unloading { await withCheckedContinuation { unloadFinished = $0 } }
        unloading = true
        await drain(cancel: true)
        unloading = false
    }

    fileprivate func unloadIfIdle() -> Bool {
        guard !closed, !unloading, !maintenance, loading == nil, activeLease == nil, model != nil else { return false }
        model = nil
        return true
    }

    private func drain(cancel: Bool) async {
        if cancel { loading?.cancel() }
        if let loading { _ = try? await loading.value }
        self.loading = nil
        loadID = nil
        if activeLease != nil { await withCheckedContinuation { drained = $0 } }
        model = nil
    }
}

private protocol ModelResourceLifecycle: Sendable {
    var state: ModelResourceState { get async }
    func load() async throws
    func unload() async throws
    func shutdown() async
    func unloadIfIdle() async -> Bool
    func beginMaintenance() async throws
    func endMaintenance() async
}

/// An owning runtime creates one resource context with explicitly injected admission limits.
/// System adapters register a lightweight resource to participate in session cleanup.
public final class ModelContext: Sendable {
    private struct State {
        var resource: (any ModelResourceLifecycle)?
        var sealed = false
    }
    private let state = Mutex(State())
    private let loadGate: ModelLoadGate
    private let maximumLoadWaiters: Int
    @_spi(ModelManagement) public init(loadGate: ModelLoadGate, maximumLoadWaiters: Int) throws {
        guard maximumLoadWaiters > 0 else { throw CapabilityError.invalidRequest("Invalid load waiter limit") }
        self.loadGate = loadGate
        self.maximumLoadWaiters = maximumLoadWaiters
    }

    public func resource<Model: Sendable>(
        loader: @escaping @Sendable () async throws -> Model
    ) throws -> ModelResource<Model> {
        try state.withLock {
            guard !$0.sealed, $0.resource == nil else {
                throw CapabilityError.invalidRequest("One resource per context; context is sealed")
            }
            let gate = loadGate
            let resource = ModelResource(maximumLoadWaiters: maximumLoadWaiters) { try await gate.run(loader) }
            $0.resource = resource
            return resource
        }
    }

    @_spi(ModelManagement) public var status: ModelResourceState {
        get async { await state.withLock { $0.resource }?.state ?? .unmanaged }
    }
    @_spi(ModelManagement) public func beginMaintenance() async throws {
        try await state.withLock { $0.resource }?.beginMaintenance()
    }
    @_spi(ModelManagement) public func endMaintenance() async {
        await state.withLock { $0.resource }?.endMaintenance()
    }
    @_spi(ModelManagement) public func seal() { state.withLock { $0.sealed = true } }
    @_spi(ModelManagement) public func load() async throws { try await state.withLock { $0.resource }?.load() }
    @_spi(ModelManagement) public func unload() async throws { try await state.withLock { $0.resource }?.unload() }
    @_spi(ModelManagement) public func unloadIfIdle() async -> Bool {
        await state.withLock { $0.resource }?.unloadIfIdle() ?? false
    }
    @_spi(ModelManagement) public func shutdown() async { await state.withLock { $0.resource }?.shutdown() }
}

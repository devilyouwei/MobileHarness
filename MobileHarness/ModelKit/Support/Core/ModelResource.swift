import Foundation
import Synchronization

public enum ModelResourceState: Sendable, Equatable {
    case unmanaged, unloaded, loading, ready, unloading, closed
}

/// Synchronous root fence; retained resources cannot bypass a suspended or retired owner.
public enum InferenceAdmissionError: Error, Sendable { case inactive, stopped }

public final class InferenceAdmission: Sendable {
    private struct State {
        var open: Bool
        var stopped = false
        var generation: UInt64 = 0
    }
    private let state: Mutex<State>
    public init(open: Bool = true) { state = Mutex(State(open: open)) }
    public func check() throws -> UInt64 {
        try state.withLock {
            guard !$0.stopped else { throw InferenceAdmissionError.stopped }
            guard $0.open else { throw InferenceAdmissionError.inactive }
            return $0.generation
        }
    }
    public func checkAlive() throws {
        try state.withLock { if $0.stopped { throw InferenceAdmissionError.stopped } }
    }
    public func validate(_ generation: UInt64) throws {
        guard try check() == generation else { throw CancellationError() }
    }
    public func close(terminal: Bool = false) {
        state.withLock {
            if $0.open { $0.generation &+= 1 }
            $0.open = false
            $0.stopped = $0.stopped || terminal
        }
    }
    public func resume() throws {
        try state.withLock {
            guard !$0.stopped else { throw InferenceAdmissionError.stopped }
            $0.open = true
        }
    }
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
    private var loadID: String?
    private var waiters = 0
    private let maximumLoadWaiters: Int
    private let admission: InferenceAdmission
    private struct ActiveLease {
        let id: String
        var cancel: (@Sendable () -> Void)?
    }
    private var activeLeases: [String: ActiveLease] = [:]
    private let concurrent: Bool
    private var unloading = false
    private var maintenance = false
    private var closed = false
    private var unloadFinished: CheckedContinuation<Void, Never>?
    private var drained: CheckedContinuation<Void, Never>?

    fileprivate init(
        maximumLoadWaiters: Int, admission: InferenceAdmission, concurrent: Bool,
        loader: @escaping @Sendable () async throws -> Model
    ) {
        self.maximumLoadWaiters = maximumLoadWaiters
        self.concurrent = concurrent
        self.admission = admission
        self.loader = loader
    }

    public func acquire() async throws -> (id: String, model: Model) {
        try Task.checkCancellation()
        let generation = try admission.check()
        guard !closed else { throw CapabilityError.sessionClosed }
        guard !unloading, !maintenance else { throw CapabilityError.unavailable("Model is under maintenance") }
        guard concurrent || activeLeases.isEmpty else { throw CapabilityError.inputBusy }
        let id = UUID().uuidString
        activeLeases[id] = ActiveLease(id: id)
        do {
            let model = try await ensureLoaded()
            try admission.validate(generation)
            try Task.checkCancellation()
            guard !closed, !unloading, !maintenance else { throw CancellationError() }
            return (id, model)
        } catch {
            release(id)
            throw error
        }
    }

    /// Install after creating the session/worker; handles shutdown-before-install races.
    public func setCancellation(_ id: String, _ cancel: @escaping @Sendable () -> Void) {
        guard activeLeases[id] != nil else { return }
        activeLeases[id]?.cancel = cancel
        if closed || (try? admission.check()) == nil { cancel() }
    }

    public func release(_ id: String) {
        guard activeLeases[id] != nil else { return }
        activeLeases[id] = nil
        if activeLeases.isEmpty {
            drained?.resume()
            drained = nil
        }
    }

    private func ensureLoaded(reportLoading: @Sendable (Bool) async -> Void = { _ in }) async throws -> Model {
        let generation = try admission.check()
        guard !closed else { throw CapabilityError.sessionClosed }
        guard !unloading, !maintenance else { throw CapabilityError.unavailable("Model is under maintenance") }
        if let model { return model }
        guard waiters < maximumLoadWaiters else { throw CapabilityError.inputBusy }
        waiters += 1
        defer { waiters -= 1 }
        if loading == nil {
            loadID = UUID().uuidString
            loading = Task { try await loader() }
        }
        let id = loadID
        let task = loading!
        await reportLoading(true)
        do {
            let value = try await task.value
            // Never let an old waiter resurrect a resource after unload or a later retry.
            if loadID == id {
                model = value
                loading = nil
                loadID = nil
            }
            try Task.checkCancellation()
            try admission.validate(generation)
            guard !closed, !unloading, !maintenance, let model else { throw CancellationError() }
            await reportLoading(false)
            return model
        } catch {
            if loadID == id {
                loading = nil
                loadID = nil
            }
            await reportLoading(false)
            throw error
        }
    }

    fileprivate func beginMaintenance() throws {
        guard !closed, !unloading, !maintenance else { throw CapabilityError.inputBusy }
        maintenance = true
    }
    fileprivate func endMaintenance() { maintenance = false }

    fileprivate var inferenceActive: Bool { !activeLeases.isEmpty }
    fileprivate var state: ModelResourceState {
        if closed { return .closed }
        if unloading || maintenance { return .unloading }
        if loading != nil { return .loading }
        return model == nil ? .unloaded : .ready
    }

    fileprivate func load() async throws { _ = try await ensureLoaded() }
    fileprivate func load(reportLoading: @Sendable (Bool) async -> Void) async throws {
        _ = try await ensureLoaded(reportLoading: reportLoading)
    }

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

    fileprivate func suspend() async {
        loading?.cancel()
        for lease in activeLeases.values { lease.cancel?() }
        if unloading {
            await withCheckedContinuation { unloadFinished = $0 }
            return
        }
        if let loading { _ = await loading.result }
        if !activeLeases.isEmpty { await withCheckedContinuation { drained = $0 } }
    }

    fileprivate func shutdown() async {
        closed = true
        loading?.cancel()
        for lease in activeLeases.values { lease.cancel?() }
        // An in-progress unload already owns the sole drain continuation.
        if unloading { await withCheckedContinuation { unloadFinished = $0 } }
        unloading = true
        await drain(cancel: true)
        unloading = false
    }

    fileprivate func unloadIfIdle() -> Bool {
        guard !closed, !unloading, !maintenance, loading == nil, activeLeases.isEmpty, model != nil else {
            return false
        }
        model = nil
        return true
    }

    private func drain(cancel: Bool) async {
        if cancel { loading?.cancel() }
        if let loading { _ = try? await loading.value }
        self.loading = nil
        loadID = nil
        if !activeLeases.isEmpty { await withCheckedContinuation { drained = $0 } }
        model = nil
    }
}

private protocol ModelResourceLifecycle: Sendable {
    var state: ModelResourceState { get async }
    var inferenceActive: Bool { get async }
    func load() async throws
    func load(reportLoading: @Sendable (Bool) async -> Void) async throws
    func unload() async throws
    func shutdown() async
    func suspend() async
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
    private let admission: InferenceAdmission
    @_spi(ModelManagement) public init(
        loadGate: ModelLoadGate, maximumLoadWaiters: Int, admission: InferenceAdmission = .init()
    ) throws {
        guard maximumLoadWaiters > 0 else { throw CapabilityError.invalidRequest("Invalid load waiter limit") }
        self.loadGate = loadGate
        self.admission = admission
        self.maximumLoadWaiters = maximumLoadWaiters
    }

    public func resource<Model: Sendable>(
        concurrent: Bool = false,
        loader: @escaping @Sendable () async throws -> Model
    ) throws -> ModelResource<Model> {
        try state.withLock {
            guard !$0.sealed, $0.resource == nil else {
                throw CapabilityError.invalidRequest("One resource per context; context is sealed")
            }
            let gate = loadGate
            let resource = ModelResource(
                maximumLoadWaiters: maximumLoadWaiters, admission: admission, concurrent: concurrent
            ) {
                try await gate.run(loader)
            }
            $0.resource = resource
            return resource
        }
    }

    @_spi(ModelManagement) public var inferenceActive: Bool {
        get async { await state.withLock { $0.resource }?.inferenceActive ?? false }
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
    @_spi(ModelManagement) public func load(reportLoading: @Sendable (Bool) async -> Void) async throws {
        try await state.withLock { $0.resource }?.load(reportLoading: reportLoading)
    }
    @_spi(ModelManagement) public func unload() async throws { try await state.withLock { $0.resource }?.unload() }
    @_spi(ModelManagement) public func unloadIfIdle() async -> Bool {
        await state.withLock { $0.resource }?.unloadIfIdle() ?? false
    }
    @_spi(ModelManagement) public func suspend() async { await state.withLock { $0.resource }?.suspend() }
    @_spi(ModelManagement) public func shutdown() async { await state.withLock { $0.resource }?.shutdown() }
}

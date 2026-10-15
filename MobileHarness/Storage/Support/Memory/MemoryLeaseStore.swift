import Foundation

/// Bounded, single-checkout handles. Nil TTLs leave lifetime to the owning scope.
public actor MemoryLeaseStore<Value: Sendable> {
    private struct Entry {
        let owner: StorageOwner
        let value: Value
        let cancel: @Sendable () async -> Void
        var leased = false
        var started = false
        var timer: Task<Void, Never>?
        var expiry: ContinuousClock.Instant?
        var timerID: UUID?
    }
    private struct Terminal {
        let owner: StorageOwner
        let error: any Error
        let expires: ContinuousClock.Instant?
        let createdAt: ContinuousClock.Instant
    }
    private var entries: [String: Entry] = [:]
    private var terminal: [String: Terminal] = [:]
    private let capacity: Int
    private let queueTTL: Duration?
    private let readyTTL: Duration?
    private let errorTTL: Duration?
    private let onRemove: @Sendable (Value, any Error) async -> Void
    private var closed = false

    public init(
        capacity: Int, queueTTL: Duration?, readyTTL: Duration?, errorTTL: Duration?,
        onRemove: @escaping @Sendable (Value, any Error) async -> Void
    ) {
        precondition(capacity > 0 && (errorTTL.map { $0 > .zero } ?? true))
        precondition(queueTTL.map { $0 > .zero } ?? true)
        precondition(readyTTL.map { $0 > .zero } ?? true)
        self.capacity = capacity
        self.queueTTL = queueTTL
        self.readyTTL = readyTTL
        self.errorTTL = errorTTL
        self.onRemove = onRemove
    }

    public func register(
        _ id: String, owner: StorageOwner, value: Value,
        cancel: @escaping @Sendable () async -> Void
    ) throws {
        prune()
        guard !closed else { throw StorageError.closed }
        guard entries[id] == nil, terminal[id] == nil else { throw StorageError.duplicate }
        guard entries.count < capacity else { throw StorageError.capacityExceeded }
        entries[id] = Entry(owner: owner, value: value, cancel: cancel)
        if let queueTTL { arm(id, after: queueTTL) }
    }

    public func begin(_ id: String) async throws -> Value {
        await expireIfNeeded(id)
        guard var entry = entries[id] else { throw terminal[id]?.error ?? StorageError.missing }
        guard !entry.started else { throw StorageError.duplicate }
        entry.started = true
        entry.timer?.cancel()
        entry.timer = nil
        entry.expiry = nil
        entry.timerID = nil
        entries[id] = entry
        return entry.value
    }

    /// Inspect an existing handle for producer completion without changing its lease state.
    public func valueForCompletion(_ id: String) throws -> Value {
        guard let entry = entries[id], entry.started else { throw StorageError.missing }
        return entry.value
    }

    public func complete(_ id: String) {
        guard let entry = entries[id], !entry.leased else { return }
        if let readyTTL { arm(id, after: readyTTL) }
    }

    public func validate(_ id: String, owner: StorageOwner) async throws {
        await expireIfNeeded(id)
        prune()
        if let result = terminal[id] {
            guard result.owner == owner else { throw StorageError.forbidden }
            throw result.error
        }
        guard let entry = entries[id] else { throw StorageError.missing }
        guard entry.owner == owner else { throw StorageError.forbidden }
    }

    public func checkout(_ id: String, owner: StorageOwner) async throws -> Value {
        try await validate(id, owner: owner)
        guard var entry = entries[id], !entry.leased else { throw StorageError.duplicate }
        entry.leased = true
        if entry.started {
            entry.timer?.cancel()
            entry.timer = nil
            entry.expiry = nil
            entry.timerID = nil
        }
        entries[id] = entry
        return entry.value
    }

    public func release(_ id: String, owner: StorageOwner) async throws {
        try await validate(id, owner: owner)
        await fail(id, error: StorageError.missing)
    }

    public func cancel(_ id: String, owner: StorageOwner) async throws {
        try await validate(id, owner: owner)
        await fail(id, error: CancellationError())
    }

    public func fail(_ id: String, error: any Error) async {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.timer?.cancel()
        prune()
        if terminal.count >= 128, let oldest = terminal.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
            terminal.removeValue(forKey: oldest)
        }
        terminal[id] = Terminal(
            owner: entry.owner, error: error, expires: errorTTL.map { .now.advanced(by: $0) }, createdAt: .now)
        await onRemove(entry.value, error)
        await entry.cancel()
    }

    public func cancel(inputID: String, source: String, namespace: String) async {
        let ids = entries.filter {
            $0.value.owner.input == inputID && $0.value.owner.source == source
                && $0.value.owner.namespace == namespace
        }.map(\.key)
        for id in ids { await fail(id, error: CancellationError()) }
    }

    public func cancel(sessionID: String, namespace: String) async {
        let ids = entries.filter {
            $0.value.owner.session == sessionID && $0.value.owner.namespace == namespace
        }.map(\.key)
        for id in ids { await fail(id, error: CancellationError()) }
    }

    /// Scope retirement removes error metadata after readers/producers have been cancelled.
    public func forgetTerminals(inputID: String, source: String, namespace: String) {
        terminal = terminal.filter {
            !($0.value.owner.input == inputID && $0.value.owner.source == source
                && $0.value.owner.namespace == namespace)
        }
    }
    public func forgetTerminals(sessionID: String, namespace: String) {
        terminal = terminal.filter {
            !($0.value.owner.session == sessionID && $0.value.owner.namespace == namespace)
        }
    }

    public func shutdown() async {
        closed = true
        for id in Array(entries.keys) { await fail(id, error: CancellationError()) }
        terminal.removeAll()
    }

    private func arm(_ id: String, after duration: Duration) {
        entries[id]?.timer?.cancel()
        let deadline = ContinuousClock.now.advanced(by: duration)
        let token = UUID()
        entries[id]?.expiry = deadline
        entries[id]?.timerID = token
        entries[id]?.timer = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            await self?.expire(id, token: token)
        }
    }

    private func expire(_ id: String, token: UUID) async {
        guard entries[id]?.timerID == token else { return }
        await expireIfNeeded(id)
    }

    private func expireIfNeeded(_ id: String) async {
        if let expiry = entries[id]?.expiry, expiry <= .now {
            await fail(id, error: StorageError.expired)
        }
    }

    private func prune() { terminal = terminal.filter { $0.value.expires.map { $0 > .now } ?? true } }
}

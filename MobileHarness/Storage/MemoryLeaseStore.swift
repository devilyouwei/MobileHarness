import Foundation

public struct StorageOwner: Sendable, Hashable {
    public let namespace: String
    public let source: String
    public let session: UUID
    public let input: UUID

    public init(namespace: String, source: String, session: UUID, input: UUID) {
        self.namespace = namespace
        self.source = source
        self.session = session
        self.input = input
    }
}

/// Bounded, single-checkout handles. A lease suspends completed-value expiry until release.
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
        let expires: ContinuousClock.Instant
    }
    private var entries: [UUID: Entry] = [:]
    private var terminal: [UUID: Terminal] = [:]
    private let capacity: Int
    private let queueTTL: Duration
    private let readyTTL: Duration
    private let errorTTL: Duration
    private let onRemove: @Sendable (Value, any Error) async -> Void
    private var closed = false

    public init(
        capacity: Int, queueTTL: Duration, readyTTL: Duration, errorTTL: Duration,
        onRemove: @escaping @Sendable (Value, any Error) async -> Void
    ) {
        precondition(capacity > 0 && queueTTL > .zero && readyTTL > .zero && errorTTL > .zero)
        self.capacity = capacity
        self.queueTTL = queueTTL
        self.readyTTL = readyTTL
        self.errorTTL = errorTTL
        self.onRemove = onRemove
    }

    public func register(
        _ id: UUID, owner: StorageOwner, value: Value,
        cancel: @escaping @Sendable () async -> Void
    ) throws {
        prune()
        guard !closed else { throw StorageError.closed }
        guard entries[id] == nil, terminal[id] == nil else { throw StorageError.duplicate }
        guard entries.count < capacity else { throw StorageError.capacityExceeded }
        entries[id] = Entry(owner: owner, value: value, cancel: cancel)
        arm(id, after: queueTTL)
    }

    public func begin(_ id: UUID) async throws -> Value {
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
    public func valueForCompletion(_ id: UUID) throws -> Value {
        guard let entry = entries[id], entry.started else { throw StorageError.missing }
        return entry.value
    }

    public func complete(_ id: UUID) {
        guard let entry = entries[id], !entry.leased else { return }
        arm(id, after: readyTTL)
    }

    public func validate(_ id: UUID, owner: StorageOwner) async throws {
        await expireIfNeeded(id)
        prune()
        if let result = terminal[id] {
            guard result.owner == owner else { throw StorageError.forbidden }
            throw result.error
        }
        guard let entry = entries[id] else { throw StorageError.missing }
        guard entry.owner == owner else { throw StorageError.forbidden }
    }

    public func checkout(_ id: UUID, owner: StorageOwner) async throws -> Value {
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

    public func release(_ id: UUID, owner: StorageOwner) async throws {
        try await validate(id, owner: owner)
        await fail(id, error: StorageError.missing)
    }

    public func cancel(_ id: UUID, owner: StorageOwner) async throws {
        try await validate(id, owner: owner)
        await fail(id, error: CancellationError())
    }

    public func fail(_ id: UUID, error: any Error) async {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.timer?.cancel()
        prune()
        if terminal.count >= 128, let oldest = terminal.min(by: { $0.value.expires < $1.value.expires })?.key {
            terminal.removeValue(forKey: oldest)
        }
        terminal[id] = Terminal(owner: entry.owner, error: error, expires: .now.advanced(by: errorTTL))
        await onRemove(entry.value, error)
        await entry.cancel()
    }

    public func cancel(inputID: UUID, source: String, namespace: String) async {
        let ids = entries.filter {
            $0.value.owner.input == inputID && $0.value.owner.source == source
                && $0.value.owner.namespace == namespace
        }.map(\.key)
        for id in ids { await fail(id, error: CancellationError()) }
    }

    public func cancel(sessionID: UUID, namespace: String) async {
        let ids = entries.filter {
            $0.value.owner.session == sessionID && $0.value.owner.namespace == namespace
        }.map(\.key)
        for id in ids { await fail(id, error: CancellationError()) }
    }

    public func shutdown() async {
        closed = true
        for id in Array(entries.keys) { await fail(id, error: CancellationError()) }
        terminal.removeAll()
    }

    private func arm(_ id: UUID, after duration: Duration) {
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

    private func expire(_ id: UUID, token: UUID) async {
        guard entries[id]?.timerID == token else { return }
        await expireIfNeeded(id)
    }

    private func expireIfNeeded(_ id: UUID) async {
        if let expiry = entries[id]?.expiry, expiry <= .now {
            await fail(id, error: StorageError.expired)
        }
    }

    private func prune() { terminal = terminal.filter { $0.value.expires > .now } }
}

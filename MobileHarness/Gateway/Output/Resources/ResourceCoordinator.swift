import AgentCore
import Foundation

public enum ResourceError: Error, Equatable, Sendable {
    case invalidDefinition, unknownResource, unauthorized, busy, staleLease, faulted, capacityExceeded
    case invalidDuration, cleanupTimedOut, shutdown
}

public struct ResourceDefinition: Sendable {
    public let id: ResourceID
    public let allowedOwners: Set<AgentID>
    public let requiresLease: Bool
    public let stop: @Sendable () async throws -> Void

    public init(
        id: ResourceID, allowedOwners: Set<AgentID>, requiresLease: Bool = false,
        stop: @escaping @Sendable () async throws -> Void
    ) {
        self.id = id
        self.allowedOwners = allowedOwners
        self.requiresLease = requiresLease
        self.stop = stop
    }
}

/// Process-wide ownership and execution fences shared by Actions, Tools and host lifecycle operations.
public actor ResourceCoordinator {
    public enum State: Sendable, Equatable {
        case available
        case leased(UUID)
        case transitioning, faulted
    }
    private struct LeaseRecord {
        var lease: ResourceLease
        let revoke: @Sendable (Set<ResourceID>) async -> Void
    }
    private struct Use {
        let resources: Set<ResourceID>
        let owner: ExecutionOwner?
        let cancel: @Sendable () -> Void
        let join: @Sendable () async -> Void
    }
    private struct Cleanup {
        let resources: Set<ResourceID>
        let task: Task<Void, Never>
    }
    private enum CleanupResult: Sendable {
        case success
        case failure(any Error)
    }
    private let definitions: [ResourceID: ResourceDefinition]
    private var states: [ResourceID: State]
    private var leases: [UUID: LeaseRecord] = [:]
    private var uses: [UUID: Use] = [:]
    private var cleanups: [UUID: Cleanup] = [:]
    private var expiry: Task<Void, Never>?
    private var closed = false
    private let cleanupDeadline: Duration

    public init(definitions: [ResourceDefinition], cleanupDeadline: Duration = .seconds(5)) throws {
        guard definitions.count <= 64, cleanupDeadline > .zero, cleanupDeadline <= .seconds(30) else {
            throw ResourceError.invalidDefinition
        }
        var catalog: [ResourceID: ResourceDefinition] = [:]
        for definition in definitions {
            guard !definition.id.rawValue.isEmpty, definition.id.rawValue.utf8.count <= 64,
                definition.allowedOwners.count <= 128, catalog[definition.id] == nil
            else { throw ResourceError.invalidDefinition }
            catalog[definition.id] = definition
        }
        self.definitions = catalog
        self.states = Dictionary(uniqueKeysWithValues: catalog.keys.map { ($0, .available) })
        self.cleanupDeadline = cleanupDeadline
    }

    deinit { expiry?.cancel() }

    public func snapshot() -> [ResourceID: State] { states }
    public func activeCleanupCount() -> Int { cleanups.count }

    public func validate(resources: Set<ResourceID>, owner: ExecutionOwner?, lease: ResourceLease?) throws {
        guard !closed else { throw ResourceError.shutdown }
        guard resources.count <= 8 else { throw ResourceError.capacityExceeded }
        for id in resources {
            guard let definition = definitions[id], let state = states[id] else { throw ResourceError.unknownResource }
            switch state {
            case .available:
                guard !definition.requiresLease, lease == nil else { throw ResourceError.staleLease }
            case .leased(let token):
                guard let lease, let current = leases[token]?.lease, current.id == lease.id,
                    current.owner == owner, current.owner == lease.owner, current.resources == lease.resources,
                    current.deadline > .now, current.resources.contains(id)
                else { throw ResourceError.staleLease }
            case .transitioning: throw ResourceError.busy
            case .faulted: throw ResourceError.faulted
            }
        }
    }

    public func lease(for owner: ExecutionOwner, resources: Set<ResourceID>) -> ResourceLease? {
        guard !resources.isEmpty else { return nil }
        return leases.values.first { $0.lease.owner == owner && resources.isSubset(of: $0.lease.resources) }?.lease
    }

    /// There is no lock-wait queue. The entire requested group is gated before any external await.
    public func acquire(
        resources requested: Set<ResourceID>, owner: ExecutionOwner, duration: Duration,
        revoke: @escaping @Sendable (Set<ResourceID>) async -> Void
    ) async throws -> ResourceLease {
        try Task.checkCancellation()
        guard !closed else { throw ResourceError.shutdown }
        try validateDuration(duration)
        guard !requested.isEmpty, requested.count <= 8 else { throw ResourceError.capacityExceeded }
        for id in requested {
            guard let definition = definitions[id] else { throw ResourceError.unknownResource }
            guard definition.allowedOwners.contains(owner.agent) else { throw ResourceError.unauthorized }
            if states[id] == .faulted { throw ResourceError.faulted }
            if states[id] == .transitioning { throw ResourceError.busy }
        }
        let victims = leases.values.filter { !$0.lease.resources.isDisjoint(with: requested) }
        let affected = victims.reduce(requested) { $0.union($1.lease.resources) }
        guard leases.count - victims.count < 32, cleanups.count < 32 else { throw ResourceError.capacityExceeded }
        for id in affected { states[id] = .transitioning }
        for victim in victims { leases[victim.lease.id] = nil }
        scheduleExpiry()
        do {
            try await clean(affected) { ids in
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await revoke(ids) }
                    for victim in victims { group.addTask { await victim.revoke(ids) } }
                }
            }
            try Task.checkCancellation()
            guard !closed else { throw ResourceError.shutdown }
            let lease = ResourceLease(
                id: UUID(), owner: owner, resources: requested, deadline: .now.advanced(by: duration))
            for id in affected { states[id] = .available }
            for id in requested { states[id] = .leased(lease.id) }
            leases[lease.id] = LeaseRecord(lease: lease, revoke: revoke)
            scheduleExpiry()
            return lease
        } catch {
            for id in affected { states[id] = .faulted }
            throw error
        }
    }

    public func renew(_ lease: ResourceLease, owner: ExecutionOwner, duration: Duration) throws -> ResourceLease {
        try Task.checkCancellation()
        guard !closed else { throw ResourceError.shutdown }
        try validateDuration(duration)
        guard var record = leases[lease.id], record.lease.owner == owner, lease.owner == owner,
            record.lease.resources == lease.resources, record.lease.deadline > .now
        else { throw ResourceError.staleLease }
        record.lease = ResourceLease(
            id: lease.id, owner: owner, resources: lease.resources, deadline: .now.advanced(by: duration))
        leases[lease.id] = record
        scheduleExpiry()
        return record.lease
    }

    public func release(_ lease: ResourceLease, owner: ExecutionOwner) async throws {
        guard let record = leases[lease.id], record.lease.owner == owner, lease.owner == owner,
            record.lease.resources == lease.resources
        else { throw ResourceError.staleLease }
        guard cleanups.count < 32 else { throw ResourceError.capacityExceeded }
        leases[lease.id] = nil
        for id in record.lease.resources { states[id] = .transitioning }
        scheduleExpiry()
        do {
            try await clean(record.lease.resources, revoke: record.revoke)
            for id in record.lease.resources { states[id] = .available }
        } catch {
            for id in record.lease.resources { states[id] = .faulted }
            throw error
        }
    }

    /// Root-owned recovery; never grants a lease and cannot overlap an unfinished cleanup.
    public func recover(_ resources: Set<ResourceID>) async throws {
        guard !closed, !resources.isEmpty, resources.count <= 8,
            resources.allSatisfy({ states[$0] == .faulted })
        else { throw ResourceError.faulted }
        guard !cleanups.values.contains(where: { !$0.resources.isDisjoint(with: resources) }) else {
            throw ResourceError.busy
        }
        for id in resources { states[id] = .transitioning }
        do {
            try await clean(resources, revoke: { _ in })
            for id in resources { states[id] = .available }
        } catch {
            for id in resources { states[id] = .faulted }
            throw error
        }
    }

    /// Protects all entry paths, including direct Tools. Already busy resources reject explicitly.
    public func run<Value: Sendable>(
        resources: Set<ResourceID>, owner: ExecutionOwner?, lease: ResourceLease?,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        try validate(resources: resources, owner: owner, lease: lease)
        guard uses.count < 256 else { throw ResourceError.capacityExceeded }
        guard !uses.values.contains(where: { !$0.resources.isDisjoint(with: resources) }) else {
            throw ResourceError.busy
        }
        let id = UUID()
        let task = Task {
            try Task.checkCancellation()
            return try await ResourceExecutionContext.$owner.withValue(owner) {
                try await ResourceExecutionContext.$held.withValue(resources) { try await operation() }
            }
        }
        uses[id] = Use(resources: resources, owner: owner, cancel: { task.cancel() }, join: { _ = await task.result })
        defer { uses[id] = nil }
        return try await withTaskCancellationHandler {
            let value = try await task.value
            try Task.checkCancellation()
            try validate(resources: resources, owner: owner, lease: lease)
            return value
        } onCancel: {
            task.cancel()
        }
    }

    public func close(agent: AgentID, incarnation: UUID) async {
        let selected = leases.values.filter {
            $0.lease.owner.agent == agent && $0.lease.owner.incarnation == incarnation
        }
        for record in selected { do { try await release(record.lease, owner: record.lease.owner) } catch {} }
        let owned = uses.values.filter { $0.owner?.agent == agent && $0.owner?.incarnation == incarnation }
        let sessions = Set(owned.compactMap { $0.owner?.sessionID })
        for session in sessions { await stopUnleasedUses(sessionID: session) }
    }

    public func close(sessionID: UUID) async {
        let selected = leases.values.filter { $0.lease.owner.sessionID == sessionID }
        for record in selected { do { try await release(record.lease, owner: record.lease.owner) } catch {} }
        await stopUnleasedUses(sessionID: sessionID)
    }

    public func shutdown() async {
        closed = true
        expiry?.cancel()
        expiry = nil
        let selected = Array(leases.values)
        for record in selected { do { try await release(record.lease, owner: record.lease.owner) } catch {} }
        await stopUnleasedUses()
    }

    private func stopUnleasedUses(sessionID: UUID? = nil) async {
        let selected = uses.values.filter { sessionID == nil || $0.owner?.sessionID == sessionID }
        let resources = selected.reduce(into: Set<ResourceID>()) { $0.formUnion($1.resources) }
            .filter { states[$0] == .available }
        guard !resources.isEmpty else { return }
        for id in resources { states[id] = .transitioning }
        do {
            try await clean(resources, revoke: { _ in })
            for id in resources { states[id] = .available }
        } catch { for id in resources { states[id] = .faulted } }
    }

    private func validateDuration(_ duration: Duration) throws {
        guard duration > .zero, duration <= .seconds(60) else { throw ResourceError.invalidDuration }
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        expiry = nil
        guard !closed, let deadline = leases.values.map({ $0.lease.deadline }).min() else { return }
        expiry = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: max(deadline, .now.advanced(by: .milliseconds(10)))) } catch {
                return
            }
            await self?.expireLeases()
        }
    }

    private func expireLeases() async {
        expiry = nil
        let expired = leases.values.filter { $0.lease.deadline <= .now }
        for record in expired {
            // Renewal may have happened while another expired group was being cleaned.
            guard leases[record.lease.id]?.lease.deadline == record.lease.deadline else { continue }
            do { try await release(record.lease, owner: record.lease.owner) } catch {}
        }
        scheduleExpiry()
    }

    private func clean(_ resources: Set<ResourceID>, revoke: @escaping @Sendable (Set<ResourceID>) async -> Void)
        async throws
    {
        guard cleanups.count < 32 else { throw ResourceError.capacityExceeded }
        let active = uses.values.filter { !$0.resources.isDisjoint(with: resources) }
        for use in active { use.cancel() }
        let stops = resources.compactMap { definitions[$0]?.stop }
        let id = UUID()
        let pair = AsyncStream<CleanupResult>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let task = Task {
            do {
                async let queues: Void = revoke(resources)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for stop in stops { group.addTask { try await stop() } }
                    for use in active { group.addTask { await use.join() } }
                    try await group.waitForAll()
                }
                await queues
                pair.continuation.yield(.success)
            } catch { pair.continuation.yield(.failure(error)) }
            pair.continuation.finish()
            self.cleanupFinished(id)
        }
        cleanups[id] = Cleanup(resources: resources, task: task)
        let timeout = Task {
            do { try await Task.sleep(for: cleanupDeadline) } catch { return }
            pair.continuation.yield(.failure(ResourceError.cleanupTimedOut))
            pair.continuation.finish()
        }
        defer { timeout.cancel() }
        var iterator = pair.stream.makeAsyncIterator()
        let result = await iterator.next()
        switch result {
        case .success: return
        case .failure(let error):
            task.cancel()
            throw error
        case nil:
            task.cancel()
            throw CancellationError()
        }
    }

    private func cleanupFinished(_ id: UUID) { cleanups[id] = nil }
}

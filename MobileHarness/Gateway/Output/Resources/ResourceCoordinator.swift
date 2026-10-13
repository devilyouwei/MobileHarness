import AgentCore
import Foundation

public enum ResourceError: Error, Equatable, Sendable {
    case invalidDefinition, unknownResource, unauthorized, busy, staleLease, staleUse, capacityExceeded
    case invalidDuration, shutdown
}

public struct ResourceDefinition: Sendable {
    public let id: ResourceID
    public let allowedOwners: Set<AgentID>
    public let requiresLease: Bool
    /// Resources sharing a physical writer exclude one another even when their declared IDs differ.
    public let executionGroup: ResourceID?
    /// Host-owned policy: a requesting Agent may interrupt only these existing owners.
    public let preempts: [AgentID: Set<AgentID>]
    public let stop: @Sendable () async throws -> Void

    public init(
        id: ResourceID, allowedOwners: Set<AgentID>, requiresLease: Bool = false,
        executionGroup: ResourceID? = nil, preempts: [AgentID: Set<AgentID>] = [:],
        stop: @escaping @Sendable () async throws -> Void
    ) {
        self.id = id
        self.allowedOwners = allowedOwners
        self.requiresLease = requiresLease
        self.executionGroup = executionGroup
        self.preempts = preempts
        self.stop = stop
    }
}

/// Process-wide ownership shared by Actions, Tools and host lifecycle operations.
public actor ResourceCoordinator {
    public enum State: Sendable, Equatable {
        case unlocked
        case locked(ExecutionOwner?)
    }
    private enum HoldingKind: Equatable {
        case lease(UUID)
        case use(UUID)
        case handoff(UUID)
    }
    private struct Holding {
        let owner: ExecutionOwner?
        let kind: HoldingKind
    }
    private struct LeaseRecord {
        var lease: ResourceLease
        let scope: Set<ResourceID>
        let revoke: @Sendable (Set<ResourceID>) async -> Void
    }
    private struct Use {
        let resources: Set<ResourceID>
        let scope: Set<ResourceID>
        let owner: ExecutionOwner?
        let leaseID: UUID?
        let cancel: @Sendable () -> Void
        let join: @Sendable () async -> Void
    }
    private struct Cleanup {
        let resources: Set<ResourceID>
        let retiredUses: Set<UUID>
        var nextOwner: ExecutionOwner?
        var waiting = true
        var finished = false
        var observers: [UUID: AsyncStream<CleanupResult>.Continuation] = [:]
        let task: Task<Void, Never>
    }
    private enum CleanupResult: Sendable {
        case success
        case failure(any Error)
    }
    private let definitions: [ResourceID: ResourceDefinition]
    // The sole authority for occupancy; leases/uses/cleanups retain lifecycle metadata only.
    private var holdings: [ResourceID: Holding] = [:]
    private var leases: [UUID: LeaseRecord] = [:]
    private var uses: [UUID: Use] = [:]
    private var cleanups: [UUID: Cleanup] = [:]
    private var expiry: Task<Void, Never>?
    private var closed = false

    public init(definitions: [ResourceDefinition]) throws {
        guard definitions.count <= 64 else {
            throw ResourceError.invalidDefinition
        }
        var catalog: [ResourceID: ResourceDefinition] = [:]
        for definition in definitions {
            guard !definition.id.rawValue.isEmpty, definition.id.rawValue.utf8.count <= 64,
                definition.allowedOwners.count <= 128, catalog[definition.id] == nil,
                definition.executionGroup.map({ !$0.rawValue.isEmpty && $0.rawValue.utf8.count <= 64 }) ?? true,
                definition.preempts.count <= 128,
                definition.preempts.allSatisfy({ $0.value.count <= 128 && !$0.value.contains($0.key) })
            else { throw ResourceError.invalidDefinition }
            catalog[definition.id] = definition
        }
        self.definitions = catalog
    }

    deinit { expiry?.cancel() }

    public func snapshot() -> [ResourceID: State] {
        Dictionary(
            uniqueKeysWithValues: definitions.keys.map { id in
                (id, holdings[id].map { .locked($0.owner) } ?? .unlocked)
            })
    }
    public func activeCleanupCount() -> Int { cleanups.count }

    public func validate(resources: Set<ResourceID>, owner: ExecutionOwner?, lease: ResourceLease?) throws {
        try validate(resources: resources, owner: owner, lease: lease, admitting: false)
    }

    /// Later Actions from the reserved takeover owner may enter the existing bounded Channel.
    public func validateAdmission(resources: Set<ResourceID>, owner: ExecutionOwner?, lease: ResourceLease?) throws {
        try validate(resources: resources, owner: owner, lease: lease, admitting: true)
    }

    private func validate(
        resources: Set<ResourceID>, owner: ExecutionOwner?, lease: ResourceLease?, admitting: Bool
    ) throws {
        guard !closed else { throw ResourceError.shutdown }
        guard resources.count <= 8 else { throw ResourceError.capacityExceeded }
        for id in resources {
            guard let definition = definitions[id] else { throw ResourceError.unknownResource }
            if definition.requiresLease && lease == nil { throw ResourceError.staleLease }
        }
        if let lease {
            guard let record = leases[lease.id], record.lease.owner == owner, lease.owner == owner,
                record.lease.resources == lease.resources, record.lease.deadline > .now,
                resources.isSubset(of: record.lease.resources),
                record.scope.allSatisfy({ holdings[$0]?.kind == .lease(lease.id) })
            else { throw ResourceError.staleLease }
        }
        for id in executionScope(resources) {
            guard let holding = holdings[id] else { continue }
            switch holding.kind {
            case .lease(let token):
                guard lease?.id == token else { throw ResourceError.staleLease }
            case .use:
                // Actual use conflicts/preemption are decided atomically by run. Admission
                // preserves accepted Channel work, rather than creating a second lock queue.
                break
            case .handoff(let token):
                guard admitting, let owner, cleanups[token]?.nextOwner == owner, lease == nil,
                    resources.allSatisfy({ definitions[$0]?.requiresLease == false })
                else { throw ResourceError.busy }
            }
        }
    }

    public func lease(for owner: ExecutionOwner, resources: Set<ResourceID>) -> ResourceLease? {
        guard !resources.isEmpty else { return nil }
        return leases.values.first { record in
            record.lease.owner == owner && resources.isSubset(of: record.lease.resources)
                && record.scope.allSatisfy { holdings[$0]?.kind == .lease(record.lease.id) }
        }?.lease
    }

    /// Explicit lease takeover keeps its existing owner permissions and revocation policy.
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
        }
        let affected = cleanupScope(executionScope(requested))
        try checkNoHandoff(affected)
        let victims = leases.values.filter { !$0.scope.isDisjoint(with: affected) }
        guard leases.count - victims.count < 32, cleanups.count < 32 else { throw ResourceError.capacityExceeded }
        for victim in victims { leases[victim.lease.id] = nil }
        scheduleExpiry()
        let token = try await clean(affected, nextOwner: owner) { ids in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await revoke(ids) }
                for victim in victims { group.addTask { await victim.revoke(ids) } }
            }
        }
        defer { finishHandoff(token) }
        try Task.checkCancellation()
        guard !closed else { throw ResourceError.shutdown }
        let lease = ResourceLease(id: UUID(), owner: owner, resources: requested, deadline: .now.advanced(by: duration))
        let scope = executionScope(requested)
        finishHandoff(token)
        for id in scope { holdings[id] = Holding(owner: owner, kind: .lease(lease.id)) }
        leases[lease.id] = LeaseRecord(lease: lease, scope: scope, revoke: revoke)
        scheduleExpiry()
        return lease
    }

    public func renew(_ lease: ResourceLease, owner: ExecutionOwner, duration: Duration) throws -> ResourceLease {
        try Task.checkCancellation()
        guard !closed else { throw ResourceError.shutdown }
        try validateDuration(duration)
        guard var record = leases[lease.id], record.lease.owner == owner, lease.owner == owner,
            record.lease.resources == lease.resources, record.lease.deadline > .now,
            record.scope.allSatisfy({ holdings[$0]?.kind == .lease(lease.id) })
        else { throw ResourceError.staleLease }
        record.lease = ResourceLease(
            id: lease.id, owner: owner, resources: lease.resources, deadline: .now.advanced(by: duration))
        leases[lease.id] = record
        scheduleExpiry()
        return record.lease
    }

    public func release(_ lease: ResourceLease, owner: ExecutionOwner) async throws {
        guard let record = leases[lease.id], record.lease.owner == owner, lease.owner == owner,
            record.lease.resources == lease.resources,
            record.scope.allSatisfy({ holdings[$0]?.kind == .lease(lease.id) })
        else { throw ResourceError.staleLease }
        let scope = cleanupScope(record.scope)
        try checkNoHandoff(scope)
        guard cleanups.count < 32 else { throw ResourceError.capacityExceeded }
        leases[lease.id] = nil
        scheduleExpiry()
        let token = try await clean(scope, nextOwner: nil, revoke: record.revoke)
        finishHandoff(token)
    }

    public func run<Value: Sendable>(
        resources: Set<ResourceID>, owner: ExecutionOwner?, lease: ResourceLease?,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        try validate(resources: resources, owner: owner, lease: lease)
        guard uses.count < 256 else { throw ResourceError.capacityExceeded }
        let scope = executionScope(resources)
        let victims = uses.values.filter { !$0.scope.isDisjoint(with: scope) }
        if !victims.isEmpty {
            guard lease == nil, let owner,
                victims.allSatisfy({ victim in
                    guard victim.leaseID == nil, let previous = victim.owner else { return false }
                    return resources.allSatisfy {
                        definitions[$0]?.preempts[owner.agent]?.contains(previous.agent) == true
                    }
                })
            else { throw ResourceError.busy }
            let affected = cleanupScope(scope)
            try checkNoHandoff(affected)
            guard
                affected.allSatisfy({ id in
                    if case .lease = holdings[id]?.kind { return false }
                    return true
                })
            else { throw ResourceError.busy }
            let token = try await clean(affected, nextOwner: owner, revoke: { _ in })
            // No suspension between retiring this handoff and installing the new writer.
            finishHandoff(token)
            try Task.checkCancellation()
            try validate(resources: resources, owner: owner, lease: lease)
        }
        let id = UUID()
        let permit = ResourceExecutionPermit { [self] requested in
            try Task.checkCancellation()
            do { try await validateUse(id, resources: requested) } catch {
                try Task.checkCancellation()
                throw error
            }
            try Task.checkCancellation()
        }
        let task = Task {
            try Task.checkCancellation()
            let value = try await ResourceExecutionContext.$owner.withValue(owner) {
                try await ResourceExecutionContext.$held.withValue(resources) {
                    try await ResourceExecutionContext.$permit.withValue(permit) { try await operation() }
                }
            }
            try Task.checkCancellation()
            return value
        }
        uses[id] = Use(
            resources: resources, scope: scope, owner: owner, leaseID: lease?.id,
            cancel: { task.cancel() }, join: { _ = await task.result })
        if lease == nil {
            for resource in scope { holdings[resource] = Holding(owner: owner, kind: .use(id)) }
        }
        defer { finishUse(id) }
        return try await withTaskCancellationHandler {
            let value = try await task.value
            try Task.checkCancellation()
            try validateUse(id, resources: resources)
            return value
        } onCancel: {
            task.cancel()
        }
    }

    private func validateUse(_ id: UUID, resources: Set<ResourceID>) throws {
        guard !closed else { throw ResourceError.shutdown }
        guard let use = uses[id], resources.isSubset(of: use.resources),
            use.scope.allSatisfy({ holdings[$0]?.kind == (use.leaseID.map { .lease($0) } ?? .use(id)) })
        else { throw ResourceError.staleUse }
        if let token = use.leaseID {
            guard let lease = leases[token]?.lease, lease.deadline > .now else { throw ResourceError.staleLease }
        }
    }

    private func finishUse(_ id: UUID) {
        guard let use = uses.removeValue(forKey: id) else { return }
        for resource in use.scope where holdings[resource]?.kind == .use(id) { holdings[resource] = nil }
    }

    private func executionScope(_ resources: Set<ResourceID>) -> Set<ResourceID> {
        let groups = Set(resources.compactMap { definitions[$0]?.executionGroup })
        return resources.union(
            definitions.values.compactMap { definition in
                guard let group = definition.executionGroup, groups.contains(group) else { return nil }
                return definition.id
            })
    }

    // A multi-resource execution/lease is retired as a whole, including shared writer siblings.
    private func cleanupScope(_ resources: Set<ResourceID>) -> Set<ResourceID> {
        var scope = resources
        while true {
            let previous = scope
            for use in uses.values where !use.scope.isDisjoint(with: scope) { scope.formUnion(use.scope) }
            for record in leases.values where !record.scope.isDisjoint(with: scope) { scope.formUnion(record.scope) }
            if scope == previous { return scope }
        }
    }

    private func checkNoHandoff(_ resources: Set<ResourceID>) throws {
        for id in resources { if case .handoff = holdings[id]?.kind { throw ResourceError.busy } }
    }

    public func close(agent: AgentID, incarnation: UUID) async {
        let selected = leases.values.filter {
            $0.lease.owner.agent == agent && $0.lease.owner.incarnation == incarnation
        }
        for record in selected { do { try await release(record.lease, owner: record.lease.owner) } catch {} }
        let selectedUses = uses.values.filter { $0.owner?.agent == agent && $0.owner?.incarnation == incarnation }
        let owned = Set(
            holdings.compactMap { id, holding in
                holding.owner?.agent == agent && holding.owner?.incarnation == incarnation ? id : nil
            })
        await stopUses(selectedUses, owned: owned)
    }

    public func close(sessionID: UUID) async {
        let selected = leases.values.filter { $0.lease.owner.sessionID == sessionID }
        for record in selected { do { try await release(record.lease, owner: record.lease.owner) } catch {} }
        let owned = Set(holdings.compactMap { id, holding in holding.owner?.sessionID == sessionID ? id : nil })
        await stopUses(uses.values.filter { $0.owner?.sessionID == sessionID }, owned: owned)
    }

    public func shutdown() async {
        closed = true
        expiry?.cancel()
        expiry = nil
        for record in Array(leases.values) {
            do { try await release(record.lease, owner: record.lease.owner) } catch {}
        }
        await stopUses(Array(uses.values), owned: Set(holdings.keys))
    }

    private func stopUses(_ selected: [Use], owned: Set<ResourceID>) async {
        let scope = cleanupScope(selected.reduce(into: owned) { $0.formUnion($1.scope) })
        guard !scope.isEmpty else { return }
        let existing = Set(
            scope.compactMap { id -> UUID? in
                if case .handoff(let token) = holdings[id]?.kind { return token }
                return nil
            })
        let remaining = scope.filter { id in
            if case .handoff = holdings[id]?.kind { return false }
            return true
        }
        if !remaining.isEmpty {
            do {
                let token = try await clean(remaining, nextOwner: nil, revoke: { _ in })
                finishHandoff(token)
            } catch {}
        }
        // Lifecycle closure joins already-owned cleanup without cancelling a new request
        // or creating another stop operation against its future owner.
        for token in existing { do { try await observeHandoff(token) } catch {} }
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
        for record in leases.values.filter({ $0.lease.deadline <= .now }) {
            guard leases[record.lease.id]?.lease.deadline == record.lease.deadline else { continue }
            do { try await release(record.lease, owner: record.lease.owner) } catch {}
        }
        scheduleExpiry()
    }

    /// Returns a completed handoff still reserved for the caller. Failure/timeout abandons the
    /// reservation; retained work releases itself when its actual stop/join later finishes.
    private func clean(
        _ resources: Set<ResourceID>, nextOwner: ExecutionOwner?,
        revoke: @escaping @Sendable (Set<ResourceID>) async -> Void
    ) async throws -> UUID {
        guard cleanups.count < 32 else { throw ResourceError.capacityExceeded }
        try checkNoHandoff(resources)
        let selected = uses.filter { !$0.value.scope.isDisjoint(with: resources) }
        let active = Array(selected.values)
        let stops = resources.compactMap { definitions[$0]?.stop }
        let id = UUID()
        for resource in resources {
            holdings[resource] = Holding(owner: holdings[resource]?.owner ?? nextOwner, kind: .handoff(id))
        }
        for use in active { use.cancel() }
        let pair = AsyncStream<CleanupResult>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let task = Task {
            // Collect stop errors without cancelling sibling stop/join tasks. An error is an
            // outcome for this request, not proof that a completed writer remains occupied.
            let result = await withTaskGroup(of: CleanupResult.self) { group in
                group.addTask {
                    await revoke(resources)
                    return .success
                }
                for stop in stops {
                    group.addTask {
                        do {
                            try await stop()
                            return .success
                        } catch { return .failure(error) }
                    }
                }
                for use in active {
                    group.addTask {
                        await use.join()
                        return .success
                    }
                }
                var result = CleanupResult.success
                for await value in group {
                    if case .failure = value, case .success = result { result = value }
                }
                return result
            }
            self.cleanupFinished(id)
            pair.continuation.yield(result)
            pair.continuation.finish()
        }
        cleanups[id] = Cleanup(resources: resources, retiredUses: Set(selected.keys), nextOwner: nextOwner, task: task)
        let acknowledgment = Task {
            var iterator = pair.stream.makeAsyncIterator()
            return await iterator.next()
        }
        switch await acknowledgment.value {
        case .success: return id
        case .failure(let error):
            abandonHandoff(id)
            throw error
        case nil:
            abandonHandoff(id)
            throw CancellationError()
        }
    }

    private func abandonHandoff(_ id: UUID) {
        guard var cleanup = cleanups[id] else { return }
        cleanup.waiting = false
        cleanup.nextOwner = nil
        cleanups[id] = cleanup
        if cleanup.finished { finishHandoff(id) }
    }

    private func cleanupFinished(_ id: UUID) {
        guard var cleanup = cleanups[id] else { return }
        // Native writers have joined even if their run callers have not resumed yet. Retire
        // these exact identities now so lifecycle closure cannot mistake them for a new owner.
        for use in cleanup.retiredUses { finishUse(use) }
        cleanup.finished = true
        for observer in cleanup.observers.values {
            observer.yield(.success)
            observer.finish()
        }
        cleanup.observers.removeAll()
        cleanups[id] = cleanup
        if !cleanup.waiting { finishHandoff(id) }
    }

    private func observeHandoff(_ id: UUID) async throws {
        guard var cleanup = cleanups[id], !cleanup.finished else { return }
        guard cleanup.observers.count < 8 else { throw ResourceError.capacityExceeded }
        let observerID = UUID()
        let pair = AsyncStream<CleanupResult>.makeStream(bufferingPolicy: .bufferingOldest(1))
        cleanup.observers[observerID] = pair.continuation
        cleanups[id] = cleanup
        defer {
            cleanups[id]?.observers[observerID] = nil
            pair.continuation.finish()
        }
        let acknowledgment = Task {
            var iterator = pair.stream.makeAsyncIterator()
            return await iterator.next()
        }
        switch await acknowledgment.value {
        case .success: return
        case .failure(let error): throw error
        case nil: throw CancellationError()
        }
    }

    private func finishHandoff(_ id: UUID) {
        guard let cleanup = cleanups[id], cleanup.finished else { return }
        for resource in cleanup.resources where holdings[resource]?.kind == .handoff(id) { holdings[resource] = nil }
        cleanups[id] = nil
    }
}

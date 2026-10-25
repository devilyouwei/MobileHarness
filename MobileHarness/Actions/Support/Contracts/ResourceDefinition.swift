import Foundation

public enum ResourceError: Error, Equatable, Sendable {
    case invalidDefinition, unknownResource, unauthorized, busy, staleLease, staleUse, capacityExceeded
    case invalidDuration, shutdown
}

public struct ResourceDefinition: Sendable {
    public let id: ResourceID
    public let allowedOwners: Set<String>
    public let requiresLease: Bool
    /// Resources sharing a physical writer exclude one another even when their declared IDs differ.
    public let executionGroup: ResourceID?
    /// Opaque endpoint policy: a requester may interrupt only these existing owners.
    public let preempts: [String: Set<String>]
    public let stop: @Sendable () async throws -> Void

    public init(
        id: ResourceID, allowedOwners: Set<String>, requiresLease: Bool = false,
        executionGroup: ResourceID? = nil, preempts: [String: Set<String>] = [:],
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

public struct ResourcePolicy: Sendable {
    public let id: ResourceID
    public let allowedOwners: Set<String>
    public let requiresLease: Bool
    public let executionGroup: ResourceID?
    public let preempts: [String: Set<String>]
    public init(
        id: ResourceID, allowedOwners: Set<String>, requiresLease: Bool = false,
        executionGroup: ResourceID? = nil, preempts: [String: Set<String>] = [:]
    ) {
        self.id = id
        self.allowedOwners = allowedOwners
        self.requiresLease = requiresLease
        self.executionGroup = executionGroup
        self.preempts = preempts
    }
}
extension ResourceDefinition {
    public init(policy: ResourcePolicy, stop: @escaping @Sendable () async throws -> Void) {
        self.init(
            id: policy.id, allowedOwners: policy.allowedOwners, requiresLease: policy.requiresLease,
            executionGroup: policy.executionGroup, preempts: policy.preempts, stop: stop)
    }
}

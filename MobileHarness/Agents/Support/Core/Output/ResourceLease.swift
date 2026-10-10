import Foundation

public struct ResourceID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct ResourceLease: Equatable, Sendable {
    public let id: UUID
    public let owner: ExecutionOwner
    public let resources: Set<ResourceID>
    public let deadline: ContinuousClock.Instant

    public init(id: UUID, owner: ExecutionOwner, resources: Set<ResourceID>, deadline: ContinuousClock.Instant) {
        self.id = id
        self.owner = owner
        self.resources = resources
        self.deadline = deadline
    }
}

/// Bound by OutputGateway to an Agent instance/session, never reconstructed from model arguments.
public struct ResourceControl: Sendable {
    public let acquire: @Sendable (Set<ResourceID>, Duration) async throws -> ResourceLease
    public let renew: @Sendable (ResourceLease, Duration) async throws -> ResourceLease
    public let release: @Sendable (ResourceLease) async throws -> Void

    public init(
        acquire: @escaping @Sendable (Set<ResourceID>, Duration) async throws -> ResourceLease,
        renew: @escaping @Sendable (ResourceLease, Duration) async throws -> ResourceLease,
        release: @escaping @Sendable (ResourceLease) async throws -> Void
    ) {
        self.acquire = acquire
        self.renew = renew
        self.release = release
    }
}

/// Revocable validation capability bound to one actual resource execution, not an Agent alone.
public struct ResourceExecutionPermit: Sendable {
    public let validate: @Sendable (Set<ResourceID>) async throws -> Void

    public init(validate: @escaping @Sendable (Set<ResourceID>) async throws -> Void) {
        self.validate = validate
    }
}

/// Trusted execution context inherited by child tasks; never read from model parameters.
public enum ResourceExecutionContext {
    @TaskLocal public static var held: Set<ResourceID> = []
    @TaskLocal public static var permit: ResourceExecutionPermit?
    /// Bound by Gateway, including intent Tools whose host worker outlives dispatch.
    @TaskLocal public static var owner: ExecutionOwner?
}

import Foundation

public struct ResourceID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let cameraCapture = Self(rawValue: "camera.capture")
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

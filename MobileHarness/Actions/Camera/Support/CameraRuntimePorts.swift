#if os(iOS)
    import AgentCore
    import Foundation
    import PlatformKit

    /// Resource arbitration is injected; camera execution never imports the Gateway implementation.
    public protocol CameraResourceAccess: Sendable {
        func acquire(resources: Set<ResourceID>, owner: ExecutionOwner, duration: Duration) async throws
            -> ResourceLease
        func run(
            resources: Set<ResourceID>, owner: ExecutionOwner, lease: ResourceLease,
            operation: @escaping @Sendable () async throws -> AsyncThrowingStream<CameraFrame, Error>
        ) async throws -> AsyncThrowingStream<CameraFrame, Error>
        func renew(_ lease: ResourceLease, owner: ExecutionOwner, duration: Duration) async throws -> ResourceLease
        func release(_ lease: ResourceLease, owner: ExecutionOwner) async throws
        func isReleased(_ resource: ResourceID) async -> Bool
    }

    public enum CameraResourceFailure: Error { case staleLease }

    @MainActor public struct CameraRuntimeDependencies {
        public let resources: any CameraResourceAccess
        public init(resources: any CameraResourceAccess) { self.resources = resources }
    }

    @MainActor public protocol CameraVisionRunning: AnyObject, Sendable {
        func run(
            frames: AsyncThrowingStream<CameraFrame, Error>, sessionID: String,
            mirroredGaze: Bool, endpoint: any CameraOutputHandling) async throws
    }
#endif

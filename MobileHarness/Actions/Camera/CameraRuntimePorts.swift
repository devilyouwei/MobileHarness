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

    /// Agent-owned integration callbacks, supplied to the App-owned Coordinator factory.
    @MainActor public struct CameraSessionConnections {
        public let makeRuntime: @MainActor () throws -> CameraRuntimeDependencies

        public let connectPerception:
            @MainActor (
                String, Bool, any CameraOutputHandling
            ) async throws -> Void
        public init(

            makeRuntime: @escaping @MainActor () throws -> CameraRuntimeDependencies,
            connectPerception:
                @escaping @MainActor (
                    String, Bool, any CameraOutputHandling
                ) async throws -> Void
        ) {
            self.makeRuntime = makeRuntime
            self.connectPerception = connectPerception
        }
    }

#endif

#if os(iOS)
    import ExecutionRuntime
    import FunctionContracts
    import Foundation
    import PlatformKit

    /// Camera resource access over the Actions-owned execution engine.
    struct CameraResourceBinding: CameraResourceAccess {
        let engine: ActionExecutionCoordinator
        func acquire(resources requested: Set<ResourceID>, owner: ExecutionOwner, duration: Duration) async throws
            -> ResourceLease
        {
            try await engine.acquireLease(resources: requested, owner: owner, duration: duration)
        }
        func run(
            resources requested: Set<ResourceID>, owner: ExecutionOwner, lease: ResourceLease,
            operation: @escaping @Sendable () async throws -> MediaSignalListener<CameraFrame>
        ) async throws -> MediaSignalListener<CameraFrame> {
            try await engine.resources.run(resources: requested, owner: owner, lease: lease, operation: operation)
        }
        func renew(_ lease: ResourceLease, owner: ExecutionOwner, duration: Duration) async throws -> ResourceLease {
            try await engine.renewLease(lease, owner: owner, duration: duration)
        }
        func release(_ lease: ResourceLease, owner: ExecutionOwner) async throws {
            do { try await engine.releaseLease(lease, owner: owner) } catch ResourceError.staleLease {
                throw CameraResourceFailure.staleLease
            }
        }
        func isSettled(_ resource: ResourceID) async -> Bool {
            await engine.resources.isSettled(resource)
        }
    }
#endif

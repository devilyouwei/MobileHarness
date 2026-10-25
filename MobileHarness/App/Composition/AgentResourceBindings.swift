import Actions

#if os(iOS)

    import FunctionContracts
    import AgentCore
    import Foundation
    import Gateway
    import PlatformKit

    struct CameraResourceBinding: CameraResourceAccess {
        let resources: ResourceCoordinator
        let actions: ChannelScheduler
        func acquire(resources requested: Set<ResourceID>, owner: ExecutionOwner, duration: Duration) async throws
            -> ResourceLease
        {
            try await resources.acquire(resources: requested, owner: owner, duration: duration) { [actions] in
                await actions.cancel(resources: $0)
            }
        }
        func run(
            resources requested: Set<ResourceID>, owner: ExecutionOwner, lease: ResourceLease,
            operation: @escaping @Sendable () async throws -> AsyncThrowingStream<CameraFrame, Error>
        ) async throws -> AsyncThrowingStream<CameraFrame, Error> {
            try await resources.run(resources: requested, owner: owner, lease: lease, operation: operation)
        }
        func renew(_ lease: ResourceLease, owner: ExecutionOwner, duration: Duration) async throws -> ResourceLease {
            try await resources.renew(lease, owner: owner, duration: duration)
        }
        func release(_ lease: ResourceLease, owner: ExecutionOwner) async throws {
            do { try await resources.release(lease, owner: owner) } catch ResourceError.staleLease {
                throw CameraResourceFailure.staleLease
            }
        }
        func isReleased(_ resource: ResourceID) async -> Bool {
            let current = await resources.snapshot()[resource]
            if current == .unlocked { return true }
            if case .locked(let owner?) = current {
                return await resources.lease(for: owner, resources: [resource]) != nil
            }
            return false
        }
    }
#endif

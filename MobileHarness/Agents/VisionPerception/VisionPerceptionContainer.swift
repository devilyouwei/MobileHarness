import Foundation
import FunctionContracts

#if os(iOS)
    import ModelKit
    import PlatformKit
#endif

/// Stable owner for one replaceable capture-generation role and its joined output work.
@MainActor
public final class VisionPerceptionContainer {
    private var work: Task<Void, any Error>?
    private var closed = false

    init() {}

    public func stateSnapshot() async throws -> AgentStateSnapshot {
        try Task.checkCancellation()
        return AgentStateSnapshot(
            path: "agents.visionperception",
            runtime: ["working": .flag(work != nil), "closed": .flag(closed), "installed": .flag(work != nil)])
    }

    #if os(iOS)
        @available(iOS 27, *)
        func run(
            runtime: AgentRuntime, pose: any PoseCapability, camera: any CameraFrameObserving,
            sessionID: String, mirrored: Bool, status: @escaping @MainActor @Sendable (String?, String) -> Void
        ) async throws {
            try await run {
                try await VisionAgentSession(runtime: runtime, pose: pose, camera: camera)
                    .run(sessionID: sessionID, mirrored: mirrored, status: status)
            }
        }
    #endif

    func run(_ session: @escaping @MainActor @Sendable () async throws -> Void) async throws {
        guard !closed else { throw AgentContainerError.stopped }
        guard work == nil else { throw AgentContainerError.busy }
        try Task.checkCancellation()
        // Capture outlives the request that enabled it. Its Tools start an independent request chain.
        let task = Task.detached(priority: Task.currentPriority) {
            try Task.checkCancellation()
            try await session()
        }
        work = task
        defer { work = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func invalidate() { work?.cancel() }

    func suspend() async throws {
        let pending = work
        pending?.cancel()
        do { try await pending?.value } catch is CancellationError {} catch { throw error }
    }

    func stop() async throws {
        closed = true
        try await suspend()
    }
}

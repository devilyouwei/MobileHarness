#if os(iOS)
    import FunctionContracts
    import Foundation
    import ModelKit
    import PlatformKit

    /// Stable owner for one replaceable capture-generation role and its joined output work.
    @available(iOS 27, *)
    @MainActor
    public final class VisionPerceptionContainer {
        public func stateSnapshot() async throws -> AgentStateSnapshot {
            try Task.checkCancellation()
            return AgentStateSnapshot(
                path: "agents.visionperception",
                runtime: ["working": .flag(work != nil), "closed": .flag(closed), "installed": .flag(work != nil)])
        }

        private var work: Task<Void, any Error>?
        private var closed = false
        init() {}
        func run(
            runtime: AgentRuntime, pose: any PoseCapability, camera: any CameraFrameObserving,
            sessionID: String, mirrored: Bool, status: @escaping @MainActor @Sendable (String?, String) -> Void
        ) async throws {
            guard !closed else { throw AgentContainerError.stopped }
            guard work == nil else { throw AgentContainerError.busy }
            let task = Task {
                try await VisionAgentSession(runtime: runtime, pose: pose, camera: camera)
                    .run(sessionID: sessionID, mirrored: mirrored, status: status)
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
#endif

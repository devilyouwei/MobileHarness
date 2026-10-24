#if os(iOS)
    import Actions
    import Foundation
    import ModelKit
    import PlatformKit

    /// Stable owner for one replaceable capture-generation role and its joined output work.
    @available(iOS 27, *)
    @MainActor
    public final class VisionPerceptionContainer {
        private var work: Task<Void, any Error>?
        private var closed = false
        init() {}
        func run(
            runtime: AgentRuntime, pose: any PoseCapability, camera: any CameraFrameObserving,
            sessionID: String, mirrored: Bool, endpoint: any CameraOutputHandling
        ) async throws {
            guard !closed else { throw AgentContainerError.stopped }
            guard work == nil else { throw AgentContainerError.busy }
            let task = Task {
                try await VisionAgentSession(runtime: runtime, pose: pose, camera: camera)
                    .run(sessionID: sessionID, mirrored: mirrored, endpoint: endpoint)
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

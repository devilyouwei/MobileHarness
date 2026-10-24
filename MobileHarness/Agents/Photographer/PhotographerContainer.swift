#if os(iOS)
    import Foundation
    import Observation
    import UI
    import Actions

    @available(iOS 27, *)
    @MainActor @Observable
    public final class PhotographerContainer {
        @ObservationIgnored private var session: PhotographerExecutionSession?
        @ObservationIgnored private var closed = false
        private let cameraUI: UICameraContainer
        private let cameraPresentation: any CameraPresenting
        init(camera: UICameraContainer, presentation: any CameraPresenting) {
            cameraUI = camera
            cameraPresentation = presentation
        }
        public var cameraState: CameraState { cameraUI.state }

        func setInputAvailable(_ value: Bool) { cameraUI.requests.setAvailable(value) }
        func install(_ session: PhotographerExecutionSession) throws {
            guard !closed else { throw AgentContainerError.stopped }
            guard self.session == nil else { throw AgentContainerError.busy }
            self.session = session
        }
        func start() async throws {
            guard !closed else { throw AgentContainerError.stopped }
            guard let session else { throw AgentContainerError.unavailable }
            try await session.prepareForInteraction()
        }
        func setForeground(_ value: Bool) async throws {
            guard !closed else { throw AgentContainerError.stopped }
            guard let session else { return }
            let state = await session.agent.status().lifecycle
            if value, state == .paused { try await session.agent.resume() }
            if !value, state == .running { try await session.agent.pause() }
        }
        func stop() async throws {
            closed = true
            await session?.shutdown()
            if let failure = await session?.cleanupFailure { throw failure }
        }
        @ObservationIgnored public lazy var cameraControls = makeCameraControls()
        private func makeCameraControls() -> CameraInteractionWorkflow {
            CameraInteractionWorkflow(
                presentation: cameraPresentation,
                perform: { [cameraUI] operation, facing, mediaID in
                    guard let operation = CameraInput.Operation(rawValue: operation.rawValue) else {
                        throw UIRequestError.stale
                    }
                    _ = try await cameraUI.requests.submit(
                        CameraInput(operation, facing: facing.map { $0 == .front ? .front : .back }, mediaID: mediaID))
                })
        }
    }
#endif

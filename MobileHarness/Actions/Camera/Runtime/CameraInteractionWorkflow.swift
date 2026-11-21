import Foundation
import StorageCore
import UI

/// Root-owned single camera-command slot; native capture lifetime remains independent of UI pages.
@MainActor public final class CameraInteractionWorkflow: CameraControlling {
    private let presentation: any CameraPresenting
    private var state: CameraPresentationSnapshot { presentation.snapshot }
    private let readPreview: (String, String) async throws -> Data
    private let perform: (CameraInput) async throws -> Void
    private var worker: Task<Void, Never>?
    private var stopped = false
    private var cancelledCountdown = false
    public init(
        presentation: any CameraPresenting,
        readPreview: @escaping (String, String) async throws -> Data = { _, _ in throw UIRequestError.unavailable },
        perform:
            @escaping (CameraInput) async throws ->
            Void
    ) {
        self.readPreview = readPreview
        self.presentation = presentation
        self.perform = perform
    }
    public func previewImage(_ id: String, session: String) async throws -> Data { try await readPreview(id, session) }
    public func configure(_ settings: CameraSettings) { submit(.configure, settings: settings) }
    public func cancelCapture() {
        guard state.countdown != nil else { return }
        if let worker {
            cancelledCountdown = true
            worker.cancel()
        } else {
            submit(.cancelCapture)
        }
    }
    public func startRecording() { submit(.startRecording) }
    public func stopRecording() {
        guard let id = state.recording.id else { return }
        submit(.stopRecording, recordingID: id)
    }
    public func saveVideo(_ id: String) { submit(.saveVideo, recordingID: id) }
    public func ignoreVideo(_ id: String) { submit(.ignoreVideo, recordingID: id) }
    public func takePhoto() { submit(.takePhoto) }
    public func open() { submit(.open) }
    public func toggle() { submit(state.isEnabled ? .close : .open) }
    public func switchCamera() { submit(.flip, facing: state.facing == .front ? .back : .front) }
    public func retry() { submit(.retry) }
    public func togglePerception() { submit(state.perceptionEnabled ? .perceptionClose : .perceptionOpen) }
    public func retryPerception() { submit(.perceptionRetry) }
    public func switchPerceptionCamera() { submit(.perceptionFlip, facing: state.facing == .front ? .back : .front) }
    public func savePhoto(_ id: String) { submitPhoto(.savePhoto, id: id) }
    private func submitPhoto(_ operation: CameraInput.Operation, id: String) {
        guard let previewID = PreviewImageID(rawValue: id) else {
            presentation.present(.photoMessage("Invalid photo reference"))
            return
        }
        submit(operation, previewID: previewID.rawValue)
    }
    public func shutdown() async {
        stopped = true
        worker?.cancel()
        await worker?.value
    }
    public func waitUntilIdle() async { await worker?.value }
    private func submit(
        _ operation: CameraInput.Operation, facing: CameraDirection? = nil,
        previewID: String? = nil, settings: CameraSettings? = nil, recordingID: String? = nil
    ) {
        guard !stopped else { return }
        guard worker == nil else {
            if previewID != nil {
                presentation.present(.photoMessage("A photo operation is in progress. Try again."))
            } else {
                presentation.present(.controlMessage("A camera operation is in progress. Try again."))
            }
            return
        }
        presentation.present(.controlMessage(nil))
        presentation.present(.controlBusy(true))
        let previewSession = state.gallerySession
        worker = Task {
            defer {
                worker = nil
                cancelledCountdown = false
                presentation.present(.controlBusy(false))
                presentation.present(.controlMessage(nil))
            }
            do {
                try await perform(
                    CameraInput(
                        operation, facing: facing, previewID: previewID, settings: settings, recordingID: recordingID,
                        previewSession: previewSession))
            } catch {
                if cancelledCountdown && error is CancellationError {
                    presentation.present(.photoMessage("Countdown cancelled"))
                    return
                }
                let message = Self.message(for: error)
                if operation == .savePhoto, let previewID, state.savedPreviewID == previewID {
                    presentation.present(.photoMessage("Saved in the app album. A follow-up step failed."))
                } else if previewID != nil {
                    presentation.present(.photoMessage("Photo operation failed. Try again."))
                } else {
                    presentation.present(
                        .message(error is UIRequestError ? message : "Camera operation failed. Try again."))
                }
            }
        }
    }
    private static func message(for error: any Error) -> String {
        if error is CancellationError { return "Operation cancelled. Try again." }
        guard let request = error as? UIRequestError else { return error.localizedDescription }
        switch request {
        case .unavailable, .stale, .consumerEnded: return "The app changed state and ended the request. Try again."
        case .capacityExceeded: return "Too many requests. Try again."
        case .duplicateConsumer: return "Camera controls failed. Restart the app."
        }
    }
}

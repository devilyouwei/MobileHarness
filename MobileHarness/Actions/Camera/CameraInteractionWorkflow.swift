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
    public func ignorePhoto(_ id: String) { submitPhoto(.ignorePhoto, id: id) }
    private func submitPhoto(_ operation: CameraInput.Operation, id: String) {
        guard let previewID = PreviewImageID(rawValue: id) else {
            presentation.present(.photoMessage("照片引用无效"))
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
                presentation.present(.photoMessage("照片操作正在执行，请稍后重试"))
            } else {
                presentation.present(.controlMessage("相机操作正在执行，请稍后重试"))
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
                    presentation.present(.photoMessage("已取消倒计时"))
                    return
                }
                let message = Self.message(for: error)
                if operation == .savePhoto, let previewID, state.savedPreviewID == previewID {
                    presentation.present(.photoMessage("已保存到 App 相册，后续请求未完成：" + message))
                } else if previewID != nil {
                    presentation.present(.photoMessage("照片操作失败：" + message))
                } else {
                    presentation.present(.message("相机操作失败：" + message))
                }
            }
        }
    }
    private static func message(for error: any Error) -> String {
        if error is CancellationError { return "操作已取消，请重试" }
        guard let request = error as? UIRequestError else { return error.localizedDescription }
        switch request {
        case .unavailable, .stale, .consumerEnded: return "请求因应用状态变化结束，请重试"
        case .capacityExceeded: return "请求过多，请稍后重试"
        case .duplicateConsumer: return "相机请求通道异常，请重新启动应用"
        }
    }
}

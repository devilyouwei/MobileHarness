import Foundation
import StorageCore
import UI

/// Root-owned single camera-command slot; native capture lifetime remains independent of UI pages.
@MainActor public final class CameraInteractionWorkflow: CameraControlling {
    private let presentation: any CameraPresenting
    private var state: CameraPresentationSnapshot { presentation.snapshot }
    private let perform: (CameraInput.Operation, CameraDirection?, String?) async throws -> Void
    private var worker: Task<Void, Never>?
    private var stopped = false
    public init(
        presentation: any CameraPresenting,
        perform:
            @escaping (CameraInput.Operation, CameraDirection?, String?) async throws ->
            Void
    ) {
        self.presentation = presentation
        self.perform = perform
    }
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
        guard let mediaID = BusinessRecordID(rawValue: id), mediaID.kind == .media else {
            presentation.present(.photoMessage("照片引用无效"))
            return
        }
        submit(operation, mediaID: mediaID.rawValue)
    }
    public func shutdown() async {
        stopped = true
        worker?.cancel()
        await worker?.value
    }
    public func waitUntilIdle() async { await worker?.value }
    private func submit(
        _ operation: CameraInput.Operation, facing: CameraDirection? = nil,
        mediaID: String? = nil
    ) {
        guard !stopped else { return }
        guard worker == nil else {
            if mediaID != nil {
                presentation.present(.photoMessage("照片操作正在执行，请稍后重试"))
            } else {
                presentation.present(.controlMessage("相机操作正在执行，请稍后重试"))
            }
            return
        }
        presentation.present(.controlMessage(nil))
        presentation.present(.controlBusy(true))
        worker = Task {
            defer {
                worker = nil
                presentation.present(.controlBusy(false))
                presentation.present(.controlMessage(nil))
            }
            do { try await perform(operation, facing, mediaID) } catch {
                let message = Self.message(for: error)
                if operation == .savePhoto, let mediaID, state.savedMediaID == mediaID {
                    presentation.present(.photoMessage("已保存到 App 相册，后续请求未完成：" + message))
                } else if mediaID != nil {
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

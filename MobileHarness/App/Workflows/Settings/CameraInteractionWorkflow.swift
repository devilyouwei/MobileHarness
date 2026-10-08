import Agents
import Foundation
import UI

/// Root-owned single camera-command slot; native capture lifetime remains independent of UI pages.
@MainActor public final class CameraInteractionWorkflow: CameraControlling {
    private let state: CameraState
    private let perform:
        (PhotographerCameraIntent.Operation, PhotographerCameraIntent.Facing?, UUID?) async throws -> Void
    private var worker: Task<Void, Never>?
    public init(
        state: CameraState,
        perform:
            @escaping (PhotographerCameraIntent.Operation, PhotographerCameraIntent.Facing?, UUID?) async throws -> Void
    ) {
        self.state = state
        self.perform = perform
    }
    public func toggle() { submit(state.isEnabled ? .close : .open) }
    public func switchCamera() { submit(.flip, facing: state.facing == .front ? .back : .front) }
    public func retry() { submit(.retry) }
    public func savePhoto(_ id: UUID) { submit(.savePhoto, photoID: id) }
    public func ignorePhoto(_ id: UUID) { submit(.ignorePhoto, photoID: id) }
    public func waitUntilIdle() async { await worker?.value }
    private func submit(
        _ operation: PhotographerCameraIntent.Operation, facing: PhotographerCameraIntent.Facing? = nil,
        photoID: UUID? = nil
    ) {
        guard worker == nil else {
            if photoID != nil {
                state.photoMessage = "照片操作正在执行，请稍后重试"
            } else {
                state.message = "相机操作正在执行，请稍后重试"
            }
            return
        }
        worker = Task {
            defer { worker = nil }
            do { try await perform(operation, facing, photoID) } catch {
                if operation == .savePhoto, let photoID, state.savedPhotoID == photoID {
                    state.photoMessage = "已保存到相册，后续请求未完成：" + error.localizedDescription
                } else if photoID != nil {
                    state.photoMessage = "照片操作失败：" + error.localizedDescription
                } else {
                    state.message = "相机操作失败：" + error.localizedDescription
                }
            }
        }
    }
}

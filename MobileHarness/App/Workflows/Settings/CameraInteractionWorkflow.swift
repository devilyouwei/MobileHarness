import Agents
import Foundation
import UI

/// Root-owned single camera-command slot; native capture lifetime remains independent of UI pages.
@MainActor public final class CameraInteractionWorkflow: CameraControlling {
    private let state: CameraState
    private let perform: (PhotographerCameraIntent.Operation) async throws -> Void
    private var worker: Task<Void, Never>?
    public init(state: CameraState, perform: @escaping (PhotographerCameraIntent.Operation) async throws -> Void) {
        self.state = state
        self.perform = perform
    }
    public func toggle() { submit(state.isEnabled ? .close : .open) }
    public func switchCamera() { submit(.flip) }
    public func retry() { submit(.retry) }
    public func waitUntilIdle() async { await worker?.value }
    private func submit(_ operation: PhotographerCameraIntent.Operation) {
        guard worker == nil else {
            state.message = "相机操作正在执行，请稍后重试"
            return
        }
        worker = Task {
            defer { worker = nil }
            do { try await perform(operation) } catch {
                state.message = "相机操作失败：" + error.localizedDescription
            }
        }
    }
}

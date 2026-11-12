import Actions
import Agents
import Foundation
import FunctionContracts
import StorageCache
import UI

@MainActor @available(iOS 27, *)
final class AppCameraAccess: AgentCameraAccess {
    let value: any ActionsCameraAccess
    init(_ value: any ActionsCameraAccess) { self.value = value }
    func previewSnapshot(scope: String) async throws -> MultimodalContextSnapshot {
        try await value.previewSnapshot(scope: scope)
    }
    func resetPreviewSelection(scope: String) async { await value.resetPreviewSelection(scope: scope) }
    func pauseVisionForModelMaintenance() async { await value.pauseVisionForModelMaintenance() }
}
@MainActor final class AppDeviceAccess: AgentDeviceAccess {
    let value: any ActionsDeviceAccess
    init(_ value: any ActionsDeviceAccess) { self.value = value }
    func openPage() { value.openPage() }
    func closePage() { value.closePage() }
    func openSystemSettings() { value.openSystemSettings() }
    var initialFence: String { value.initialFence }
    func stopFence() -> String { value.stopFence() }
}
@MainActor @available(iOS 27, *)
final class AppVoiceLifecycle: AgentVoiceLifecycle {
    let value: VoiceSessionCoordinator
    init(value: VoiceSessionCoordinator) { self.value = value }
    func start(perception: any VoicePerceptionHandling, audioStore: AudioCache) async throws {
        try await value.start(perception: perception, audioStore: audioStore)
    }
    func shutdown() async { await value.shutdown() }
    func beginSettingsChange() async { await value.beginSettingsChange() }
    func endSettingsChange() { value.endSettingsChange() }
    func stopVoiceAndWait() async { await value.stopVoiceAndWait() }
    func stopVoice(message: String) { value.stopVoice(message: message) }
}
@MainActor final class AppDetectionControl: AgentDetectionControl {
    let value: AudioDetectionPresentation
    init(value: AudioDetectionPresentation) { self.value = value }
    func stopAndWait() async { await value.stopAndWait() }
}

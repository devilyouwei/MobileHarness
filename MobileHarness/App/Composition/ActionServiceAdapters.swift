import Actions
import Agents
import Foundation
import FunctionContracts
import StorageCache
import UI

@MainActor @available(iOS 27, *)
final class AppCameraAccess: AgentCameraAccess {
    let business: ActionsBusinessAssembly
    var value: CameraCoordinator { business.camera }
    init(_ business: ActionsBusinessAssembly) { self.business = business }
    func setForeground(_ active: Bool) { value.setForeground(active) }
    func pauseVisionForModelMaintenance() async { await value.pauseVisionForModelMaintenance() }
    func shutdown() async throws { try await value.shutdown() }
    func readPhoto(_ id: String, source: String, sessionID: String, inputID: String) async throws -> Data {
        try await value.readPhoto(id, source: source, sessionID: sessionID, inputID: inputID)
    }
}
@MainActor final class AppDeviceAccess: AgentDeviceAccess {
    let business: ActionsBusinessAssembly
    var value: BluetoothWorkflow { business.bluetooth }
    var device: NexArmDeviceAdapter { business.device }
    init(_ business: ActionsBusinessAssembly) { self.business = business }
    func setForeground(_ active: Bool) { value.setForeground(active) }
    func waitUntilIdle() async { await value.waitUntilIdle() }
    func openPage() { value.openPage() }
    func closePage() { value.closePage() }
    func openSystemSettings() { value.openSystemSettings() }
    var initialFence: String { device.fence }
    func stopFence() -> String { device.stopFence() }
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

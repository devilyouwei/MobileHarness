import Agents
import AppWorkflows
import Foundation
import ModelKit
import ModelKitDefaults
import Observation
import PlatformKit
import Storage
import UI

/// The scene's composition root. Runtime services are lazy but never discovered by consumers.
@MainActor @Observable
final class AppAssembly {
    private(set) var container: AppContainer?
    @ObservationIgnored private var runtimeValue: ApplicationRuntime?
    @ObservationIgnored private let cameraDevice = AppleCamera()
    @ObservationIgnored private let resources = Bundle.main.bundleURL.appendingPathComponent("Models")
    @ObservationIgnored private lazy var settingsWorkflow = SettingsWorkflow(
        provider: SettingsProviderAdapter.operations(resources: resources),
        beginChange: { [weak self] in await self?.container?.lifecycle.beginSettingsChange() },
        endChange: { [weak self] in self?.container?.lifecycle.endSettingsChange() })
    @ObservationIgnored lazy var settings = SettingsState(
        operations: settingsWorkflow, initial: SettingsProviderAdapter.initial)
    @ObservationIgnored lazy var bluetooth = BluetoothWorkflow(
        state: BluetoothSettingsState(), link: NexArmBluetooth(),
        quiesce: { [weak self] in
            await self?.container?.lifecycle.beginSettingsChange()
            self?.container?.lifecycle.endSettingsChange()
        },
        makeStore: {
            let root = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            return try LocalDocumentStore<BluetoothDeviceRecord>(
                url: root.appendingPathComponent("MobileHarness/Bluetooth/device.json"), maximumBytes: 4096)
        })
    @ObservationIgnored lazy var camera = makeCamera()
    private func makeCamera() -> CameraCoordinator {
        let device = cameraDevice
        return CameraCoordinator(
            camera: device, state: CameraState(),
            makeRuntime: { [weak self] in
                guard let self else { throw CancellationError() }
                return try self.runtime().cameraDependencies
            },
            makeSession: { [weak self] in
                guard let self else { throw CancellationError() }
                let models = try await ModelKitDefaults.manager(resources: self.resources)
                let pose = try await models.get(.pose, load: false)
                return try VisionSession(runtime: self.runtime().visionDependencies) {
                    sessionID, configuration, mirroredGaze in
                    try VisionPerceptionAgent(
                        pose: pose, sessionID: sessionID, sampling: configuration, mirroredGaze: mirroredGaze,
                        resolveImage: CameraImageAttachment.resolve)
                }
            })
    }
    @ObservationIgnored lazy var history = makeHistory()
    private func makeHistory() -> ConversationHistoryWorkflow {
        ConversationHistoryWorkflow(
            state: ConversationHistoryState(),
            loadStore: { [weak self] in
                guard let self else { throw CancellationError() }
                await self.container?.lifecycle.beginSettingsChange()
                defer { self.container?.lifecycle.endSettingsChange() }
                try Task.checkCancellation()
                return try self.runtime().conversations
            },
            summarizeTitle: { [weak self] conversation in
                guard let self else { throw CancellationError() }
                let chat = try await self.makeHistoryChat()
                try Task.checkCancellation()
                return try await ConversationTitleGenerator.summarize(conversation, using: chat)
            }, previewOutput: HistoryAgentAdapter.preview)
    }
    private func makeHistoryChat() async throws -> any ChatCapability {
        try await settings.restore()
        await container?.lifecycle.beginSettingsChange()
        defer { container?.lifecycle.endSettingsChange() }
        try Task.checkCancellation()
        let models = try await ModelKitDefaults.manager(resources: resources)
        return CurrentChatCapability(models: models)
    }
    private func runtime() throws -> ApplicationRuntime {
        if let runtimeValue { return runtimeValue }
        let runtime = try ApplicationRuntime(camera: cameraDevice, cameraControl: camera, bluetooth: bluetooth)
        runtimeValue = runtime
        return runtime
    }
    func prepare(progress: @MainActor (String) -> Void) async throws {
        guard container == nil else { return }
        try await settings.restore()
        let workflow = settingsWorkflow
        let prepared = try await AppContainer(
            resources: resources, runtime: runtime(), modelName: { await workflow.modelName }, progress: progress)
        try Task.checkCancellation()
        container = prepared
    }
}

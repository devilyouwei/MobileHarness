import Agents
import AppWorkflows
import Foundation
import ModelKit
import ModelKitDefaults
import ModelKitHub
import ModelKitRuntime
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
    @ObservationIgnored private let resources = URL.applicationSupportDirectory.appendingPathComponent(
        "MobileHarness/Models/installed")
    @ObservationIgnored private var speechPreference: [Bool]?
    @ObservationIgnored private var artifactAssembly: Task<ModelManager, Error>?
    private func artifactManager() async throws -> ModelManager {
        if let artifactAssembly { return try await artifactAssembly.value }
        let resources = self.resources
        let task = Task {
            let catalog = try ModelArtifactCatalog.read(
                Bundle.main.bundleURL.appendingPathComponent("Models/model-catalog.json"))
            let storage = try ModelArtifactStorageAdapter(root: resources.deletingLastPathComponent())
            let manager = try await ModelKitDefaults.configureArtifacts(
                resources: resources, catalog: catalog, storage: storage, downloader: HuggingFaceArtifactDownloader())
            _ = try await manager.artifactSnapshots()
            return manager
        }
        artifactAssembly = task
        return try await task.value
    }
    @ObservationIgnored private lazy var modelResourcesWorkflow = makeModelResourcesWorkflow()
    private func makeModelResourcesWorkflow() -> ModelResourcesWorkflow {
        ModelResourcesWorkflow(
            store: {
                try LocalDocumentStore<ModelResourceSourceDraft>(
                    url: URL.applicationSupportDirectory.appendingPathComponent(
                        "MobileHarness/Models/download-source.json"), maximumBytes: 4096)
            },
            read: { [weak self] in
                guard let self else { throw CancellationError() }
                let manager = try await self.artifactManager()
                return try await SettingsModelResourcesAdapter.items(manager)
            }, validate: SettingsModelResourcesAdapter.validate,
            download: { [weak self] id, draft in
                guard let self else { throw CancellationError() }
                let manager = try await self.artifactManager()
                try await manager.downloadArtifact(
                    id, source: ModelDownloadSource(endpoint: draft.endpoint, allowsCellular: draft.allowsCellular))
            },
            cancel: { [weak self] id in
                guard let self else { throw CancellationError() }
                let manager = try await self.artifactManager()
                try await manager.cancelArtifact(id)
            },
            remove: { [weak self] id in
                guard let self else { throw CancellationError() }
                let manager = try await self.artifactManager()
                try await manager.removeArtifact(id) { [weak self] in
                    await self?.quiesceForModelRemoval(id)
                }
            },
            apply: { [weak self] draft in
                let preference = [draft.useCustomRecognition, draft.useCustomSynthesis]
                guard let self, self.speechPreference != preference else { return }
                await self.container?.lifecycle.beginSettingsChange()
                await ModelKitDefaults.configureSpeech(
                    recognition: draft.useCustomRecognition, synthesis: draft.useCustomSynthesis)
                self.speechPreference = preference
                self.container?.lifecycle.endSettingsChange()
            })
    }
    @ObservationIgnored lazy var modelResources = ModelResourcesState(operations: modelResourcesWorkflow)
    private func quiesceForModelRemoval(_ id: String) async {
        if id == "yolo26n-pose" {
            await camera.pauseVisionForModelMaintenance()
        } else {
            await container?.lifecycle.beginSettingsChange()
            container?.lifecycle.endSettingsChange()
        }
    }
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
                        pose: pose, sessionID: sessionID, sampling: configuration, mirroredGaze: mirroredGaze)
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
        _ = try await artifactManager()
        _ = try await modelResourcesWorkflow.restoreSource()
        try await settings.restore()
        let workflow = settingsWorkflow
        let prepared = try await AppContainer(
            resources: resources, runtime: runtime(), modelName: { await workflow.modelName }, progress: progress)
        try Task.checkCancellation()
        container = prepared
    }
}

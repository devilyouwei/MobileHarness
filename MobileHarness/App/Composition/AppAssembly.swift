import Actions
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
    @ObservationIgnored private var environmentSequence: UInt64 = 0
    @ObservationIgnored private var pendingEnvironment: [AppEnvironmentFact.Category: AppEnvironmentFact] = [:]
    @ObservationIgnored private var environmentWorker: Task<Void, Never>?
    @ObservationIgnored private var environmentSample = ""
    private(set) var environmentFailure: String?
    @ObservationIgnored private lazy var environmentObservation = makeEnvironmentObservation()
    private func makeEnvironmentObservation() -> ResourceObservationWorkflow {
        ResourceObservationWorkflow(
            read: { [weak self] in
                guard let self else { throw CancellationError() }
                let device = try self.deviceControl.readStatus()
                let data = try JSONSerialization.data(
                    withJSONObject: [
                        "bluetooth": device, "cameraEnabled": self.camera.state.isEnabled,
                        "cameraVisible": self.camera.state.isVisible,
                        "cameraNeedsSettings": self.camera.state.needsSettings,
                    ], options: [.sortedKeys])
                let value = String(decoding: data, as: UTF8.self)
                guard data.count <= 16_384 else { throw DeviceControlError.invalidRequest }
                self.environmentSample = value
                return value
            },
            deliver: { [weak self] sample, _ in
                guard let self else { throw CancellationError() }
                switch sample {
                case .changed:
                    self.environmentSequence += 1
                    try await self.runtime().applicationControlIntents.observeEnvironment(
                        .init(category: .devices, sequence: self.environmentSequence, value: self.environmentSample))
                    return .accepted
                case .failed(let message): return .retry(message)
                }
            }, invalidate: {}, report: { [weak self] message in self?.recordEnvironmentFailure(message) })
    }

    func reportEnvironment(_ category: AppEnvironmentFact.Category, value: String) {
        guard value.utf8.count <= 16_384 else {
            recordEnvironmentFailure("Environment fact exceeds bound")
            return
        }
        environmentSequence += 1
        pendingEnvironment[category] = .init(category: category, sequence: environmentSequence, value: value)
        guard environmentWorker == nil else { return }
        environmentWorker = Task {
            defer { environmentWorker = nil }
            while let fact = pendingEnvironment.values.min(by: { $0.sequence < $1.sequence }) {
                pendingEnvironment[fact.category] = nil
                do {
                    try await runtime().applicationControlIntents.observeEnvironment(fact)
                    environmentFailure = nil
                } catch { recordEnvironmentFailure(error.localizedDescription) }
            }
        }
    }
    private func recordEnvironmentFailure(_ message: String) {
        environmentFailure = String(message.prefix(512))
        runtimeValue?.actionActivity.recordFailure(
            title: "环境信息提交失败", source: AppEnvironmentFact.source, message: environmentFailure ?? "",
            failureCode: "environment.delivery")
    }
    @ObservationIgnored private var resourceObservationForeground = false
    @ObservationIgnored private let cameraDevice = AppleCamera()
    @ObservationIgnored private let resources = URL.applicationSupportDirectory.appendingPathComponent(
        "MobileHarness/Models/installed")
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
            read: { [weak self] generation in
                guard let self else { throw CancellationError() }
                let intents = try await self.runtime().applicationControlIntents
                let raw: String
                if let generation {
                    raw = try await intents.presentInventory(generation: generation)
                } else {
                    raw = try await intents.inventory()
                }
                return try SettingsModelResourcesAdapter.items(raw)
            },
            restore: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.resourcePreference(.restoreSource)
            },
            save: { [weak self] draft in
                guard let self else { throw CancellationError() }
                return try await self.resourcePreference(
                    .saveSource(
                        endpoint: draft.endpoint,
                        allowsCellular: draft.allowsCellular, recognition: draft.useCustomRecognition,
                        synthesis: draft.useCustomSynthesis))
            },
            download: { [weak self] id, draft in
                guard let self else { throw CancellationError() }
                try await self.runtime().applicationControlIntents.perform(
                    .download(id: id, endpoint: draft.endpoint, allowsCellular: draft.allowsCellular))
            },
            cancel: { [weak self] id in
                guard let self else { throw CancellationError() }
                try await self.runtime().applicationControlIntents.perform(.cancel(id))
            },
            remove: { [weak self] id in
                guard let self else { throw CancellationError() }
                try await self.runtime().applicationControlIntents.perform(.remove(id))
            })
    }
    private func resourcePreference(_ intent: ModelResourceIntent) async throws -> ModelResourceSourceDraft {
        do {
            let value = try await runtime().applicationControlIntents.preferences(intent)
            return try JSONDecoder().decode(ModelResourceSourceDraft.self, from: Data(value.utf8))
        } catch ApplicationControlIntentFailure.execution(let message) {
            throw SettingsModelResourcesAdapter.preferenceFailure(message)
        }
    }
    let modelResources = ModelResourcesState()
    @ObservationIgnored lazy var modelResourceControls = ModelResourceInteractionWorkflow(
        state: modelResources, operations: modelResourcesWorkflow)
    private func quiesceForModelRemoval(_ id: String) async {
        if id == "yolo26n-pose" {
            await camera.pauseVisionForModelMaintenance()
        } else {
            await container?.lifecycle.beginSettingsChange()
            container?.lifecycle.endSettingsChange()
        }
    }
    @ObservationIgnored private lazy var settingsWorkflow = SettingsWorkflow(
        provider: SettingsProviderAdapter.operations(
            restore: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.runtime().restoreProvider()
            },
            discover: { [weak self] draft in
                guard let self else { throw CancellationError() }
                return try await self.runtime().discoverProvider(draft)
            },
            save: { [weak self] draft in
                guard let self else { throw CancellationError() }
                try await self.runtime().saveProvider(draft)
            }), presentsResults: true)
    @ObservationIgnored lazy var settings = SettingsState(initial: SettingsProviderAdapter.initial)
    @ObservationIgnored lazy var settingsControls = SettingsInteractionWorkflow(
        state: settings, operations: settingsWorkflow, defaultModel: SettingsProviderAdapter.initial.model)
    @ObservationIgnored lazy var cameraControls = makeCameraControls()
    private func makeCameraControls() -> CameraInteractionWorkflow {
        CameraInteractionWorkflow(
            state: camera.state,
            perform: { [weak self] intent, facing, photoID in
                guard let self else { throw CancellationError() }
                _ = try await self.runtime().photographerIntents.perform(intent, facing: facing, photoID: photoID)
            })
    }
    let navigation = NavigationState()
    @ObservationIgnored lazy var deviceControl = DeviceControlAdapter(bluetooth: bluetooth)
    @ObservationIgnored lazy var bluetoothControls = makeBluetoothControls()
    private func makeBluetoothControls() -> BluetoothInteractionWorkflow {
        BluetoothInteractionWorkflow(
            state: bluetooth.state,
            initialFence: deviceControl.fence, fenceStop: { [deviceControl] in deviceControl.stopFence() },
            perform: { [weak self] intent in
                guard let self else { throw CancellationError() }
                try await self.runtime().applicationControlIntents.interact(intent)
            })
    }

    func navigate(_ destination: AppDestination?) async {
        do {
            try await runtime().applicationControlIntents.interact(
                .init(kind: .navigation, parameters: ["destination": destination?.rawValue ?? "home"]))
        } catch { bluetooth.state.error = "无法打开页面：" + error.localizedDescription }
    }
    @ObservationIgnored lazy var bluetooth = BluetoothWorkflow(
        state: BluetoothSettingsState(), link: NexArmBluetooth(),
        makeStore: {
            let root = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            return try LocalDocumentStore<BluetoothDeviceRecord>(
                url: root.appendingPathComponent("MobileHarness/Bluetooth/device.json"), maximumBytes: 4096)
        })
    @ObservationIgnored private let capturedPhotos = CapturedPhotoStore(
        root: URL.applicationSupportDirectory.appendingPathComponent("MobileHarness/CapturedPhotos", isDirectory: true))
    @ObservationIgnored lazy var camera = makeCamera()
    private func makeCamera() -> CameraCoordinator {
        let device = cameraDevice
        return CameraCoordinator(
            camera: device, state: CameraState(), photos: capturedPhotos,
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
    private let historyState = ConversationHistoryState()
    @ObservationIgnored lazy var history = makeHistory()
    private func makeHistory() -> ConversationHistoryWorkflow {
        ConversationHistoryWorkflow(
            state: historyState,
            prepare: { [weak self] in
                guard let self else { throw CancellationError() }
                await self.container?.lifecycle.beginSettingsChange()
                defer { self.container?.lifecycle.endSettingsChange() }
                try Task.checkCancellation()
                _ = try self.runtime()
            },
            refresh: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.runtime().historyIntents.refresh()
            },
            deleteArchive: { [weak self] id in
                guard let self else { throw CancellationError() }
                try await self.runtime().historyIntents.deleteArchived(id)
            },
            startNew: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.runtime().historyIntents.startNew()
            },
            summarize: { [weak self] id in
                guard let self else { throw CancellationError() }
                try await self.runtime().historyIntents.summarize(id)
            }, previewOutput: HistoryAgentAdapter.preview,
            readPhoto: { [weak self] id, inputID in
                guard let self else { throw CancellationError() }
                return try await self.capturedPhotos.readForInput(id, source: "assistant", input: inputID)
            })
    }
    private func makeHistoryChat() async throws -> any ChatCapability {
        try await settingsControls.restore()
        await container?.lifecycle.beginSettingsChange()
        defer { container?.lifecycle.endSettingsChange() }
        try Task.checkCancellation()
        let models = try await ModelKitDefaults.manager(resources: resources)
        return CurrentChatCapability(models: models)
    }
    private func runtime() throws -> ApplicationRuntime {
        if let runtimeValue { return runtimeValue }
        let resourceAdapter = ModelResourceCapabilityAdapter(
            manager: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.artifactManager()
            },
            quiesce: { [weak self] id in await self?.quiesceForModelRemoval(id) },
            bindSpeech: { [weak self] recognition, synthesis in
                guard let self else { throw CancellationError() }
                await self.container?.lifecycle.beginSettingsChange()
                await ModelKitDefaults.configureSpeech(recognition: recognition, synthesis: synthesis)
                self.container?.lifecycle.endSettingsChange()
            })
        let runtime = try ApplicationRuntime(
            camera: cameraDevice, cameraControl: camera, bluetooth: bluetooth, historyState: historyState,
            resourceState: modelResources, providerState: settings, navigationState: navigation, device: deviceControl,
            modelResources: resourceAdapter,
            providerSettingsRuntime: SettingsProviderAdapter.runtime(
                resources: resources,
                beginChange: { [weak self] in await self?.container?.lifecycle.beginSettingsChange() },
                endChange: { [weak self] in self?.container?.lifecycle.endSettingsChange() }),
            resourcePreferences: ModelResourcePreferencesService(
                store: {
                    try LocalDocumentStore<ModelResourcePreferences>(
                        url: URL.applicationSupportDirectory.appendingPathComponent(
                            "MobileHarness/Models/download-source.json"), maximumBytes: 4096)
                },
                validate: { try await SettingsModelResourcesAdapter.validatePreferences($0) },
                installed: { [weak self] in
                    guard let self else { throw CancellationError() }
                    let manager = try await self.artifactManager()
                    return Set(
                        try await manager.artifactSnapshots().filter { $0.phase == .installed }.map { $0.artifact.id })
                }),
            resourceInventory: resourceAdapter,
            resourceFingerprint: { try await resourceAdapter.observationFingerprint() },
            resourceSnapshotAccepted: { [weak self] in self?.modelResourceControls.acceptPresentedSnapshot() },
            summarizeTitle: { [weak self] conversation in
                guard let self else { throw CancellationError() }
                let chat = try await self.makeHistoryChat()
                try Task.checkCancellation()
                return try await ConversationTitleGenerator.summarize(conversation, using: chat)
            })
        runtimeValue = runtime
        return runtime
    }
    func setResourceObservationForeground(_ value: Bool) {
        environmentObservation.setForeground(value)
        resourceObservationForeground = value
        guard container != nil else { return }
        runtimeValue?.resourceObservation.setForeground(value)
    }
    func prepare(progress: @MainActor (String) -> Void) async throws {
        guard container == nil else { return }
        _ = try await artifactManager()
        _ = try await modelResourcesWorkflow.restoreSource()
        try await settingsControls.restore()
        let workflow = settingsWorkflow
        let prepared = try await AppContainer(
            resources: resources, runtime: runtime(), modelName: { await workflow.modelName }, progress: progress)
        try Task.checkCancellation()
        container = prepared
        runtimeValue?.resourceObservation.setForeground(resourceObservationForeground)
    }
}

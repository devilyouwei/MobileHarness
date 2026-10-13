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
    @ObservationIgnored private var cameraSample: CameraStateObservation?
    @ObservationIgnored private lazy var cameraObservation = makeCameraObservation()
    private func makeCameraObservation() -> ResourceObservationWorkflow {
        ResourceObservationWorkflow(
            read: { [weak self] in
                guard let self else { throw CancellationError() }
                let state = self.camera.state
                let value = CameraStateObservation(
                    sequence: 1, observedAt: Date(timeIntervalSince1970: 0),
                    enabled: state.isEnabled, visible: state.isVisible, busy: state.isBusy || state.photoBusy,
                    needsSettings: state.needsSettings, facing: state.facing == .front ? .front : .back,
                    displayedPhotoID: state.capturedPhoto?.id, savedPhotoID: state.savedPhotoID,
                    failure: state.message.map { String($0.prefix(128)) })
                self.cameraSample = value
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                return String(decoding: try encoder.encode(value), as: UTF8.self)
            },
            deliver: { [weak self] sample, sequence in
                guard let self else { throw CancellationError() }
                switch sample {
                case .changed:
                    guard let value = self.cameraSample else { throw DeviceControlError.invalidRequest }
                    try await self.runtime().photographerIntents.observeCamera(
                        CameraStateObservation(
                            sequence: sequence, enabled: value.enabled, visible: value.visible,
                            busy: value.busy, needsSettings: value.needsSettings, facing: value.facing,
                            displayedPhotoID: value.displayedPhotoID, savedPhotoID: value.savedPhotoID,
                            failure: value.failure))
                    return .accepted
                case .failed(let message): return .retry(message)
                }
            }, wait: { try await Task.sleep(for: .milliseconds(100)) }, invalidate: {},
            report: { [weak self] message in
                self?.runtimeValue?.actionActivity.recordFailure(
                    title: "摄像头状态发布失败", source: CameraStateObservation.source,
                    message: String(message.prefix(512)), failureCode: "camera.observation")
            })
    }

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
            pageVisibility: { [bluetooth] visible in
                if visible { bluetooth.openPage() } else { bluetooth.closePage() }
            }, openSettings: { [bluetooth] in bluetooth.openSystemSettings() },
            perform: { [weak self] intent in
                guard let self else { throw CancellationError() }
                try await self.runtime().applicationControlIntents.interact(intent)
            })
    }

    func navigate(_ destination: AppDestination?) {
        navigation.show(destination)
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
        root: URL.applicationSupportDirectory.appendingPathComponent("MobileHarness/CapturedPhotos", isDirectory: true),
        limits: .init(
            maximumPhotos: 1024, maximumBytes: 2 * 1024 * 1024 * 1024, maximumIndexBytes: 512 * 1024,
            overflowPolicy: .evictOldest))
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
                let context = try self.runtime().visionContext()
                return try VisionSession(runtime: self.runtime().visionDependencies) {
                    sessionID, configuration, mirroredGaze in
                    try VisionPerceptionAgent(
                        pose: pose, sessionID: sessionID, sampling: configuration, mirroredGaze: mirroredGaze,
                        context: context)
                }
            })
    }
    private let historyState = ConversationHistoryState(title: "Assistant")
    @ObservationIgnored lazy var history = makeHistory()
    private func makeHistory() -> ConversationHistoryWorkflow {
        let assistant = ConversationHistoryWorkflow(
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
                try await self.runtime().startNewConversation()
            },
            summarize: { [weak self] id in
                guard let self else { throw CancellationError() }
                try await self.runtime().historyIntents.summarize(id)
            }, previewOutput: HistoryAgentAdapter.preview,
            readPhoto: { [weak self] id, inputID in
                guard let self else { throw CancellationError() }
                return try await self.capturedPhotos.readForInput(id, source: "assistant", input: inputID)
            })
        let root = ConversationHistoryWorkflow(
            state: ConversationHistoryState(), prepare: {}, refresh: {}, deleteArchive: { _ in },
            startNew: {}, summarize: { _ in }, previewOutput: { _ in "" }, readPhoto: { _, _ in nil })
        root.agents = [
            HistoryAgentDestination(
                id: "assistant", name: "Assistant 聊天记录", summary: "当前聊天与已归档聊天", state: historyState, controls: assistant
            )
        ]
        let id = "assistant.tasks"
        let name = "任务记录"
        let summary = "Assistant 的前台与后台任务"
        do {
            let state = ConversationHistoryState(
                title: name, allowsMutations: false, groupsByTask: true)
            let workflow = ConversationHistoryWorkflow(
                state: state,
                prepare: { [weak self] in
                    guard let self else { throw CancellationError() }
                    _ = try self.runtime()
                },
                refresh: { [weak self] in
                    guard let self else { throw CancellationError() }
                    guard let read = try self.runtime().historyReaders[id] else { throw CancellationError() }
                    let snapshot = try await read()
                    try Task.checkCancellation()
                    state.archive = snapshot.archive
                    state.tasks = snapshot.tasks
                }, deleteArchive: { _ in }, startNew: {}, summarize: { _ in },
                previewOutput: { HistoryAgentAdapter.preview($0) },
                readPhoto: { [weak self] photo, input in
                    guard let self else { throw CancellationError() }
                    return try await self.capturedPhotos.readForInput(
                        photo, source: "assistant", input: input)
                })
            root.agents.append(
                HistoryAgentDestination(
                    id: id, name: name, summary: summary, state: state,
                    controls: workflow))
        }
        return root
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
            },
            modelName: { [weak self] in
                guard let self else { throw CancellationError() }
                return await self.settingsWorkflow.modelName
            },
            chatProvider: { [resources] in
                let models = try await ModelKitDefaults.manager(resources: resources)
                return try await models.get(.chat)
            })
        runtimeValue = runtime
        return runtime
    }
    func setAgentForeground(_ value: Bool) {
        runtimeValue?.setForeground(value)
    }
    func setResourceObservationForeground(_ value: Bool) {
        cameraObservation.setForeground(value)
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

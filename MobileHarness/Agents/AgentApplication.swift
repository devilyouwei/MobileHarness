import Foundation
import StorageCache
import StorageFiles
import StorageState

#if os(iOS)

    import StorageDevices
    import Actions
    import AgentCore
    import Gateway

    import ModelKit
    import ModelKitDefaults
    import ModelKitHub
    import ModelKitRuntime
    import Observation
    import PlatformKit
    import StorageCore
    import StorageChat
    import StorageMedia
    import StorageTasks
    import UI

    /// The scene's composition root. Runtime services are lazy but never discovered by consumers.
    @MainActor @Observable
    @available(iOS 27, *)
    public final class AgentApplication {
        @ObservationIgnored private let containerFailures: ContainerFailureChannel
        @ObservationIgnored private let repositories: @Sendable () throws -> AgentRepositories
        @ObservationIgnored private let capturedPhotos: CapturedPhotoStore
        @ObservationIgnored private let audio: AudioContainer
        @ObservationIgnored private let cameraDevice: any CameraCapturing
        private let cameraUI: UICameraContainer
        public let cameraState: CameraState
        @ObservationIgnored private let cameraPresentation: any CameraPresenting
        @ObservationIgnored private let cameraFactory: @MainActor (CameraSessionConnections) -> CameraCoordinator
        @ObservationIgnored private let languageModels: any ModelLanguageProviding
        @ObservationIgnored private let speechModels: any ModelSpeechProviding
        @ObservationIgnored private let visionModels: any ModelVisionProviding
        @ObservationIgnored private let modelArtifacts: any ModelArtifactsManaging
        @ObservationIgnored private let memoryPressure: @Sendable () async -> Void
        @ObservationIgnored private var publicStateScope: StateScope?
        private func installPublicState() throws {
            guard publicStateScope == nil else { return }
            let scope = try stateStorage.makeScope()
            try camera.connectPublicState(scope: scope)
            try bluetooth.service.connectPublicState(scope: scope)
            publicStateScope = scope
        }
        public var onModelConfigurationChanged: (@MainActor () -> Void)?
        private let homeUI: UIHomeContainer
        private let settingsUI: UISettingsContainer
        private let resourcesUI: UIModelResourcesContainer
        private let navigationUI: UINavigationContainer
        private let historyUI: UIHistoryContainer
        public let devicesUI: UIDeviceSettingsContainer
        private let diagnosticsUI: UIDiagnosticsContainer
        private let stateStorage: StateContainer
        private let cacheStorage: CacheContainer
        private let filesStorage: FilesContainer
        let bluetooth: BluetoothWorkflow
        public init(
            containerFailures: ContainerFailureChannel,
            home: UIHomeContainer, settings: UISettingsContainer, modelResources: UIModelResourcesContainer,
            navigation: UINavigationContainer, history: UIHistoryContainer, devices: UIDeviceSettingsContainer,
            diagnostics: UIDiagnosticsContainer,
            repositories: @escaping @Sendable () throws -> AgentRepositories, state: StateContainer,
            cache: CacheContainer, files: FilesContainer, photos: CapturedPhotoStore,
            camera: any CameraCapturing, cameraState: CameraState, cameraPresentation: any CameraPresenting,
            cameraUI: UICameraContainer,
            makeCamera: @escaping @MainActor (CameraSessionConnections) -> CameraCoordinator,
            bluetooth: BluetoothWorkflow, audio: AudioContainer,
            languageModels: any ModelLanguageProviding, speechModels: any ModelSpeechProviding,
            visionModels: any ModelVisionProviding, modelArtifacts: any ModelArtifactsManaging,
            memoryPressure: @escaping @Sendable () async -> Void
        ) {
            self.containerFailures = containerFailures
            homeUI = home
            settingsUI = settings
            resourcesUI = modelResources
            navigationUI = navigation
            historyUI = history
            devicesUI = devices
            diagnosticsUI = diagnostics
            self.audio = audio
            self.stateStorage = state
            self.cacheStorage = cache
            self.filesStorage = files
            self.repositories = repositories
            capturedPhotos = photos
            cameraDevice = camera
            self.cameraUI = cameraUI
            self.cameraState = cameraState
            self.cameraPresentation = cameraPresentation
            cameraFactory = makeCamera
            self.bluetooth = bluetooth
            self.languageModels = languageModels
            self.speechModels = speechModels
            self.visionModels = visionModels
            self.modelArtifacts = modelArtifacts
            self.memoryPressure = memoryPressure
        }
        public private(set) var container: VoiceInteractionSession?
        @ObservationIgnored private var runtimeValue: AgentRuntime?
        @ObservationIgnored private lazy var environmentInputs: ApplicationEnvironmentInputs = makeEnvironmentInputs()
        private func makeEnvironmentInputs() -> ApplicationEnvironmentInputs {
            ApplicationEnvironmentInputs(
                deliver: { [weak self] fact in
                    guard let self else { throw CancellationError() }
                    try await self.runtime().applicationControlSession.agent.observeEnvironment(fact)
                },
                failed: { [containerFailures] error in
                    containerFailures.report(
                        module: "agents", component: "applicationControl.environment",
                        operation: "observe", error: error)
                })
        }
        public func reportModelPreparation(loading: Bool) {
            reportEnvironment(.modelPreparation, value: loading ? "loading" : "idle")
        }
        public func reportEnvironment(_ category: AppEnvironmentFact.Category, value: String) {
            environmentInputs.report(category, value: value)
        }
        private func artifactManager() async throws -> any ModelArtifactsManaging {
            try await modelArtifacts.prepare()
            return modelArtifacts
        }
        @ObservationIgnored private lazy var modelResourcesWorkflow = makeModelResourcesWorkflow()
        private func makeModelResourcesWorkflow() -> ModelResourcesClient {
            ModelResourcesClient(
                read: { [resourcesUI] generation in
                    guard case .snapshot(let value) = try await resourcesUI.requests.submit(.refresh(generation)) else {
                        throw UIRequestError.stale
                    }
                    return value
                },
                restore: { [resourcesUI] in
                    guard case .source(let value) = try await resourcesUI.requests.submit(.restore) else {
                        throw UIRequestError.stale
                    }
                    return value
                },
                save: { [resourcesUI] draft in
                    guard case .source(let value) = try await resourcesUI.requests.submit(.save(draft)) else {
                        throw UIRequestError.stale
                    }
                    return value
                },
                download: { [resourcesUI] id, draft in _ = try await resourcesUI.requests.submit(.download(id, draft))
                },
                cancel: { [resourcesUI] id in _ = try await resourcesUI.requests.submitControl(.cancel(id)) },
                remove: { [resourcesUI] id in _ = try await resourcesUI.requests.submit(.remove(id)) })
        }
        public var modelResources: ModelResourcesState { resourcesUI.state }
        @ObservationIgnored public lazy var modelResourceControls = ModelResourceInteractionWorkflow(
            state: resourcesUI.presentation, operations: modelResourcesWorkflow)
        private func quiesceForModelRemoval(_ id: String) async {
            if id == "yolo26n-pose" {
                await camera.pauseVisionForModelMaintenance()
            } else {
                await container?.lifecycle.beginSettingsChange()
                container?.lifecycle.endSettingsChange()
            }
        }
        @ObservationIgnored private lazy var settingsWorkflow = ProviderSettingsClient(
            provider: SettingsProviderOperations(
                initial: SettingsProviderAdapter.initial,
                restore: { [settingsUI] in
                    guard case .draft(let value) = try await settingsUI.requests.submit(.restore) else {
                        throw UIRequestError.stale
                    }
                    return value
                },
                discover: { [settingsUI] draft in
                    guard case .models(let values) = try await settingsUI.requests.submit(.discover(draft)) else {
                        throw UIRequestError.stale
                    }
                    return values
                }, save: { [settingsUI] draft in _ = try await settingsUI.requests.submit(.save(draft)) },
                errorMessage: { SettingsProviderAdapter.errorMessage($0) }), presentsResults: true)

        public var settings: SettingsState { settingsUI.state }
        @ObservationIgnored public lazy var settingsControls = SettingsFormController(
            state: settingsUI.presentation, operations: settingsWorkflow,
            defaultModel: SettingsProviderAdapter.initial.model)
        @ObservationIgnored public lazy var cameraControls = makeCameraControls()
        private func makeCameraControls() -> CameraInteractionWorkflow {
            CameraInteractionWorkflow(
                presentation: cameraPresentation,
                perform: { [cameraUI] operation, facing, mediaID in
                    guard let operation = CameraInput.Operation(rawValue: operation.rawValue) else {
                        throw UIRequestError.stale
                    }
                    _ = try await cameraUI.requests.submit(
                        CameraInput(operation, facing: facing.map { $0 == .front ? .front : .back }, mediaID: mediaID))
                })
        }
        public var navigation: NavigationState { navigationUI.state }
        @ObservationIgnored lazy var deviceControl = NexArmDeviceAdapter(bluetooth: bluetooth)
        @ObservationIgnored public lazy var bluetoothControls = makeBluetoothControls()
        private func makeBluetoothControls() -> BluetoothInteractionWorkflow {
            BluetoothInteractionWorkflow(
                state: devicesUI.presentation,
                initialFence: deviceControl.fence, fenceStop: { [deviceControl] in deviceControl.stopFence() },
                pageVisibility: { [bluetooth] visible in
                    if visible { bluetooth.openPage() } else { bluetooth.closePage() }
                }, openSettings: { [bluetooth] in bluetooth.openSystemSettings() },
                perform: { [weak self] intent in
                    guard let self else { throw CancellationError() }
                    if ["stopScan", "disconnect", "forget"].contains(intent["operation"] ?? "") {
                        try await self.devicesUI.requests.submitControl(DeviceInput(intent))
                    } else {
                        try await self.devicesUI.requests.submit(DeviceInput(intent))
                    }
                })
        }

        public func navigate(_ destination: AppDestination?) {
            navigationUI.presentation.show(destination)
        }
        @ObservationIgnored lazy var camera = makeCamera()
        private func makeCamera() -> CameraCoordinator {
            cameraFactory(
                CameraSessionConnections(
                    makeRuntime: { [weak self] in
                        guard let self else { throw CancellationError() }
                        return try self.runtime().cameraDependencies
                    },
                    connectPerception: { [weak self] sessionID, mirrored, endpoint in
                        guard let self else { throw CancellationError() }
                        do {
                            try await VisionAgentSession(
                                runtime: self.runtime(), pose: self.visionModels, camera: self.cameraDevice
                            ).run(sessionID: sessionID, mirrored: mirrored, endpoint: endpoint)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            self.containerFailures.report(
                                module: "agents", component: "visionPerception",
                                operation: "session", error: error)
                            throw error
                        }
                    }))
        }

        public var historyState: ConversationHistoryState { historyUI.state }
        @ObservationIgnored public lazy var history = makeHistory()
        private func makeHistory() -> ConversationHistoryWorkflow {
            ConversationHistoryWorkflow(
                state: historyUI.presentation,
                prepare: {},
                refresh: { [historyUI] in _ = try await historyUI.requests.submit(.refresh) },
                deleteArchive: { [historyUI] id in _ = try await historyUI.requests.submit(.delete(id)) },
                startNew: { [historyUI] in _ = try await historyUI.requests.submit(.startNew) },
                summarize: { [historyUI] id in _ = try await historyUI.requests.submit(.summarize(id)) },
                previewOutput: HistoryExecutionPreview.preview,
                readConversation: { [historyUI] id in
                    guard case .conversation(let value) = try await historyUI.requests.submit(.conversation(id)) else {
                        throw UIRequestError.stale
                    }
                    return value
                },
                readPhoto: { [historyUI] id, inputID in
                    guard case .photo(let value) = try await historyUI.requests.submit(.photo(id, inputID)) else {
                        throw UIRequestError.stale
                    }
                    return value
                },
                readMessage: { [historyUI] id in
                    guard case .conversation(let value) = try await historyUI.requests.submit(.message(id)) else {
                        throw UIRequestError.stale
                    }
                    return value
                },
                readPage: { [historyUI] id, after, taskID in
                    guard case .conversation(let value) = try await historyUI.requests.submit(.page(id, after, taskID))
                    else { throw UIRequestError.stale }
                    return value
                },
                readArchives: { [historyUI] cursor in
                    guard case .archives(let values) = try await historyUI.requests.submit(.archives(cursor)) else {
                        throw UIRequestError.stale
                    }
                    return values
                })
        }
        private func makeHistoryChat() async throws -> any ChatCapability {
            try await settingsControls.restore()
            await container?.lifecycle.beginSettingsChange()
            defer { container?.lifecycle.endSettingsChange() }
            try Task.checkCancellation()
            return languageModels
        }
        private func runtime() throws -> AgentRuntime {
            _ = try repositories()
            if let runtimeValue { return runtimeValue }
            let resourceAdapter = ModelResourceCapabilityAdapter(
                artifacts: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.artifactManager()
                },
                quiesce: { [weak self] id in await self?.quiesceForModelRemoval(id) },
                bindSpeech: { [weak self] recognition, synthesis in
                    guard let self else { throw CancellationError() }
                    await self.container?.lifecycle.beginSettingsChange()
                    defer {
                        self.container?.lifecycle.endSettingsChange()
                        self.onModelConfigurationChanged?()
                    }
                    try await self.speechModels.configure(recognition: recognition, synthesis: synthesis)
                })
            try installPublicState()
            let runtime = try AgentRuntime(
                containerFailures: containerFailures, home: homeUI,
                state: stateStorage, cache: cacheStorage, files: filesStorage,
                chatRecords: try repositories().chat, taskRecords: try repositories().tasks,
                camera: cameraDevice, cameraUI: cameraUI, settingsUI: settingsUI,
                resourcesUI: resourcesUI, devicesUI: devicesUI, historyUI: historyUI, diagnosticsUI: diagnosticsUI,
                readHistoryPhoto: { [capturedPhotos] id, inputID in
                    try await capturedPhotos.readForInput(id, source: "assistant", input: inputID)
                }, cameraControl: camera, bluetooth: bluetooth, historyState: historyState,
                resourceState: modelResources, providerState: settings, navigationState: navigationUI.presentation,
                device: deviceControl,
                modelResources: resourceAdapter,
                providerSettingsRuntime: SettingsProviderAdapter.runtime(
                    language: languageModels,
                    beginChange: { [weak self] in await self?.container?.lifecycle.beginSettingsChange() },
                    endChange: { [weak self] in
                        self?.container?.lifecycle.endSettingsChange()
                        self?.onModelConfigurationChanged?()
                    }),
                resourcePreferences: ModelResourcePreferencesService(
                    store: {
                        try self.filesStorage.document(
                            ModelResourcePreferences.self, in: self.filesStorage.models, name: "download-source.json",
                            maximumBytes: 4096)
                    },
                    validate: { try await SettingsModelResourcesAdapter.validatePreferences($0) },
                    installed: { [weak self] in
                        guard let self else { throw CancellationError() }
                        let manager = try await self.artifactManager()
                        return Set(
                            try await manager.artifactSnapshots().filter { $0.phase == .installed }.map {
                                $0.artifact.id
                            })
                    }),
                resourceInventory: resourceAdapter,
                resourceChanges: { [modelArtifacts] in try await modelArtifacts.observeArtifactChanges() },
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
                chatProvider: { [languageModels] in languageModels })
            runtimeValue = runtime
            return runtime
        }
        public func setAgentForeground(_ value: Bool) async throws {
            try await runtimeValue?.setForeground(value)
        }
        @ObservationIgnored private var preparation: Task<Void, Error>?
        @ObservationIgnored private var bluetoothObservation: Task<Void, Never>?
        @ObservationIgnored private var cameraEvents: Task<Void, Never>?
        private var foreground = true
        public func updateCameraAvailability() {
            camera.setForeground(foreground && navigation.path.isEmpty)
        }
        public var isolatedPresentation: Bool {
            let arguments = ProcessInfo.processInfo.arguments
            return [
                "-gemma4-validation",
                "-moss-benchmark",
            ].contains { arguments.contains($0) }
        }
        public func prepare(progress: @MainActor (String) -> Void) async throws {
            if let preparation { return try await preparation.value }
            if container != nil { return }
            // Progress is a value update; no page lifetime owns the preparation task.
            let task = Task { try await self.prepareServices(progress: { _ in }) }
            preparation = task
            do {
                try await task.value
                progress("本地模型可在设置中下载")
            } catch {
                preparation = nil
                throw error
            }
        }
        public func startAgents() async throws {
            guard !isolatedPresentation else { return }
            try await runtime().start()
        }
        public func startNativeServices() async throws {
            guard !isolatedPresentation else { return }
            try await prepare(progress: { _ in })
            try await container?.startInteraction()
            guard bluetoothObservation == nil, cameraEvents == nil else { return }
            bluetoothObservation = Task { [bluetooth] in await bluetooth.run() }
            cameraEvents = Task { [camera] in await camera.observe() }
            setForeground(foreground)
        }
        public func invalidateNative() {
            foreground = false
            camera.setForeground(false)
            bluetooth.setForeground(false)
            container?.lifecycle.stopVoice(message: "已进入后台，按住双眼重新开始")
            container?.invalidateDetection()
        }
        public func setForeground(_ value: Bool) {
            foreground = value
            guard !isolatedPresentation else { return }
            updateCameraAvailability()
            bluetooth.setForeground(value)
            reportEnvironment(.scene, value: value ? "active" : "background")
            if !value { invalidateNative() }
        }
        public func stopNativeServices() async throws {
            invalidateNative()
            preparation?.cancel()
            _ = await preparation?.result
            cameraEvents?.cancel()
            bluetoothObservation?.cancel()
            await cameraEvents?.value
            await bluetoothObservation?.value
            cameraEvents = nil
            bluetoothObservation = nil
            await modelResourceControls.stopAndWait()
            var cleanupErrors: [any Error] = []
            do { try await camera.shutdown() } catch { cleanupErrors.append(error) }
            do { try await bluetooth.shutdown() } catch { cleanupErrors.append(error) }
            await bluetoothControls.shutdown()
            do { try await container?.shutdown() } catch { cleanupErrors.append(error) }
            container = nil
            if !cleanupErrors.isEmpty { throw NativeCleanupFailure(errors: cleanupErrors) }
        }
        public func stopAgents() async {
            await environmentInputs.shutdown()
            await runtimeValue?.shutdown()
            publicStateScope?.close()
            publicStateScope = nil
        }
        private func prepareServices(progress: @MainActor (String) -> Void) async throws {
            _ = try repositories()
            guard container == nil else { return }
            _ = try await artifactManager()
            try await runtime().start()
            _ = try await modelResourcesWorkflow.restoreSource()
            try await settingsControls.restore()
            let workflow = settingsWorkflow
            let prepared = try await VoiceInteractionSession(
                home: homeUI, diagnostics: diagnosticsUI, language: languageModels, speech: speechModels,
                memoryPressure: memoryPressure, audio: audio, runtime: runtime(),
                modelName: { await workflow.modelName },
                progress: progress)
            try Task.checkCancellation()
            container = prepared
        }
    }

#endif

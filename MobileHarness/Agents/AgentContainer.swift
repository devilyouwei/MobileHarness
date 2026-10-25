import Foundation
import StorageCache
import StorageFiles

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

    /// Instance-local module root. Only explicit lifecycle operations create runtime work.
    @MainActor @Observable
    @available(iOS 27, *)
    public final class AgentContainer {
        @ObservationIgnored private let containerFailures: ContainerFailureChannel
        @ObservationIgnored private let repositories: @Sendable () throws -> AgentRepositories
        @ObservationIgnored private let capturedPhotos: CapturedPhotoStore
        @ObservationIgnored private let audio: AudioContainer
        @ObservationIgnored private let cameraDevice: any CameraCapturing
        private let albumUI: UIAlbumContainer
        private let albumService: PhotoAlbumService
        private let cameraUI: UICameraContainer
        @ObservationIgnored private let cameraFactory: @MainActor (CameraSessionConnections) -> CameraCoordinator
        @ObservationIgnored private let languageModels: any ModelLanguageProviding
        @ObservationIgnored private let speechModels: any ModelSpeechProviding
        @ObservationIgnored private let visionModels: any ModelVisionProviding
        @ObservationIgnored private let modelArtifacts: any ModelArtifactsManaging
        @ObservationIgnored private let memoryPressure: @Sendable () async -> Void
        private func makeStateContext() throws -> AgentStateContext {
            let context = AgentStateContext()
            try context.register(
                "actions.camera",
                source: ContainerContextSource { [camera] in
                    await camera.contextSnapshot()
                })
            try context.register(
                "actions.robot",
                source: ContainerContextSource { [service = bluetooth.service] in
                    await service.contextSnapshot()
                })
            try context.register(
                "ui.navigation",
                source: ContainerContextSource { [navigation = navigationUI.state, album = albumUI] in
                    try await MainActor.run {
                        try navigation.requirePresentation()
                        return ContainerContextValue(navigation.contextSnapshot(album: album.contextSnapshot()))
                    }
                })
            try context.register(
                "ui.camera",
                source: ContainerContextSource { [cameraUI] in
                    try await MainActor.run {
                        guard cameraUI.state.isPresentationAvailable else { throw UIContainerError.unavailable }
                        return ContainerContextValue(cameraUI.contextSnapshot())
                    }
                })
            try context.register(
                "ui.album",
                source: ContainerContextSource { [albumUI, navigation = navigationUI.state] in
                    try await MainActor.run {
                        try navigation.requirePresentation()
                        return ContainerContextValue(albumUI.contextSnapshot())
                    }
                })
            return context
        }
        public var onModelConfigurationChanged: (@MainActor () -> Void)?
        private let homeUI: UIHomeContainer
        private let settingsUI: UISettingsContainer
        private let resourcesUI: UIModelResourcesContainer
        private let navigationUI: UINavigationContainer
        private let historyUI: UIHistoryContainer
        private let devicesUI: UIDeviceSettingsContainer
        private let diagnosticsUI: UIDiagnosticsContainer
        private let cacheStorage: CacheContainer
        private let filesStorage: FilesContainer
        let bluetooth: BluetoothWorkflow
        public init(
            containerFailures: ContainerFailureChannel,
            home: UIHomeContainer, settings: UISettingsContainer, modelResources: UIModelResourcesContainer,
            navigation: UINavigationContainer, history: UIHistoryContainer, devices: UIDeviceSettingsContainer,
            diagnostics: UIDiagnosticsContainer,
            repositories: @escaping @Sendable () throws -> AgentRepositories,
            cache: CacheContainer, files: FilesContainer, photos: CapturedPhotoStore,
            camera: any CameraCapturing, cameraPresentation: any CameraPresenting,
            cameraUI: UICameraContainer, albumUI: UIAlbumContainer,
            exportPhoto: @escaping @Sendable (Data) async throws -> Void = { _ in throw PhotoAlbumError.unavailable },
            makeCamera: @escaping @MainActor (CameraSessionConnections) -> CameraCoordinator,
            bluetooth: BluetoothWorkflow, audio: AudioContainer,
            languageModels: any ModelLanguageProviding, speechModels: any ModelSpeechProviding,
            visionModels: any ModelVisionProviding, modelArtifacts: any ModelArtifactsManaging,
            memoryPressure: @escaping @Sendable () async -> Void
        ) {
            self.containerFailures = containerFailures
            assistant = AssistantContainer(home: home)
            speechPerception = SpeechPerceptionContainer(home: home, diagnostics: diagnostics)
            applicationControl = ApplicationControlContainer(
                settings: settings, resources: modelResources, diagnostics: diagnostics,
                devices: devices, navigation: navigation, bluetooth: bluetooth, failures: containerFailures)
            memory = MemoryContainer(history: history)
            photographer = PhotographerContainer(camera: cameraUI, presentation: cameraPresentation)
            homeUI = home
            settingsUI = settings
            resourcesUI = modelResources
            navigationUI = navigation
            historyUI = history
            devicesUI = devices
            diagnosticsUI = diagnostics
            self.audio = audio
            self.cacheStorage = cache
            self.filesStorage = files
            self.repositories = repositories
            capturedPhotos = photos
            cameraDevice = camera
            self.albumUI = albumUI
            self.albumService = PhotoAlbumService(photos: photos, export: exportPhoto)
            self.cameraUI = cameraUI
            cameraFactory = makeCamera
            self.bluetooth = bluetooth
            self.languageModels = languageModels
            self.speechModels = speechModels
            self.visionModels = visionModels
            self.modelArtifacts = modelArtifacts
            self.memoryPressure = memoryPressure
        }
        public let assistant: AssistantContainer
        public let applicationControl: ApplicationControlContainer
        public let memory: MemoryContainer
        public let photographer: PhotographerContainer
        public let speechPerception: SpeechPerceptionContainer
        public let speechSynthesis = SpeechSynthesisContainer()
        public let visionPerception = VisionPerceptionContainer()
        @ObservationIgnored private lazy var lifecycle = AgentContainerLifecycle(
            start: { [unowned self] in try await self.startServices() },
            invalidate: { [unowned self] in self.invalidateServices() },
            foreground: { [unowned self] in try await self.applyForeground($0) },
            stop: { [unowned self] in try await self.stopServices() },
            report: { [containerFailures] failure in
                containerFailures.report(
                    module: "agents", component: failure.component, operation: failure.operation,
                    error: failure, details: .init(code: failure.code.rawValue, isCancellation: failure.isCancellation))
            })
        public var isAvailable: Bool { lifecycle.isAvailable }
        public func start() async throws(AgentFailure) { try await lifecycle.start() }
        public func invalidate() { lifecycle.invalidate() }
        public func setForeground(_ value: Bool) async throws(AgentFailure) { try await lifecycle.setForeground(value) }
        public func stop() async throws(AgentFailure) { try await lifecycle.stop() }
        @ObservationIgnored private var runtimeValue: AgentRuntime?
        public func reportModelPreparation(loading: Bool) {
            reportEnvironment(.modelPreparation, value: loading ? "loading" : "idle")
        }
        public func reportEnvironment(_ category: AppEnvironmentFact.Category, value: String) {
            guard isAvailable else { return }
            applicationControl.reportEnvironment(category, value: value)
        }
        private func artifactManager() async throws -> any ModelArtifactsManaging {
            try await modelArtifacts.prepare()
            return modelArtifacts
        }

        public var album: UIAlbumContainer { albumUI }
        public var navigation: NavigationState { navigationUI.state }

        public func navigate(_ destination: AppDestination?) {
            navigationUI.presentation.show(destination)
        }
        @ObservationIgnored lazy var camera = makeCamera()
        private func makeCamera() -> CameraCoordinator {
            cameraFactory(
                CameraSessionConnections(
                    makeRuntime: { [weak self] in
                        guard let self else { throw CancellationError() }
                        try self.lifecycle.requireAvailable()
                        return try self.runtime().cameraDependencies
                    },
                    connectPerception: { [weak self] sessionID, mirrored, endpoint in
                        guard let self else { throw CancellationError() }
                        do {
                            try self.lifecycle.requireAvailable()
                            try await self.visionPerception.run(
                                runtime: self.runtime(), pose: self.visionModels, camera: self.cameraDevice,
                                sessionID: sessionID, mirrored: mirrored, endpoint: endpoint)
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

        private func makeHistoryChat() async throws -> any ChatCapability {
            try await applicationControl.settingsControls.restore()
            await speechPerception.beginSettingsChange()
            defer { speechPerception.endSettingsChange() }
            try Task.checkCancellation()
            return languageModels
        }
        private func quiesceForModelRemoval(_ id: String) async {
            if id == "yolo26n-pose" {
                await camera.pauseVisionForModelMaintenance()
            } else {
                await speechPerception.beginSettingsChange()
                speechPerception.endSettingsChange()
            }
        }
        private func runtime() throws -> AgentRuntime {
            guard !lifecycle.isStopped else { throw AgentContainerError.stopped }
            try Task.checkCancellation()
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
                    await self.speechPerception.beginSettingsChange()
                    defer {
                        self.speechPerception.endSettingsChange()
                        self.onModelConfigurationChanged?()
                    }
                    try await self.speechModels.configure(recognition: recognition, synthesis: synthesis)
                })
            let runtime = try AgentRuntime(
                containerFailures: containerFailures, home: homeUI,
                assistantContainer: assistant, applicationControlContainer: applicationControl,
                memoryContainer: memory, photographerContainer: photographer,
                stateContext: try makeStateContext(), cache: cacheStorage, files: filesStorage,
                chatRecords: try repositories().chat, taskRecords: try repositories().tasks,
                camera: cameraDevice, cameraUI: cameraUI, albumUI: albumUI, album: albumService, settingsUI: settingsUI,
                resourcesUI: resourcesUI, devicesUI: devicesUI, historyUI: historyUI, diagnosticsUI: diagnosticsUI,
                readHistoryPhoto: { [capturedPhotos] id, inputID in
                    try await capturedPhotos.readForInput(id, source: "assistant", input: inputID)
                }, cameraControl: camera, bluetooth: bluetooth, historyState: memory.historyState,
                resourceState: applicationControl.modelResources, providerState: applicationControl.settings,
                navigationState: navigationUI.presentation,
                device: applicationControl.deviceControl,
                modelResources: resourceAdapter,
                providerSettingsRuntime: SettingsProviderAdapter.runtime(
                    language: languageModels,
                    beginChange: { [weak self] in await self?.speechPerception.beginSettingsChange() },
                    endChange: { [weak self] in
                        self?.speechPerception.endSettingsChange()
                        self?.onModelConfigurationChanged?()
                    }),
                resourcePreferences: ModelResourcePreferencesService(
                    store: { [filesStorage] in
                        try filesStorage.document(
                            ModelResourcePreferences.self, in: filesStorage.models, name: "download-source.json",
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
                resourceSnapshotAccepted: { [weak self] in
                    self?.applicationControl.modelResourceControls.acceptPresentedSnapshot()
                },
                summarizeTitle: { [weak self] conversation in
                    guard let self else { throw CancellationError() }
                    let chat = try await self.makeHistoryChat()
                    try Task.checkCancellation()
                    return try await ConversationTitleGenerator.summarize(conversation, using: chat)
                },
                modelName: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return await self.applicationControl.settingsWorkflow.modelName
                },
                chatProvider: { [languageModels] in languageModels })
            runtimeValue = runtime
            return runtime
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
        private func prepare(progress: @MainActor (String) -> Void) async throws {
            if let preparation { return try await preparation.value }
            if speechPerception.isReady { return }
            // Progress is a value update; no page lifetime owns the preparation task.
            let task = Task { try await self.prepareServices(progress: { _ in }) }
            preparation = task
            do {
                try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                progress("本地模型可在设置中下载")
            } catch {
                preparation = nil
                throw error
            }
        }
        private func startAgents() async throws {
            guard !isolatedPresentation else { return }
            let runtime = try runtime()
            try await applicationControl.start()
            try await photographer.start()
            try await memory.start()
            try await assistant.start()
            runtime.connectFailures()
        }
        private func startNativeServices() async throws {
            guard !isolatedPresentation else { return }
            try await prepare(progress: { _ in })
            try await speechPerception.startInteraction()
            guard bluetoothObservation == nil, cameraEvents == nil else { return }
            bluetoothObservation = Task { [bluetooth] in await bluetooth.run() }
            cameraEvents = Task { [camera] in await camera.observe() }
            applyNativeForeground(foreground)
        }
        private func invalidateNative() {
            foreground = false
            camera.setForeground(false)
            bluetooth.setForeground(false)
            speechPerception.invalidate()
        }
        private func applyNativeForeground(_ value: Bool) {
            foreground = value
            guard !isolatedPresentation else { return }
            updateCameraAvailability()
            bluetooth.setForeground(value)
            reportEnvironment(.scene, value: value ? "active" : "background")
            if !value { invalidateNative() }
        }
        private func stopNativeServices() async throws {
            invalidateNative()
            preparation?.cancel()
            _ = await preparation?.result
            cameraEvents?.cancel()
            bluetoothObservation?.cancel()
            await cameraEvents?.value
            await bluetoothObservation?.value
            cameraEvents = nil
            bluetoothObservation = nil
            await applicationControl.modelResourceControls.stopAndWait()
            var cleanupErrors: [any Error] = []
            do { try await camera.shutdown() } catch { cleanupErrors.append(error) }
            do { try await bluetooth.shutdown() } catch { cleanupErrors.append(error) }
            await applicationControl.bluetoothControls.shutdown()
            do { try await speechPerception.stop() } catch { cleanupErrors.append(error) }
            do { try await speechSynthesis.stop() } catch { cleanupErrors.append(error) }
            do { try await visionPerception.stop() } catch { cleanupErrors.append(error) }
            if !cleanupErrors.isEmpty { throw NativeCleanupFailure(errors: cleanupErrors) }
        }
        private func stopAgents() async throws {
            var errors: [any Error] = []
            do { try await assistant.stop() } catch { errors.append(error) }
            do { try await photographer.stop() } catch { errors.append(error) }
            do { try await memory.stop() } catch { errors.append(error) }
            do { try await applicationControl.stop() } catch { errors.append(error) }
            await runtimeValue?.shutdown()
            runtimeValue = nil
            if let primary = errors.first {
                throw AgentFailure(
                    component: "roles", operation: "stop", underlying: primary,
                    cleanupErrors: Array(errors.dropFirst()), code: .cleanupFailed)
            }
        }
        private func startServices() async throws {
            try await startAgents()
            try Task.checkCancellation()
            try await startNativeServices()
        }
        private func setInputAvailable(_ value: Bool) {
            assistant.setInputAvailable(value)
            applicationControl.setInputAvailable(value)
            memory.setInputAvailable(value)
            photographer.setInputAvailable(value)
            speechPerception.setInputAvailable(value)
        }
        private func invalidateServices() {
            preparation?.cancel()
            setInputAvailable(false)
            invalidateNative()
            visionPerception.invalidate()
        }
        private func applyForeground(_ value: Bool) async throws {
            if !value {
                var errors: [any Error] = []
                do { try await camera.shutdown() } catch { errors.append(error) }
                await speechPerception.suspend()
                await bluetooth.waitUntilIdle()
                do { try await visionPerception.suspend() } catch { errors.append(error) }
                do { try await applicationControl.setForeground(false) } catch { errors.append(error) }
                do { try await photographer.setForeground(false) } catch { errors.append(error) }
                do { try await memory.setForeground(false) } catch { errors.append(error) }
                do { try await assistant.setForeground(false) } catch { errors.append(error) }
                if let primary = errors.first {
                    throw AgentFailure(
                        component: "root", operation: "suspend", underlying: primary,
                        cleanupErrors: Array(errors.dropFirst()), code: .cleanupFailed)
                }
                return
            }
            try await applicationControl.setForeground(true)
            try await photographer.setForeground(true)
            try await memory.setForeground(true)
            try await assistant.setForeground(true)
            guard lifecycle.isForegroundRequested else { return }
            applyNativeForeground(true)
            setInputAvailable(true)
        }
        private func stopServices() async throws {
            var errors: [any Error] = []
            do { try await stopNativeServices() } catch { errors.append(error) }
            do { try await stopAgents() } catch { errors.append(error) }
            if let primary = errors.first {
                throw AgentFailure(
                    component: "root", operation: "stop", underlying: primary, cleanupErrors: Array(errors.dropFirst()),
                    code: .cleanupFailed)
            }
        }
        private func prepareServices(progress: @MainActor (String) -> Void) async throws {
            _ = try repositories()
            guard !speechPerception.isReady else { return }
            _ = try await artifactManager()
            _ = try await applicationControl.modelResourcesWorkflow.restoreSource()
            try await applicationControl.settingsControls.restore()
            let workflow = applicationControl.settingsWorkflow
            let prepared = try await VoiceInteractionSession(
                home: homeUI, diagnostics: diagnosticsUI, language: languageModels, speech: speechModels,
                memoryPressure: memoryPressure, audio: audio, runtime: runtime(),
                perceptionContainer: speechPerception, synthesisContainer: speechSynthesis,
                modelName: { await workflow.modelName },
                progress: progress)
            try Task.checkCancellation()
            try speechPerception.installInteraction(prepared)
        }
    }

#endif

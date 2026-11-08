#if os(iOS)
    import CallRuntime
    import Foundation
    import StorageDatabase
    import FunctionContracts
    import ModelKit
    import ModelKitOpenAI
    import ModelKitDefaults
    import ModelKitRuntime
    import PlatformKit
    import StorageChat
    import StorageCache
    import StorageCore
    import StorageFiles
    import StorageMedia
    import UI

    /// Module-owned business assembly. Its lifetime is retained and closed by ActionsContainer.
    @MainActor @available(iOS 27, *)
    final class ActionsBusinessAssembly {
        unowned let actions: ActionsContainer
        let workspaces: @Sendable () throws -> any WorkspaceRepository
        let cache: CacheContainer
        let files: FilesContainer
        let model: ModelContainer
        let platform: PlatformContainer
        let ui: UIContainer
        let photos: MediaStore
        let bluetooth: BluetoothWorkflow
        let device: NexArmDeviceAdapter
        lazy var facades = makeUIFacades()
        var stopInteractions: @MainActor () async -> Void = {}
        private let makeCameraRuntime: @MainActor () throws -> CameraRuntimeDependencies
        private let connectVision: @MainActor (String, Bool, any CameraOutputHandling) async throws -> Void
        private var endpoints: ActionEndpoints?
        init(
            actions: ActionsContainer, files: FilesContainer, cache: CacheContainer,
            workspaces: @escaping @Sendable () throws -> any WorkspaceRepository, model: ModelContainer,
            platform: PlatformContainer, ui: UIContainer, photos: MediaStore, bluetooth: BluetoothWorkflow,
            makeCameraRuntime: @escaping @MainActor () throws -> CameraRuntimeDependencies,
            connectVision: @escaping @MainActor (String, Bool, any CameraOutputHandling) async throws -> Void
        ) {
            self.actions = actions
            self.workspaces = workspaces
            self.cache = cache
            self.files = files
            self.model = model
            self.platform = platform
            self.ui = ui
            self.photos = photos
            self.bluetooth = bluetooth
            self.device = NexArmDeviceAdapter(bluetooth: bluetooth)
            self.makeCameraRuntime = makeCameraRuntime
            self.connectVision = connectVision
        }
        private var observedCamera: CameraCoordinator?
        lazy var camera: CameraCoordinator = {
            let owner = CameraCoordinator(
                camera: platform.vision.camera, presentation: ui.camera, photos: photos, cache: cache,
                photoCues: platform.audio.cue(.camera), windows: ui.windows,
                makeRuntime: { [weak self] in
                    guard let self else { throw ActionsContainerError.stopped }
                    return try self.makeCameraRuntime()
                },
                connectPerception: { [weak self] session, mirrored, endpoint in
                    guard let self, let endpoints = self.endpoints else { throw ActionsContainerError.unavailable }
                    try endpoints.presentation.bindCamera(endpoint)
                    defer { endpoints.presentation.unbindCamera(endpoint) }
                    try await self.connectVision(session, mirrored, endpoint)
                })
            observedCamera = owner
            return owner
        }()

        func stateReaders() async throws -> [String: ActionsStateSnapshot.Reader] {
            var readers = try await bluetooth.service.stateReaders()
            if let camera = observedCamera {
                readers["actions.camera"] = ActionsStateSnapshot.reader(of: camera) { try await $0.stateSnapshot() }
            } else {
                readers["actions.camera"] = ActionsStateSnapshot.reader(of: self) { _ in
                    .init(path: "actions.camera", runtime: ["created": .flag(false)])
                }
            }
            readers["actions.camera.preview"] = ActionsStateSnapshot.reader(of: self) {
                try await $0.previewStateSnapshot()
            }
            return readers
        }
        private func previewStateSnapshot() throws -> ActionsStateSnapshot {
            guard let camera = observedCamera else { return .init(path: "actions.camera.preview") }
            let snapshot = try camera.previewSnapshot(scope: "inspection")
            let value = try JSONDecoder().decode([String: ActionsStateSnapshot.Value].self, from: snapshot.facts)
            return .init(path: "actions.camera.preview", business: value)
        }
        func prepare(_ request: ActionsBusinessRequest) throws -> ActionsBusinessBindings {
            let files = self.files
            let providerService = ProviderSettingsService(
                store: ProviderSettingsStore(
                    credentials: SettingsCredentialAdapter(),
                    document: {
                        try files.document(UserSettingsDocument.self, in: files.settings, name: "settings.json")
                    }),
                runtime: SettingsProviderAdapter.runtime(
                    language: model.language,
                    beginChange: request.maintenance.beginSettings, endChange: request.maintenance.endSettings))
            let providerSettings = ProviderSettingsRequests(service: providerService)
            let discovery = ProviderDiscoveryRequests(discover: SettingsProviderAdapter.discoverModels)
            let providerPresentation = ProviderPresentationAdapter(
                state: ui.settings.presentation, sessionID: request.sessionID,
                settings: providerSettings)
            let history = HistoryPresentationAdapter(
                state: ui.history.presentation, store: request.conversations, sessionID: request.sessionID)
            let endpoints = ActionEndpoints(
                cameraControl: camera, rootSessionID: request.sessionID, activity: request.activity,
                effects: ui.home.effects, expressions: ui.home.expressions, homeBluetooth: ui.home.conversation,
                deviceBluetooth: bluetooth.state)
            self.endpoints = endpoints
            let presentation = endpoints.presentation
            let resources =
                [
                    ResourceDefinition(
                        id: CameraCoordinator.captureResource, allowedOwners: [CameraCoordinator.resourceOwnerID],
                        requiresLease: true,
                        stop: { [platform] in await platform.vision.camera.stop() })
                ]
                + request.resourcePolicies.map { policy in
                    ResourceDefinition(policy: policy, stop: { [bluetooth] in await bluetooth.stopAgentActions() })
                }
            let robot = NexArmBehaviorAdapter(bluetooth: bluetooth, activity: request.failures)
            let mutations = HistoryMutationService(
                store: request.conversations, summarizeTitle: request.summarizeTitle,
                archiveChanged: { message in
                    do { try await history.refreshAfterMutation(message: message) } catch {
                        await history.recordRefreshFailure(error)
                    }
                }, titlePositions: request.titlePositions)
            let resourceAdapter = ModelResourceCapabilityAdapter(
                artifacts: request.maintenance.artifacts,
                quiesce: request.maintenance.quiesce, bindSpeech: request.maintenance.bindSpeech)
            let preferences = ModelResourcePreferencesService(
                store: {
                    try files.document(
                        ModelResourcePreferences.self, in: files.models, name: "download-source.json",
                        maximumBytes: 4096)
                }, validate: { try await SettingsModelResourcesAdapter.validatePreferences($0) },
                installed: {
                    let manager = try await request.maintenance.artifacts()
                    return Set(
                        try await manager.artifactSnapshots().filter { $0.phase == .installed }.map { $0.artifact.id })
                })
            let album = PhotoAlbumService(
                photos: photos, export: { [platform] data in try await platform.vision.savePhoto(data) },
                exportVideo: { [platform] file in try await platform.vision.saveVideo(file) })
            let island = IslandPresentationService(state: ui.island)
            let workspace = ArtifactWorkspace(
                disk: try files.file(files.workspaces), catalog: try workspaces())
            let exports = ArtifactExportService(workspace: workspace, disk: try files.file(files.workspaces))
            let artifactPresentation = ArtifactPresentation(
                pages: ui.web, windows: ui.windows, disk: try files.file(files.workspaces))
            let artifacts = ArtifactService(
                workspace: workspace,
                prepare: { id, deleting in try await artifactPresentation.prepare(id: id, deleting: deleting) },
                capture: { id in try await artifactPresentation.snapshot(id: id) },
                describe: { id, title, subtitle in
                    await artifactPresentation.describe(id: id, title: title, subtitle: subtitle)
                },
                present: { id, title, entry, files, preview in
                    try await artifactPresentation.present(
                        id: id, title: title, entry: entry, files: files, preview: preview)
                })
            let web = WebExecutionService(
                page: ui.web, windows: ui.windows,
                pageForWindow: { [pages = ui.web] id in pages.sessions[id] },
                saveImage: { [photos] data, input in
                    try await photos.save(
                        data,
                        owner: StorageOwner(
                            namespace: "photos", source: input.context.source,
                            session: input.context.sessionID, input: input.context.inputID))
                })
            let windowExecution = WindowExecutionService(
                state: ui.windows,
                lifecycles: [
                    WindowContent.camera.rawValue: camera, WindowContent.web.rawValue: web,
                    WindowContent.artifact.rawValue: artifactPresentation,
                ])
            let assembly = try BehaviorAssembly(
                presentation: presentation, playback: endpoints.speech, pose: presentation,
                historyPresentation: history, camera: endpoints.camera,
                history: HistoryQueryService(store: request.conversations),
                historyMutations: mutations,
                fullHistory: HistoryFullReadService(store: request.conversations),
                album: album, windows: windowExecution, web: web, artifacts: artifacts, island: island,
                modelResources: resourceAdapter,
                resourcePreferences: preferences,
                resourceInventory: resourceAdapter,
                resourcePresentation: ResourcePresentationAdapter(
                    state: ui.modelResources.presentation, sessionID: request.sessionID,
                    provider: providerPresentation, navigation: ui.navigation.presentation,
                    acknowledge: request.maintenance.resourcesPresented),
                providerDiscovery: discovery, providerSettings: providerSettings, device: device,
                feedback: presentation, effects: presentation, listening: endpoints.speech,
                listeningGesture: endpoints.speech,
                detection: endpoints.speech, taskControl: endpoints.tasks, loading: presentation,
                runtimeFailures: presentation, bluetoothStatus: presentation,
                gesture: { value, input in try await robot.gesture(value, input) },
                shakeBase: { value, input in try await robot.shakeBase(value, input) },
                aim: { base, pitch, input in try await robot.aim(base, pitch, input) })
            device.activity = request.failures
            try actions.configure(
                assembly,
                cleanup: [
                    { await mutations.shutdown() }, { await windowExecution.stop() }, { await web.stop() },
                    { try await artifacts.shutdown() },
                    { await artifactPresentation.setSceneActive(false) },
                    {
                        island.stop()
                    },
                ],
                workers: [
                    { [camera] in await camera.observe() },
                    { [bluetooth] in await bluetooth.run() },
                ],
                invalidateNative: { [camera, bluetooth] in
                    camera.setForeground(false)
                    bluetooth.setForeground(false)
                },
                nativeForeground: { [camera, bluetooth, artifactPresentation] active in
                    if active {
                        camera.setForeground(true)
                        bluetooth.setForeground(true)
                        await artifactPresentation.setSceneActive(true)
                    } else {
                        await artifactPresentation.setSceneActive(false)
                        var failure: (any Error)?
                        do { try await camera.shutdown() } catch { failure = error }
                        await bluetooth.waitUntilIdle()
                        if let failure { throw failure }
                    }
                })
            return ActionsBusinessBindings(
                executor: actions.execution, catalog: try actions.catalog(),
                artifactStreaming: artifacts, writerArtifacts: exports,
                writerModel: { [model] in
                    let selected = try await providerService.writerConfiguration()
                    let configuration =
                        try selected.enabled
                        ? OpenAIChatConfiguration(
                            baseURL: OpenAIChatConfiguration.endpoint(selected.url), apiKey: selected.key,
                            model: selected.model, thinking: selected.writerThinking ? .enabled : .minimum) : nil
                    return try await model.language.chatModel(configuration: configuration)
                },
                settings: providerSettings, discovery: discovery, providerPresentation: providerPresentation,
                tasks: endpoints.tasks,
                resources: resources,
                connectionFacts: { [bluetooth] in try bluetooth.service.observeConnectionFacts() },
                trackingAvailable: { [bluetooth] in await bluetooth.trackingAvailable },
                bindTracking: { [bluetooth] in bluetooth.trackingInputAvailable = $0 },
                bindDeferredFailure: { [device] in device.deliverActionResult = $0 },
                bindResourceRun: { [bluetooth] run in
                    bluetooth.withMotorResources = { motors, operation in
                        let requested = Set(motors.map { ResourceID(rawValue: "nexarm.motor.\($0)") })
                        try await run(requested, operation)
                    }
                }, observeTranscript: { text, session in try presentation.observeTranscript(text, sessionID: session) },
                observeEmpty: { session in try presentation.observeEmptyUtterance(sessionID: session) },
                output: { await presentation.output($0) },
                decodeResources: { try SettingsModelResourcesAdapter.items($0) },
                makeVoice: { [self] in try makeVoice($0) })
        }
        private func makeVoice(_ host: ActionsVoiceHost) throws -> ActionsVoiceExecution {
            guard let endpoints else { throw ActionsContainerError.unavailable }
            let speech = model.speech
            let lifecycle = VoiceSessionCoordinator(
                runtime: VoiceSessionConnections(
                    endpoints: endpoints,
                    interactionSessionID: host.sessionID, cancelReply: host.cancelReply,
                    adaptFailure: host.adaptFailure,
                    playbackChanged: host.playbackChanged,
                    playbackSpectrum: { [island = ui.island] values, active in
                        do { try island.spectrum(values, active: active, generation: island.generation) } catch {
                            island.report(error)
                        }
                    }
                ),
                state: ui.home.conversation, audio: platform.audio.io(.voice), cue: platform.audio.cue(.voice),
                haptic: platform.audio.haptic(.voice), recognition: speech.recognition, synthesis: speech.synthesis,
                voiceActivity: speech.voiceActivity)
            if camera.recordingAudioHeld { lifecycle.holdVideoAudioOnBinding() }
            camera.acquireRecordingAudio = { [weak lifecycle] in
                guard let lifecycle else { throw ActionsContainerError.unavailable }
                try await lifecycle.beginVideoAudio()
            }
            camera.releaseRecordingAudio = { [weak lifecycle] resume in
                try await lifecycle?.endVideoAudio(resume: resume)
            }
            let detection = AudioDetectionPresentation(
                state: ui.diagnostics.audioDetection,
                endpoint: Actions.AudioDetectionSession(
                    connections: host.detection,
                    execution: AudioDetectionExecution(
                        audio: platform.audio.io(.detection),
                        beforeStart: { [weak lifecycle] in await lifecycle?.stopVoiceAndWait() })))
            let diagnostic = SpeechDiagnosticWorkflow(
                state: ui.diagnostics.speech, player: platform.audio.io(.diagnostic),
                provider: speech.synthesis, load: { try await speech.warmup(.synthesis) },
                unload: { try await speech.unload(.synthesis) })
            endpoints.speech.audioDetection = detection
            lifecycle.beforeVoiceStart = { [weak detection] in await detection?.stopAndWait() }
            try actions.addCleanup {
                await lifecycle.shutdown()
                await detection.stopAndWait()
                try await diagnostic.stopAndWait()
            }
            return ActionsVoiceExecution(
                lifecycle: lifecycle,
                spectrum: MicrophoneSpectrumPresentation(state: ui.home.conversation), diagnostic: diagnostic,
                stopDiagnostic: { try await diagnostic.stopAndWait() }, detection: detection,
                validate: { [model] in
                    try await ChatDiagnosticWorkflow.validate(chat: model.language) {
                        try await model.speech.warmup(.recognition)
                        try await model.language.warmup()
                    }
                })
        }
    }

    @MainActor @available(iOS 27, *)
    final class ActionsCameraHost: ActionsCameraAccess {
        let camera: CameraCoordinator
        init(_ camera: CameraCoordinator) { self.camera = camera }
        func pauseVisionForModelMaintenance() async { await camera.pauseVisionForModelMaintenance() }
        func previewSnapshot(scope: String) async throws -> MultimodalContextSnapshot {
            try camera.previewSnapshot(scope: scope)
        }
        func resetPreviewSelection(scope: String) async { camera.previews.reset(scope: scope) }
        func readPhoto(_ id: String, source: String, sessionID: String, inputID: String) async throws -> Data {
            try await camera.readPhoto(id, source: source, sessionID: sessionID, inputID: inputID)
        }
    }
    @MainActor final class ActionsDeviceHost: ActionsDeviceAccess {
        let bluetooth: BluetoothWorkflow
        let device: NexArmDeviceAdapter
        init(bluetooth: BluetoothWorkflow, device: NexArmDeviceAdapter) {
            self.bluetooth = bluetooth
            self.device = device
        }
        func openPage() { bluetooth.openPage() }
        func closePage() { bluetooth.closePage() }
        func openSystemSettings() { bluetooth.openSystemSettings() }
        var initialFence: String { device.fence }
        func stopFence() -> String { device.stopFence() }
    }

#endif

#if os(iOS)
    @available(iOS 27, *)
    extension ActionsContainer {
        public func configureBusiness(request: ActionsBusinessRequest) throws -> ActionsBusinessBindings {
            guard state == .cold else { throw ActionsContainerError.alreadyConfigured }
            guard let assembly = businessOwner as? ActionsBusinessAssembly else {
                throw ActionsContainerError.missingBinding
            }
            return try assembly.prepare(request)
        }
    }
#endif

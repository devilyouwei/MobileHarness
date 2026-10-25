#if os(iOS)
    import CallRuntime
    import Foundation
    import FunctionContracts
    import ModelKit
    import ModelKitDefaults
    import ModelKitRuntime
    import PlatformKit
    import StorageChat
    import StorageCore
    import StorageFiles
    import StorageMedia
    import UI

    /// Module-owned business assembly. Its lifetime is retained and closed by ActionsContainer.
    @MainActor @available(iOS 27, *)
    public final class ActionsBusinessAssembly {
        unowned let actions: ActionsContainer
        let files: FilesContainer
        let model: ModelContainer
        let platform: PlatformContainer
        let ui: UIContainer
        let photos: CapturedPhotoStore
        public let bluetooth: BluetoothWorkflow
        public let device: NexArmDeviceAdapter
        let previewHistory: @MainActor (HistoryTurn) -> String
        public lazy var facades = makeUIFacades()
        var stopInteractions: @MainActor () async -> Void = {}
        private let makeCameraRuntime: @MainActor () throws -> CameraRuntimeDependencies
        private let connectVision: @MainActor (String, Bool, any CameraOutputHandling) async throws -> Void
        private var endpoints: ActionEndpoints?
        public init(
            actions: ActionsContainer, files: FilesContainer, model: ModelContainer,
            platform: PlatformContainer, ui: UIContainer, photos: CapturedPhotoStore, bluetooth: BluetoothWorkflow,
            previewHistory: @escaping @MainActor (HistoryTurn) -> String,
            makeCameraRuntime: @escaping @MainActor () throws -> CameraRuntimeDependencies,
            connectVision: @escaping @MainActor (String, Bool, any CameraOutputHandling) async throws -> Void
        ) {
            self.actions = actions
            self.files = files
            self.model = model
            self.platform = platform
            self.ui = ui
            self.photos = photos
            self.bluetooth = bluetooth
            self.device = NexArmDeviceAdapter(bluetooth: bluetooth)
            self.previewHistory = previewHistory
            self.makeCameraRuntime = makeCameraRuntime
            self.connectVision = connectVision
        }
        public lazy var camera = CameraCoordinator(
            camera: platform.vision.camera, presentation: ui.camera, photos: photos,
            photoCues: platform.audio.cue(.camera),
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

        public func cameraContext() async throws -> Data { try JSONEncoder().encode(await camera.contextSnapshot()) }
        public func deviceContext() async throws -> Data {
            try JSONEncoder().encode(await bluetooth.service.contextSnapshot())
        }
        public func prepare(_ request: ActionsBusinessRequest) throws -> ActionsBusinessBindings {
            let files = self.files
            let providerSettings = ProviderSettingsRequests(
                service: ProviderSettingsService(
                    store: ProviderSettingsStore(
                        credentials: SettingsCredentialAdapter(),
                        document: {
                            try files.document(UserSettingsDocument.self, in: files.settings, name: "settings.json")
                        }),
                    runtime: SettingsProviderAdapter.runtime(
                        language: model.language,
                        beginChange: request.maintenance.beginSettings, endChange: request.maintenance.endSettings)))
            let discovery = ProviderDiscoveryRequests(discover: SettingsProviderAdapter.discoverModels)
            let providerPresentation = ProviderPresentationAdapter(
                state: ui.settings.presentation, sessionID: request.sessionID,
                settings: providerSettings, discovery: discovery)
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
                photos: photos, export: { [platform] data in try await platform.vision.savePhoto(data) })
            let assembly = try BehaviorAssembly(
                presentation: presentation, playback: endpoints.speech, pose: presentation,
                historyPresentation: history, camera: endpoints.camera,
                history: HistoryQueryService(store: request.conversations),
                historyMutations: mutations,
                fullHistory: HistoryFullReadService(
                    store: request.conversations,
                    photo: { [photos] id, input in try await photos.readForInput(id, source: "assistant", input: input)
                    }),
                album: album, modelResources: resourceAdapter, resourcePreferences: preferences,
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
                    { await mutations.shutdown() }
                ], workers: [{ [camera] in await camera.observe() }, { [bluetooth] in await bluetooth.run() }],
                invalidateNative: { [camera, bluetooth] in
                    camera.setForeground(false)
                    bluetooth.setForeground(false)
                })
            return ActionsBusinessBindings(
                executor: actions.execution, catalog: try actions.catalog(),
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
                    interactionSessionID: host.sessionID, cancelReply: host.cancelReply, adaptFailure: host.adaptFailure
                ),
                state: ui.home.conversation, audio: platform.audio.io(.voice), cue: platform.audio.cue(.voice),
                haptic: platform.audio.haptic(.voice), recognition: speech.recognition, synthesis: speech.synthesis,
                voiceActivity: speech.voiceActivity)
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

#endif

#if os(iOS)
    @available(iOS 27, *)
    extension ActionsContainer {
        public func configureBusiness(_ assembly: ActionsBusinessAssembly) throws {
            guard state == .cold, businessOwner == nil else { throw ActionsContainerError.alreadyConfigured }
            businessOwner = assembly
            try registerPreparationCleanup { try await assembly.camera.shutdown() }
            try registerPreparationCleanup { try await assembly.bluetooth.shutdown() }
            try registerPreparationCleanup {
                await assembly.stopInteractions()
            }
        }
    }
#endif

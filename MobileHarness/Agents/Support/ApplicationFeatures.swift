import Foundation
import StorageCache
import StorageFiles
import StorageState

/// Joins a session without letting source completion race away its terminal diagnostic.
public enum VisionPipelineWorkflow {
    public enum Failure: Error, Sendable { case inputEnded, outputEnded, unexpectedCancellation }
    private enum Branch: Sendable { case input, output, monitor }
    public static func run(
        input: @escaping @Sendable () async throws -> Void,
        inputFailed: @escaping @Sendable (any Error) async -> Void,
        output: @escaping @Sendable () async throws -> Void,
        stopInput: @escaping @Sendable () async -> Void,
        monitor: (@Sendable () async throws -> Void)? = nil
    ) async throws {
        do {
            try await withThrowingTaskGroup(of: Branch.self) { group in
                group.addTask {
                    do {
                        try await input()
                        try Task.checkCancellation()
                        await inputFailed(Failure.inputEnded)
                    } catch is CancellationError {
                        if !Task.isCancelled { await inputFailed(Failure.unexpectedCancellation) }
                    } catch {
                        await inputFailed(error)
                    }
                    return .input
                }
                group.addTask {
                    try await output()
                    return .output
                }
                if let monitor {
                    group.addTask {
                        try await monitor()
                        return .monitor
                    }
                }
                defer { group.cancelAll() }
                while let branch = try await group.next() {
                    if case .output = branch {
                        await stopInput()
                        group.cancelAll()
                        break
                    }
                }
                try Task.checkCancellation()
            }
        } catch {
            await stopInput()
            throw error
        }
        await stopInput()
    }
}

#if os(iOS)
    import ActionBindings
    import StorageDevices
    import Actions
    import AgentCore
    import Gateway
    import Agents
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
    public final class ApplicationFeatures {
        @ObservationIgnored private let containerFailures: ContainerFailureChannel
        @ObservationIgnored private let repositories: @Sendable () throws -> ApplicationRepositories
        @ObservationIgnored private let capturedPhotos: CapturedPhotoStore
        @ObservationIgnored private let audio: AudioContainer
        @ObservationIgnored private let cameraDevice: any CameraCapturing
        let cameraState: CameraState
        @ObservationIgnored private let cameraPresentation: any CameraPresenting
        @ObservationIgnored private let cameraFactory: @MainActor (CameraIntegrationBindings) -> CameraCoordinator
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
        let devicesUI: UIDeviceSettingsContainer
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
            repositories: @escaping @Sendable () throws -> ApplicationRepositories, state: StateContainer,
            cache: CacheContainer, files: FilesContainer, photos: CapturedPhotoStore,
            camera: any CameraCapturing, cameraState: CameraState, cameraPresentation: any CameraPresenting,
            makeCamera: @escaping @MainActor (CameraIntegrationBindings) -> CameraCoordinator,
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
        private(set) var container: InteractionServices?
        @ObservationIgnored private var runtimeValue: AgentServices?
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
                    let state = self.cameraState
                    let displayedMediaID = state.capturedPhoto?.id
                    let savedMediaID = state.savedMediaID
                    guard
                        state.capturedPhoto == nil
                            || displayedMediaID.flatMap(BusinessRecordID.init(rawValue:))?.kind == .media,
                        state.savedMediaID == nil
                            || savedMediaID.flatMap(BusinessRecordID.init(rawValue:))?.kind == .media
                    else { throw CommunicationError.invalidPayload }
                    let value = CameraStateObservation(
                        sequence: 1, observedAt: Date(timeIntervalSince1970: 0),
                        enabled: state.isEnabled, visible: state.isVisible, busy: state.isBusy || state.photoBusy,
                        needsSettings: state.needsSettings, facing: state.facing == .front ? .front : .back,
                        displayedMediaID: displayedMediaID, savedMediaID: savedMediaID,
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
                                displayedMediaID: value.displayedMediaID, savedMediaID: value.savedMediaID,
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
                            "bluetooth": device, "cameraEnabled": self.cameraState.isEnabled,
                            "cameraVisible": self.cameraState.isVisible,
                            "cameraNeedsSettings": self.cameraState.needsSettings,
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
                            .init(category: .devices, sequence: self.environmentSequence, value: self.environmentSample)
                        )
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
        private func artifactManager() async throws -> any ModelArtifactsManaging {
            try await modelArtifacts.prepare()
            return modelArtifacts
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
        var modelResources: ModelResourcesState { resourcesUI.state }
        @ObservationIgnored lazy var modelResourceControls = ModelResourceInteractionWorkflow(
            state: resourcesUI.presentation, operations: modelResourcesWorkflow)
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
        var settings: SettingsState { settingsUI.state }
        @ObservationIgnored lazy var settingsControls = SettingsInteractionWorkflow(
            state: settingsUI.presentation, operations: settingsWorkflow,
            defaultModel: SettingsProviderAdapter.initial.model)
        @ObservationIgnored lazy var cameraControls = makeCameraControls()
        private func makeCameraControls() -> CameraInteractionWorkflow {
            CameraInteractionWorkflow(
                presentation: cameraPresentation,
                perform: { [weak self] intent, facing, mediaID in
                    guard let self else { throw CancellationError() }
                    _ = try await self.runtime().photographerIntents.perform(intent, facing: facing, mediaID: mediaID)
                })
        }
        var navigation: NavigationState { navigationUI.state }
        @ObservationIgnored lazy var deviceControl = DeviceControlAdapter(bluetooth: bluetooth)
        @ObservationIgnored lazy var bluetoothControls = makeBluetoothControls()
        private func makeBluetoothControls() -> BluetoothInteractionWorkflow {
            BluetoothInteractionWorkflow(
                state: devicesUI.presentation,
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
            navigationUI.presentation.show(destination)
        }
        @ObservationIgnored lazy var camera = makeCamera()
        private func makeCamera() -> CameraCoordinator {
            cameraFactory(
                CameraIntegrationBindings(
                    nativeEvent: { [weak self] event in
                        guard let self else { throw CancellationError() }
                        let runtime = try await self.runtime()
                        try await runtime.input.publish(
                            DeviceInputAdapter.cameraEvent(event, sessionID: runtime.interactionSessionID))
                    },
                    makeRuntime: { [weak self] in
                        guard let self else { throw CancellationError() }
                        return try self.runtime().cameraDependencies
                    },
                    connectFrames: { [weak self] frames, sessionID, mirrored, endpoint in
                        guard let self else { throw CancellationError() }
                        do {
                            try await self.runVision(
                                frames: frames, sessionID: sessionID, mirrored: mirrored, endpoint: endpoint)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            let diagnostic = AgentFailureDiagnostic(
                                category: .runtime, code: "vision.pipeline.failed", detail: String(describing: error))
                            self.runtimeValue?.actionActivity.recordFailure(
                                title: "视觉会话异常", source: "visionPerception", message: diagnostic.detail,
                                failureCode: diagnostic.code,
                                context: .init(workerID: "visionPerception", sessionID: sessionID),
                                diagnostic: diagnostic)
                            throw error
                        }
                    }))
        }

        /// Role lifecycle and tracking policy stay here; native-to-Signal conversion belongs to Gateway.
        private func runVision(
            frames: AsyncThrowingStream<CameraFrame, Error>, sessionID: String, mirrored: Bool,
            endpoint: any CameraOutputHandling
        ) async throws {
            let runtime = try runtime()
            let pose = visionModels
            let vision = try VisionPerceptionAgent(
                pose: pose, sessionID: sessionID, mirroredGaze: mirrored, context: runtime.visionContext())
            try runtime.presentation.bindCamera(endpoint)
            defer { runtime.presentation.unbindCamera(endpoint) }
            try await runtime.manager.register(vision, sessionID: sessionID)
            var tracking = false
            do {
                try await runtime.photographerIntents.attachTracking(sessionID: sessionID)
                tracking = true
                try await runtime.manager.start(.visionPerception)
                let consumer = try await runtime.output.consumer(for: vision)
                let connection = DeviceInputConnection(frames: frames, sessionID: sessionID, input: runtime.input)
                try await VisionPipelineWorkflow.run(
                    input: { try await connection.wait() },
                    inputFailed: { error in await vision.failInput(error) },
                    output: {
                        try await IndependentOutputWorkflow.consumeSignals(
                            vision.outputs,
                            replacementKey: { VisionPerceptionAgent.outputReplacementKey($0.output) },
                            onMediaExpired: { envelope in
                                await vision.presentationFinished(
                                    failure: "Pose media expired before presentation; sequence=\(envelope.sequence)")
                            },
                            dispatch: { envelope in
                                try Task.checkCancellation()
                                if case .control(let value) = envelope.output, value.hasPrefix("agent.error:") {
                                    // Present before dispatch: a transport rejection must not hide the failure.
                                    await endpoint.visionStatus("姿态识别已停止，请重试", sessionID: sessionID)
                                }
                                let result = try await consumer.execute(envelope)
                                if envelope.media != nil, !result.isCancellationOnly {
                                    let details = [
                                        result.failure, result.tool?.isError == true ? result.tool?.value : nil,
                                    ]
                                    .compactMap { $0 }.joined(separator: "; ")
                                    await vision.presentationFinished(
                                        failure: result.isError
                                            ? (details.isEmpty ? "Media Tool execution failed" : details) : nil)
                                }
                            })
                        try Task.checkCancellation()
                        guard await vision.status().lifecycle == .failed else {
                            throw VisionPipelineWorkflow.Failure.outputEnded
                        }
                    },
                    stopInput: { await connection.stop() },
                    monitor: {
                        try await self.monitorVision(vision, endpoint: endpoint, runtime: runtime, sessionID: sessionID)
                    })
                if tracking { await runtime.photographerIntents.detachTracking(sessionID: sessionID) }
                try await runtime.manager.remove(.visionPerception)
                await runtime.output.cancel(sessionID: sessionID)
                try Task.checkCancellation()
            } catch {
                if tracking { await runtime.photographerIntents.detachTracking(sessionID: sessionID) }
                try? await runtime.manager.remove(.visionPerception)
                await runtime.output.cancel(sessionID: sessionID)
                throw error
            }
        }

        private func monitorVision(
            _ vision: VisionPerceptionAgent, endpoint: any CameraOutputHandling,
            runtime: AgentServices, sessionID: String
        ) async throws {
            var reported: String?
            while true {
                try await Task.sleep(for: .seconds(1))
                try Task.checkCancellation()
                guard await vision.status().lifecycle == .running else { continue }
                let health = await vision.health()
                if let diagnostic = health.diagnostic {
                    guard reported != diagnostic.code else { continue }
                    reported = diagnostic.code
                    runtime.actionActivity.recordFailure(
                        title: "视觉管线无进展", source: "visionPerception", message: diagnostic.detail,
                        failureCode: diagnostic.code,
                        context: .init(workerID: "visionPerception", sessionID: sessionID, inputID: health.inputID),
                        diagnostic: diagnostic)
                    await endpoint.visionStatus("姿态识别长时间无有效结果，请查看日志", sessionID: sessionID)
                } else if reported != nil {
                    reported = nil
                    await endpoint.visionStatus(nil, sessionID: sessionID)
                }
            }
        }

        private var historyState: ConversationHistoryState { historyUI.state }
        @ObservationIgnored lazy var history = makeHistory()
        private func makeHistory() -> ConversationHistoryWorkflow {
            return ConversationHistoryWorkflow(
                state: historyUI.presentation,
                prepare: { [weak self] in
                    guard let self else { throw CancellationError() }
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
                readConversation: { [weak self] id in
                    guard let self else { throw CancellationError() }
                    return try self.historyConversation(await self.runtime().historyIntents.query(.conversation(id)))
                },
                readPhoto: { [weak self] id, inputID in
                    guard let self else { throw CancellationError() }
                    guard
                        case .photo(let value) = try await self.runtime().historyIntents.query(
                            .photo(id: id, inputID: inputID))
                    else {
                        throw CommunicationError.invalidPayload
                    }
                    return value
                },
                readMessage: { [weak self] id in
                    guard let self else { throw CancellationError() }
                    return try self.historyConversation(await self.runtime().historyIntents.query(.message(id)))
                },
                readPage: { [weak self] id, after, taskID in
                    guard let self else { throw CancellationError() }
                    return try self.historyConversation(
                        await self.runtime().historyIntents.query(.page(id: id, after: after, taskID: taskID)))
                },
                readArchives: { [weak self] cursor in
                    guard let self else { throw CancellationError() }
                    guard
                        case .archives(let values) = try await self.runtime().historyIntents.query(
                            .archives(before: cursor))
                    else {
                        throw CommunicationError.invalidPayload
                    }
                    return try values.map(HistoryPresentationAdapter.conversation)
                })
        }
        private func historyConversation(_ result: MemoryHistoryReadResult) throws -> HistoryConversation {
            guard case .conversation(let value) = result else { throw CommunicationError.invalidPayload }
            return try HistoryPresentationAdapter.conversation(value)
        }
        #if os(iOS)
            var recordDestinations: [AgentRecordDestination] {
                let state = historyState
                let controls = history
                return [
                    AgentRecordDestination(
                        id: "assistant", name: "Assistant 聊天记录", summary: "对话、Task 摘要与完整请求记录"
                    ) {
                        ConversationHistoryView(state: state, controls: controls)
                    }
                ]
            }
        #endif
        private func makeHistoryChat() async throws -> any ChatCapability {
            try await settingsControls.restore()
            await container?.lifecycle.beginSettingsChange()
            defer { container?.lifecycle.endSettingsChange() }
            try Task.checkCancellation()
            return languageModels
        }
        private func runtime() throws -> AgentServices {
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
            let runtime = try AgentServices(
                containerFailures: containerFailures, home: homeUI,
                state: stateStorage, cache: cacheStorage, files: filesStorage,
                chatRecords: try repositories().chat, taskRecords: try repositories().tasks,
                camera: cameraDevice,
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
                chatProvider: { [languageModels] in languageModels })
            runtimeValue = runtime
            return runtime
        }
        public func setAgentForeground(_ value: Bool) async throws {
            try await runtimeValue?.setForeground(value)
        }
        func setResourceObservationForeground(_ value: Bool) {
            cameraObservation.setForeground(value)
            environmentObservation.setForeground(value)
            resourceObservationForeground = value
            guard container != nil else { return }
            runtimeValue?.resourceObservation.setForeground(value)
        }
        @ObservationIgnored private var preparation: Task<Void, Error>?
        @ObservationIgnored private var bluetoothObservation: Task<Void, Never>?
        @ObservationIgnored private var cameraEvents: Task<Void, Never>?
        private var foreground = true
        func updateCameraAvailability() {
            camera.setForeground(foreground && navigation.path.isEmpty)
        }
        var isolatedPresentation: Bool {
            let arguments = ProcessInfo.processInfo.arguments
            return [
                "-gemma4-validation",
                "-moss-benchmark",
            ].contains { arguments.contains($0) }
        }
        func prepare(progress: @MainActor (String) -> Void) async throws {
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
            setResourceObservationForeground(false)
            container?.lifecycle.stopVoice(message: "已进入后台，按住双眼重新开始")
            container?.audioDetection.stop()
        }
        public func setForeground(_ value: Bool) {
            foreground = value
            guard !isolatedPresentation else { return }
            updateCameraAvailability()
            bluetooth.setForeground(value)
            setResourceObservationForeground(value)
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
            environmentWorker?.cancel()
            await environmentWorker?.value
            await cameraObservation.shutdown()
            await environmentObservation.shutdown()
            await runtimeValue?.resourceObservation.shutdown()
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
            let prepared = try await InteractionServices(
                home: homeUI, diagnostics: diagnosticsUI, language: languageModels, speech: speechModels,
                memoryPressure: memoryPressure, audio: audio, runtime: runtime(),
                modelName: { await workflow.modelName },
                progress: progress)
            try Task.checkCancellation()
            container = prepared
            runtimeValue?.resourceObservation.setForeground(resourceObservationForeground)
        }
    }

#endif

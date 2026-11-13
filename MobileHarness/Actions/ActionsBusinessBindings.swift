#if os(iOS)
    import Foundation
    import FunctionContracts
    import ModelKit
    import ModelKitDefaults
    import PlatformKit
    import StorageChat
    import StorageDevices
    import StorageDatabase
    import StorageFiles
    import StorageMedia
    import StorageCache
    import StorageCore
    import UI

    @MainActor public protocol ActionsCameraAccess: AnyObject {
        func pauseVisionForModelMaintenance() async
        func previewSnapshot(scope: String) async throws -> MultimodalContextSnapshot
        func resetPreviewSelection(scope: String) async
    }
    @MainActor public protocol ActionsDeviceAccess: AnyObject {
        func openPage()
        func closePage()
        func openSystemSettings()
        var initialFence: String { get }
        func stopFence() -> String
    }
    @MainActor public struct ActionsHostCapabilities {
        public let camera: any ActionsCameraAccess
        public let device: any ActionsDeviceAccess
        public let facades: ActionsUIFacades
    }
    @MainActor public struct ActionsDependencies {
        let cache: CacheContainer
        let files: FilesContainer
        let model: ModelContainer
        let platform: PlatformContainer
        let ui: UIContainer
        let workspaces: @Sendable () throws -> any WorkspaceRepository
        let media: @Sendable () throws -> any MediaRepository
        let devices: @Sendable () throws -> any DeviceRepository
        let makeCameraRuntime: @MainActor () throws -> CameraRuntimeDependencies
        let connectVision: @MainActor (String, Bool, any CameraOutputHandling) async throws -> Void
        public init(
            files: FilesContainer, cache: CacheContainer = CacheContainer(), model: ModelContainer,
            platform: PlatformContainer, ui: UIContainer,
            workspaces: @escaping @Sendable () throws -> any WorkspaceRepository,
            media: @escaping @Sendable () throws -> any MediaRepository,
            devices: @escaping @Sendable () throws -> any DeviceRepository,
            makeCameraRuntime: @escaping @MainActor () throws -> CameraRuntimeDependencies,
            connectVision: @escaping @MainActor (String, Bool, any CameraOutputHandling) async throws -> Void
        ) {
            self.cache = cache
            self.files = files
            self.model = model
            self.platform = platform
            self.ui = ui
            self.workspaces = workspaces
            self.media = media
            self.devices = devices
            self.makeCameraRuntime = makeCameraRuntime
            self.connectVision = connectVision
        }
    }
    public typealias ActionsUIFacades = ActionUIFacades<
        any CameraControlling, any ConversationHistoryControlling, any ModelResourcesControlling,
        any BluetoothControlling, any SettingsControlling, any ModelResourcesOperating, any SettingsOperating
    >

    public typealias ActionsBusinessRequest = ActionAssemblyRequest<
        AssistantHistoryStore,
        any ExecutionFailureReporting, any ModelArtifactsManaging, AssistantConversation
    >
    @MainActor public struct ActionsVoiceHost {
        public let sessionID: String
        public let cancelReply: @MainActor () async throws -> Void
        public let adaptFailure: @Sendable (any Error) -> any Error
        public let detection: AudioDetectionConnections
        public let playbackChanged: @Sendable (String, Bool) async -> Void
        public init(
            sessionID: String, cancelReply: @escaping @MainActor () async throws -> Void,
            detection: AudioDetectionConnections, adaptFailure: @escaping @Sendable (any Error) -> any Error,
            playbackChanged: @escaping @Sendable (String, Bool) async -> Void = { _, _ in }
        ) {
            self.sessionID = sessionID
            self.cancelReply = cancelReply
            self.detection = detection
            self.playbackChanged = playbackChanged
            self.adaptFailure = adaptFailure
        }
    }
    @MainActor public struct ActionsVoiceExecution {
        public let lifecycle: VoiceSessionCoordinator
        public let spectrum: any SpectrumPresenting
        public let diagnostic: any SpeechDiagnosticControlling
        public let stopDiagnostic: @MainActor () async throws -> Void
        public let detection: AudioDetectionPresentation
        public let validate: @Sendable () async throws -> String
        public init(
            lifecycle: VoiceSessionCoordinator, spectrum: any SpectrumPresenting,
            diagnostic: any SpeechDiagnosticControlling, stopDiagnostic: @escaping @MainActor () async throws -> Void,
            detection: AudioDetectionPresentation, validate: @escaping @Sendable () async throws -> String
        ) {
            self.lifecycle = lifecycle
            self.spectrum = spectrum
            self.diagnostic = diagnostic
            self.stopDiagnostic = stopDiagnostic
            self.detection = detection
            self.validate = validate
        }
    }
    @MainActor public struct ActionsBusinessBindings {
        public let readWebScreenshot: @Sendable (String) async throws -> MultimodalContextSnapshot
        public let artifactStreaming: (any ArtifactStreaming)?
        public let writerArtifacts: (any WriterArtifactsControlling)?
        public let writerModel: (@Sendable () async throws -> ChatModel)?
        public let inputQueueStatus: @MainActor @Sendable (Int, Int) -> Void
        public let decisionStatus: @MainActor @Sendable (String) -> Void
        public let decisionConfiguration:
            (@Sendable () async throws -> (Bool, (@Sendable () async throws -> ChatModel)?))?
        public let executor: ActionsExecutionPort
        public let catalog: ActionCatalogSnapshot
        public let settings: any ProviderSettingsStaging
        public let discovery: any ProviderDiscoveryStaging
        public let providerPresentation: any ProviderPresentationRegistering
        public let tasks: any TaskControlBinding
        public let resources: [ResourceDefinition]
        public let connectionFacts:
            @MainActor @Sendable () throws -> AsyncThrowingStream<NexArmConnectionFacts, any Error>
        public let trackingAvailable: @Sendable () async -> Bool
        public let bindTracking: @MainActor (@escaping @Sendable () async -> Bool) -> Void
        public let bindDeferredFailure: @MainActor (@escaping @Sendable (DeferredActionFailure) async -> Bool) -> Void
        public let bindResourceRun:
            @MainActor (
                @escaping @Sendable (Set<ResourceID>, @escaping @Sendable () async throws -> Void) async throws -> Void
            ) -> Void
        public let observeTranscript: @MainActor @Sendable (String, String) throws -> Void
        public let output: @Sendable (ActionOutputObservation) async -> Void
        public let decodeResources: @Sendable (String) throws -> ModelResourceViewSnapshot
        public let makeVoice: @MainActor (ActionsVoiceHost) throws -> ActionsVoiceExecution
        public init(
            executor: ActionsExecutionPort, catalog: ActionCatalogSnapshot,
            readWebScreenshot: @escaping @Sendable (String) async throws -> MultimodalContextSnapshot,
            artifactStreaming: (any ArtifactStreaming)? = nil,
            writerArtifacts: (any WriterArtifactsControlling)? = nil,
            writerModel: (@Sendable () async throws -> ChatModel)? = nil,
            decisionConfiguration: (@Sendable () async throws -> (Bool, (@Sendable () async throws -> ChatModel)?))? =
                nil,
            decisionStatus: @escaping @MainActor @Sendable (String) -> Void = { _ in },
            inputQueueStatus: @escaping @MainActor @Sendable (Int, Int) -> Void = { _, _ in },
            settings: any ProviderSettingsStaging, discovery: any ProviderDiscoveryStaging,
            providerPresentation: any ProviderPresentationRegistering, tasks: any TaskControlBinding,
            resources: [ResourceDefinition],
            connectionFacts:
                @escaping @MainActor @Sendable () throws -> AsyncThrowingStream<NexArmConnectionFacts, any Error>,
            trackingAvailable: @escaping @Sendable () async -> Bool,
            bindTracking: @escaping @MainActor (@escaping @Sendable () async -> Bool) -> Void,
            bindDeferredFailure:
                @escaping @MainActor (@escaping @Sendable (DeferredActionFailure) async -> Bool) -> Void,
            bindResourceRun:
                @escaping @MainActor (
                    @escaping @Sendable (Set<ResourceID>, @escaping @Sendable () async throws -> Void) async throws ->
                        Void
                ) -> Void,
            observeTranscript: @escaping @MainActor @Sendable (String, String) throws -> Void,
            output: @escaping @Sendable (ActionOutputObservation) async -> Void,
            decodeResources: @escaping @Sendable (String) throws -> ModelResourceViewSnapshot,
            makeVoice: @escaping @MainActor (ActionsVoiceHost) throws -> ActionsVoiceExecution
        ) {
            self.readWebScreenshot = readWebScreenshot
            self.artifactStreaming = artifactStreaming
            self.writerArtifacts = writerArtifacts
            self.writerModel = writerModel
            self.decisionConfiguration = decisionConfiguration
            self.decisionStatus = decisionStatus
            self.inputQueueStatus = inputQueueStatus
            self.executor = executor
            self.catalog = catalog
            self.settings = settings
            self.discovery = discovery
            self.providerPresentation = providerPresentation
            self.tasks = tasks
            self.resources = resources
            self.connectionFacts = connectionFacts
            self.trackingAvailable = trackingAvailable
            self.bindTracking = bindTracking
            self.bindDeferredFailure = bindDeferredFailure
            self.bindResourceRun = bindResourceRun
            self.observeTranscript = observeTranscript
            self.output = output
            self.decodeResources = decodeResources
            self.makeVoice = makeVoice
        }
    }

#endif

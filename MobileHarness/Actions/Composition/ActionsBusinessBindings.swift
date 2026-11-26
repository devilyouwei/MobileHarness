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
        let presentationLanguage: @Sendable () -> AppLanguage
        let workspaces: @Sendable () throws -> any WorkspaceRepository
        let media: @Sendable () throws -> any MediaRepository
        let devices: @Sendable () throws -> any DeviceRepository
        let connectVision: @MainActor (String, Bool, any CameraOutputHandling) async throws -> Void
        public init(
            files: FilesContainer, cache: CacheContainer = CacheContainer(), model: ModelContainer,
            platform: PlatformContainer, ui: UIContainer,
            presentationLanguage: @escaping @Sendable () -> AppLanguage = { .english },
            workspaces: @escaping @Sendable () throws -> any WorkspaceRepository,
            media: @escaping @Sendable () throws -> any MediaRepository,
            devices: @escaping @Sendable () throws -> any DeviceRepository,
            connectVision: @escaping @MainActor (String, Bool, any CameraOutputHandling) async throws -> Void
        ) {
            self.cache = cache
            self.files = files
            self.model = model
            self.platform = platform
            self.ui = ui
            self.presentationLanguage = presentationLanguage
            self.workspaces = workspaces
            self.media = media
            self.devices = devices
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
        public let preparePlayback: @Sendable (String) async throws -> Void
        public let playbackChanged: @Sendable (String, Bool, ContinuousClock.Instant) async -> Void
        public init(
            sessionID: String, cancelReply: @escaping @MainActor () async throws -> Void,
            detection: AudioDetectionConnections, adaptFailure: @escaping @Sendable (any Error) -> any Error,
            preparePlayback: @escaping @Sendable (String) async throws -> Void = { _ in },
            playbackChanged: @escaping @Sendable (String, Bool, ContinuousClock.Instant) async -> Void = { _, _, _ in }
        ) {
            self.sessionID = sessionID
            self.cancelReply = cancelReply
            self.detection = detection
            self.preparePlayback = preparePlayback
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
        public let homeModelSelections:
            @MainActor () async throws -> (writer: ManagedModelResource?, decision: ManagedModelResource?)
        public let inputQueueStatus: @MainActor @Sendable (Int, Int) -> Void
        public let decisionStatus: @MainActor @Sendable (String) -> Void
        public let decisionConfiguration:
            (@Sendable () async throws -> (String?, (@Sendable () async throws -> ChatModel)?))?
        public let catalog: ActionCatalogSnapshot
        public let settings: any ProviderSettingsStaging
        public let discovery: any ProviderDiscoveryStaging
        public let providerPresentation: any ProviderPresentationRegistering
        public let resources: [ResourceDefinition]
        public let connectionFacts:
            @MainActor @Sendable () throws -> PlatformKit.StateSignalListener<NexArmConnectionFacts>
        public let trackingAvailable: @Sendable () async -> Bool
        public let bindTracking: @MainActor (@escaping @Sendable () async -> Bool) -> Void
        public let bindDeferredFailure: @MainActor (@escaping @Sendable (DeferredActionFailure) async -> Bool) -> Void
        public let observeTranscript: @MainActor @Sendable (String, String) throws -> Void
        public let output: @Sendable (ActionOutputObservation) async -> Void
        public let speechEnhancementEnabled: @Sendable () async throws -> Bool
        public let keywordDetection: @Sendable () async throws -> (enabled: Bool, threshold: Double)
        public let speechDetection: @Sendable () async throws -> (windows: Int, threshold: Double)
        public let decodeResources: @Sendable (String) throws -> ModelResourceViewSnapshot
        public let makeVoice: @MainActor (ActionsVoiceHost) throws -> ActionsVoiceExecution
        public init(
            catalog: ActionCatalogSnapshot,
            readWebScreenshot: @escaping @Sendable (String) async throws -> MultimodalContextSnapshot,
            artifactStreaming: (any ArtifactStreaming)? = nil,
            writerArtifacts: (any WriterArtifactsControlling)? = nil,
            writerModel: (@Sendable () async throws -> ChatModel)? = nil,
            homeModelSelections:
                @escaping @MainActor () async throws -> (ManagedModelResource?, ManagedModelResource?) = { (nil, nil) },
            decisionConfiguration: (
                @Sendable () async throws -> (String?, (@Sendable () async throws -> ChatModel)?)
            )? =
                nil,
            decisionStatus: @escaping @MainActor @Sendable (String) -> Void = { _ in },
            inputQueueStatus: @escaping @MainActor @Sendable (Int, Int) -> Void = { _, _ in },
            settings: any ProviderSettingsStaging, discovery: any ProviderDiscoveryStaging,
            providerPresentation: any ProviderPresentationRegistering,
            resources: [ResourceDefinition],
            connectionFacts:
                @escaping @MainActor @Sendable () throws -> PlatformKit.StateSignalListener<NexArmConnectionFacts>,
            trackingAvailable: @escaping @Sendable () async -> Bool,
            bindTracking: @escaping @MainActor (@escaping @Sendable () async -> Bool) -> Void,
            bindDeferredFailure:
                @escaping @MainActor (@escaping @Sendable (DeferredActionFailure) async -> Bool) -> Void,
            observeTranscript: @escaping @MainActor @Sendable (String, String) throws -> Void,
            output: @escaping @Sendable (ActionOutputObservation) async -> Void,
            speechEnhancementEnabled: @escaping @Sendable () async throws -> Bool = { false },
            keywordDetection: @escaping @Sendable () async throws -> (enabled: Bool, threshold: Double) = {
                (false, 0.25)
            },
            speechDetection: @escaping @Sendable () async throws -> (windows: Int, threshold: Double) = { (8, 0.65) },
            decodeResources: @escaping @Sendable (String) throws -> ModelResourceViewSnapshot,
            makeVoice: @escaping @MainActor (ActionsVoiceHost) throws -> ActionsVoiceExecution
        ) {
            self.readWebScreenshot = readWebScreenshot
            self.artifactStreaming = artifactStreaming
            self.writerArtifacts = writerArtifacts
            self.writerModel = writerModel
            self.homeModelSelections = homeModelSelections
            self.decisionConfiguration = decisionConfiguration
            self.decisionStatus = decisionStatus
            self.inputQueueStatus = inputQueueStatus
            self.catalog = catalog
            self.settings = settings
            self.discovery = discovery
            self.providerPresentation = providerPresentation
            self.resources = resources
            self.connectionFacts = connectionFacts
            self.trackingAvailable = trackingAvailable
            self.bindTracking = bindTracking
            self.bindDeferredFailure = bindDeferredFailure
            self.observeTranscript = observeTranscript
            self.output = output
            self.speechEnhancementEnabled = speechEnhancementEnabled
            self.keywordDetection = keywordDetection
            self.speechDetection = speechDetection
            self.decodeResources = decodeResources
            self.makeVoice = makeVoice
        }
    }

#endif

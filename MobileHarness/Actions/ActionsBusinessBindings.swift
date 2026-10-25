#if os(iOS)
    import Foundation
    import FunctionContracts
    import ModelKitDefaults
    import PlatformKit
    import StorageChat
    import StorageCore
    import UI

    public typealias ActionsUIFacades = ActionUIFacades<
        any CameraControlling, any ConversationHistoryControlling, any ModelResourcesControlling,
        any BluetoothControlling, any SettingsControlling, any ModelResourcesOperating, any SettingsOperating
    >

    public typealias ActionsBusinessRequest = ActionAssemblyRequest<
        ConversationHistoryStore, any ActivityPresenting,
        any ExecutionFailureReporting, any ModelArtifactsManaging, StoredConversation
    >
    @MainActor public struct ActionsVoiceHost {
        public let sessionID: String
        public let cancelReply: @MainActor () async throws -> Void
        public let adaptFailure: @Sendable (any Error) -> any Error
        public let detection: AudioDetectionConnections
        public init(
            sessionID: String, cancelReply: @escaping @MainActor () async throws -> Void,
            detection: AudioDetectionConnections, adaptFailure: @escaping @Sendable (any Error) -> any Error
        ) {
            self.sessionID = sessionID
            self.cancelReply = cancelReply
            self.detection = detection
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
        public let bindEnvironment: @MainActor (@escaping @Sendable () async throws -> String) -> Void
        public let bindDeferredFailure: @MainActor (@escaping @Sendable (DeferredActionFailure) async -> Bool) -> Void
        public let bindResourceRun:
            @MainActor (
                @escaping @Sendable (Set<ResourceID>, @escaping @Sendable () async throws -> Void) async throws -> Void
            ) -> Void
        public let observeTranscript: @MainActor @Sendable (String, String) throws -> Void
        public let observeEmpty: @MainActor @Sendable (String) throws -> Void
        public let output: @Sendable (ActionOutputObservation) async -> Void
        public let decodeResources: @Sendable (String) throws -> ModelResourceViewSnapshot
        public let makeVoice: @MainActor (ActionsVoiceHost) throws -> ActionsVoiceExecution
        public init(
            executor: ActionsExecutionPort, catalog: ActionCatalogSnapshot,
            settings: any ProviderSettingsStaging, discovery: any ProviderDiscoveryStaging,
            providerPresentation: any ProviderPresentationRegistering, tasks: any TaskControlBinding,
            resources: [ResourceDefinition],
            connectionFacts:
                @escaping @MainActor @Sendable () throws -> AsyncThrowingStream<NexArmConnectionFacts, any Error>,
            trackingAvailable: @escaping @Sendable () async -> Bool,
            bindTracking: @escaping @MainActor (@escaping @Sendable () async -> Bool) -> Void,
            bindEnvironment: @escaping @MainActor (@escaping @Sendable () async throws -> String) -> Void,
            bindDeferredFailure:
                @escaping @MainActor (@escaping @Sendable (DeferredActionFailure) async -> Bool) -> Void,
            bindResourceRun:
                @escaping @MainActor (
                    @escaping @Sendable (Set<ResourceID>, @escaping @Sendable () async throws -> Void) async throws ->
                        Void
                ) -> Void,
            observeTranscript: @escaping @MainActor @Sendable (String, String) throws -> Void,
            observeEmpty: @escaping @MainActor @Sendable (String) throws -> Void,
            output: @escaping @Sendable (ActionOutputObservation) async -> Void,
            decodeResources: @escaping @Sendable (String) throws -> ModelResourceViewSnapshot,
            makeVoice: @escaping @MainActor (ActionsVoiceHost) throws -> ActionsVoiceExecution
        ) {
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
            self.bindEnvironment = bindEnvironment
            self.bindDeferredFailure = bindDeferredFailure
            self.bindResourceRun = bindResourceRun
            self.observeTranscript = observeTranscript
            self.observeEmpty = observeEmpty
            self.output = output
            self.decodeResources = decodeResources
            self.makeVoice = makeVoice
        }
    }

#endif

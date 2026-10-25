import AgentCore
import Foundation
import FunctionContracts
import Gateway
import ModelKit
import ModelKitDefaults
import ModelKitRuntime
import PlatformKit
import StorageCache
import StorageChat
import StorageCore
import UI

/// App binds native services to these narrow role-facing ports. No business implementation is imported.
@MainActor public protocol AgentCameraAccess: AnyObject, Sendable {
    func contextSnapshot() async throws -> Data
    func setForeground(_ value: Bool)
    func pauseVisionForModelMaintenance() async
    func shutdown() async throws
    func readPhoto(_ id: String, source: String, sessionID: String, inputID: String) async throws -> Data
}
@MainActor public protocol AgentDeviceAccess: AnyObject, Sendable {
    func contextSnapshot() async throws -> Data
    func setForeground(_ value: Bool)
    func waitUntilIdle() async
    func openPage()
    func closePage()
    func openSystemSettings()
    var initialFence: String { get }
    func stopFence() -> String
}
@MainActor public protocol AgentVoiceLifecycle: AnyObject, Sendable {
    func start(perception: any VoicePerceptionHandling, audioStore: AudioCache) async throws
    func shutdown() async
    func beginSettingsChange() async
    func endSettingsChange()
    func stopVoiceAndWait() async
    func stopVoice(message: String)
}
@MainActor public protocol AgentDetectionControl: AnyObject, Sendable { func stopAndWait() async }

@MainActor public struct AgentVoiceHost {
    public let sessionID: String
    public let cancelReply: @MainActor () async throws -> Void
    public let detection: AudioDetectionConnections
    public init(
        sessionID: String, cancelReply: @escaping @MainActor () async throws -> Void,
        detection: AudioDetectionConnections
    ) {
        self.sessionID = sessionID
        self.cancelReply = cancelReply
        self.detection = detection
    }
}
@MainActor public struct AgentVoiceExecution {
    public let lifecycle: any AgentVoiceLifecycle
    public let spectrum: any SpectrumPresenting
    public let diagnostic: any SpeechDiagnosticControlling
    public let stopDiagnostic: @MainActor () async throws -> Void
    public let detection: any AgentDetectionControl
    public let validate: @Sendable () async throws -> String
    public init(
        lifecycle: any AgentVoiceLifecycle, spectrum: any SpectrumPresenting,
        diagnostic: any SpeechDiagnosticControlling, stopDiagnostic: @escaping @MainActor () async throws -> Void,
        detection: any AgentDetectionControl, validate: @escaping @Sendable () async throws -> String
    ) {
        self.lifecycle = lifecycle
        self.spectrum = spectrum
        self.diagnostic = diagnostic
        self.stopDiagnostic = stopDiagnostic
        self.detection = detection
        self.validate = validate
    }
}
public typealias AgentMaintenancePorts = ActionMaintenancePorts<any ModelArtifactsManaging>
public typealias AgentBusinessRequest = ActionAssemblyRequest<
    ConversationHistoryStore, any ActivityPresenting,
    any ExecutionFailureReporting, any ModelArtifactsManaging, StoredConversation
>
@MainActor public struct AgentBusinessBindings {
    public let executor: ActionsExecutionPort
    public let catalog: ActionCatalogSnapshot
    public let settings: any ProviderSettingsStaging
    public let discovery: any ProviderDiscoveryStaging
    public let providerPresentation: any ProviderPresentationRegistering
    public let tasks: any TaskControlBinding
    public let resources: [ResourceDefinition]
    public let connectionFacts: @MainActor @Sendable () throws -> AsyncThrowingStream<NexArmConnectionFacts, any Error>
    public let trackingAvailable: @Sendable () async -> Bool
    public let bindTracking: @MainActor (@escaping @Sendable () async -> Bool) -> Void
    public let bindEnvironment: @MainActor (@escaping @Sendable () async throws -> String) -> Void
    public let bindDeferredFailure: @MainActor (@escaping @Sendable (DeferredActionFailure) async -> Bool) -> Void
    public let bindResources: @MainActor (ResourceCoordinator, ChannelScheduler) -> Void
    public let observeTranscript: @MainActor @Sendable (String, String) throws -> Void
    public let observeEmpty: @MainActor @Sendable (String) throws -> Void
    public let output: @Sendable (ActionOutputObservation) async -> Void
    public let decodeResources: @Sendable (String) throws -> ModelResourceViewSnapshot
    public let makeVoice: @MainActor (AgentVoiceHost) throws -> AgentVoiceExecution
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
        bindDeferredFailure: @escaping @MainActor (@escaping @Sendable (DeferredActionFailure) async -> Bool) -> Void,
        bindResources: @escaping @MainActor (ResourceCoordinator, ChannelScheduler) -> Void,
        observeTranscript: @escaping @MainActor @Sendable (String, String) throws -> Void,
        observeEmpty: @escaping @MainActor @Sendable (String) throws -> Void,
        output: @escaping @Sendable (ActionOutputObservation) async -> Void,
        decodeResources: @escaping @Sendable (String) throws -> ModelResourceViewSnapshot,
        makeVoice: @escaping @MainActor (AgentVoiceHost) throws -> AgentVoiceExecution
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
        self.bindResources = bindResources
        self.observeTranscript = observeTranscript
        self.observeEmpty = observeEmpty
        self.output = output
        self.decodeResources = decodeResources
        self.makeVoice = makeVoice
    }
}

public typealias AgentUIFacades = ActionUIFacades<
    any CameraControlling, any ConversationHistoryControlling, any ModelResourcesControlling, any BluetoothControlling,
    any SettingsControlling, any ModelResourcesOperating, any SettingsOperating
>

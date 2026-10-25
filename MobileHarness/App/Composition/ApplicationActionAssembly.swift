import Actions
import Agents
import Foundation
import FunctionContracts
import Gateway
import ModelKitDefaults
import PlatformKit
import Storage
import StorageMedia
import UI

@MainActor @available(iOS 27, *)
final class ApplicationActionAssembly {
    let actions: ActionsContainer
    let gateway: GatewayContainer
    let storage: StorageContainer
    let model: ModelContainer
    let platform: PlatformContainer
    let ui: UIContainer
    let photos: CapturedPhotoStore
    let bluetooth: BluetoothWorkflow
    weak var agents: AgentContainer?
    init(
        actions: ActionsContainer, gateway: GatewayContainer, storage: StorageContainer, model: ModelContainer,
        platform: PlatformContainer, ui: UIContainer, photos: CapturedPhotoStore, bluetooth: BluetoothWorkflow
    ) {
        self.actions = actions
        self.gateway = gateway
        self.storage = storage
        self.model = model
        self.platform = platform
        self.ui = ui
        self.photos = photos
        self.bluetooth = bluetooth
    }
    lazy var business = ActionsBusinessAssembly(
        actions: actions, files: storage.files, model: model, platform: platform,
        ui: ui, photos: photos, bluetooth: bluetooth, previewHistory: MemoryContainer.previewHistory,
        makeCameraRuntime: { [weak self] in
            guard let self else { throw ActionsContainerError.stopped }
            let ports = try self.gateway.capabilities
            return CameraRuntimeDependencies(
                resources: CameraResourceBinding(resources: ports.resources, actions: ports.actions))
        },
        connectVision: { [weak self] session, mirrored, endpoint in
            guard let agents = self?.agents else { throw ActionsContainerError.unavailable }
            try await agents.connectVision(
                sessionID: session, mirrored: mirrored,
                status: { message, session in endpoint.visionStatus(message, sessionID: session) })
        })
    var camera: CameraCoordinator { business.camera }
    var device: NexArmDeviceAdapter { business.device }
    func prepare(_ request: AgentBusinessRequest) throws -> AgentBusinessBindings {
        try actions.configureBusiness(business)
        let ports = try business.prepare(request)
        return AgentBusinessBindings(
            executor: ports.executor, catalog: ports.catalog, settings: ports.settings,
            discovery: ports.discovery, providerPresentation: ports.providerPresentation, tasks: ports.tasks,
            resources: ports.resources, connectionFacts: ports.connectionFacts,
            trackingAvailable: ports.trackingAvailable,
            bindTracking: ports.bindTracking,
            bindDeferredFailure: ports.bindDeferredFailure,
            bindResources: { resources, _ in
                ports.bindResourceRun { requested, operation in
                    let owner = ResourceExecutionContext.owner
                    let lease =
                        if let owner { await resources.lease(for: owner, resources: requested) } else {
                            nil as ResourceLease?
                        }
                    try await resources.run(resources: requested, owner: owner, lease: lease, operation: operation)
                }
            }, observeTranscript: ports.observeTranscript, observeEmpty: ports.observeEmpty, output: ports.output,
            decodeResources: ports.decodeResources,
            makeVoice: { host in
                let voice = try ports.makeVoice(
                    ActionsVoiceHost(
                        sessionID: host.sessionID, cancelReply: host.cancelReply,
                        detection: host.detection, adaptFailure: SpeechPlaybackFailure.adapting))
                return AgentVoiceExecution(
                    lifecycle: AppVoiceLifecycle(value: voice.lifecycle), spectrum: voice.spectrum,
                    diagnostic: voice.diagnostic, stopDiagnostic: voice.stopDiagnostic,
                    detection: AppDetectionControl(value: voice.detection), validate: voice.validate)
            })
    }
}

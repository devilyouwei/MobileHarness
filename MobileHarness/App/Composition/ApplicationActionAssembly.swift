import Actions
import Agents
import Foundation
import FunctionContracts
import Gateway
import ModelKitDefaults
import PlatformKit
import Storage
import UI

@MainActor @available(iOS 27, *)
final class ApplicationActionAssembly {
    let gateway: GatewayContainer
    weak var agents: AgentContainer?
    init(gateway: GatewayContainer) { self.gateway = gateway }
    func dependencies(
        storage: StorageContainer, model: ModelContainer, platform: PlatformContainer,
        ui: UIContainer
    ) -> ActionsDependencies {
        ActionsDependencies(
            files: storage.files, model: model, platform: platform, ui: ui,
            media: { try storage.database.media }, devices: { try storage.database.devices },
            previewHistory: MemoryContainer.previewHistory,
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
    }
    func prepare(_ request: AgentBusinessRequest, actions: ActionsContainer) throws -> AgentBusinessBindings {
        let ports = try actions.configureBusiness(request: request)
        return AgentBusinessBindings(
            executor: ports.executor, catalog: ports.catalog, artifactStreaming: ports.artifactStreaming,
            writerArtifacts: ports.writerArtifacts, writerPhotos: ports.writerPhotos,
            writerModel: ports.writerModel, settings: ports.settings,
            discovery: ports.discovery, providerPresentation: ports.providerPresentation, tasks: ports.tasks,
            resources: ports.resources, connectionFacts: ports.connectionFacts,
            trackingAvailable: ports.trackingAvailable,
            bindTracking: ports.bindTracking,
            bindDeferredFailure: ports.bindDeferredFailure,
            bindResources: { resources, _ in
                ports.bindResourceRun { requested, operation in
                    try await resources.runInCurrentContext(resources: requested, operation: operation)
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

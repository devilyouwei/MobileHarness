import AgentCore
import Agents
import AppWorkflows
import BehaviorAssembly
import Foundation
import Gateway
import ModelKit
import PlatformKit
import Storage
import StorageChat

/// Root-owned communication assembly, available before voice models are ready.
@MainActor
final class ApplicationRuntime {
    let conversations: ConversationHistoryStore
    let manager: AgentManager
    let input: InputGateway
    let output: OutputGateway
    let presentation: RuntimePresentation
    let actions: ChannelScheduler
    let resources: ResourceCoordinator

    init(camera: AppleCamera, bluetooth: BluetoothWorkflow) throws {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var directory = root.appendingPathComponent("MobileHarness/Conversations", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try directory.setResourceValues(attributes)
        let document = try LocalDocumentStore<ConversationArchive>(
            url: directory.appendingPathComponent("history.json"),
            maximumBytes: ConversationHistoryStore.maximumBytes)
        conversations = ConversationHistoryStore(document: document)
        let policy = try CommunicationPolicy(
            configurations: ["Assistant", "SpeechPerception", "VisionPerception", "SpeechSynthesis"].map {
                try AgentConfigurations.load(named: $0)
            })
        let manager = AgentManager()
        let input = InputGateway(manager: manager, policy: policy)
        let presentation = RuntimePresentation()
        let resources = try ResourceCoordinator(definitions: [
            ResourceDefinition(
                id: .cameraCapture, allowedOwners: [CameraCoordinator.resourceOwnerID], requiresLease: true
            ) {
                await camera.stop()
            }
        ])
        self.resources = resources
        let behaviors = try BehaviorAssembly(
            presentation: presentation, playback: presentation, pose: presentation,
            shakeBase: { cycles, _ in try await bluetooth.shakeBase(cycles: cycles) },
            capabilities: [
                AssistantAgent.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities),
                SpeechPerceptionAgent.runtimeCapabilities(
                    AgentConfigurations.load(named: "SpeechPerception").capabilities),
                VisionPerceptionAgent.runtimeCapabilities(
                    AgentConfigurations.load(named: "VisionPerception").capabilities),
                AgentConfigurations.load(named: "SpeechSynthesis").capabilities,
            ])
        let actions = ChannelScheduler(registry: behaviors.actions, resources: resources) {
            await input.deliverActionResult($0)
        }
        self.manager = manager
        self.input = input
        self.presentation = presentation
        self.actions = actions
        output = OutputGateway(
            manager: manager, requests: input, tools: behaviors.tools, actions: actions, policy: policy,
            actionFeedback: .terminal,
            observedContracts: ["speech.partial", "speech.final", "speech.phase"],
            observeEvent: { try await presentation.observe($0) }, sink: { await presentation.output($0) })
    }
    func makeAssistant(
        chat: any ChatCapability, modelName: @escaping @Sendable () async throws -> String
    ) throws -> AssistantAgent {
        try AssistantAgent(chat: chat, conversations: conversations, modelName: modelName)
    }
}

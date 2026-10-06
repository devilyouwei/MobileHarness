import Actions
import AgentCore
import Agents
import AppWorkflows
import BehaviorAssembly
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import ModelKit
import PlatformKit
import Storage
import StorageChat
import UI

/// Root-owned communication assembly, available before voice models are ready.
@MainActor
final class ApplicationRuntime {
    private let bluetooth: BluetoothWorkflow
    let historyIntents: HistoryIntentRuntime
    let conversations: ConversationHistoryStore
    let manager: AgentManager
    let input: InputGateway
    let output: OutputGateway
    let presentation: RuntimePresentation
    let actions: ChannelScheduler
    let actionActivity: ActionActivityWorkflow
    let resources: ResourceCoordinator

    init(
        camera: AppleCamera, cameraControl: any CameraControlCapability, bluetooth: BluetoothWorkflow,
        historyState: ConversationHistoryState
    ) throws {
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
        let historySessionID = UUID()
        let historyAgent = try ConversationMemoryAgent(sessionID: historySessionID)
        let historyPresentation = HistoryPresentationAdapter(
            state: historyState, store: conversations, sessionID: historySessionID)
        let policy = try CommunicationPolicy(
            contracts: AgentContracts.communication, externalSources: MediaInputAdapter.externalSources,
            configurations: [
                "Assistant", "SpeechPerception", "VisionPerception", "Photographer", "SpeechSynthesis",
                "ConversationMemory",
            ]
            .map {
                try AgentConfigurations.load(named: $0)
            })
        let manager = AgentManager()
        let input = InputGateway(manager: manager, policy: policy)
        let presentation = RuntimePresentation(cameraControl: cameraControl)
        self.bluetooth = bluetooth
        let resources = try ResourceCoordinator(
            definitions: [
                ResourceDefinition(
                    id: CameraCoordinator.captureResource, allowedOwners: [CameraCoordinator.resourceOwnerID],
                    requiresLease: true
                ) {
                    await camera.stop()
                }
            ]
                + (1...6).map { motor in
                    ResourceDefinition(
                        id: ResourceID(rawValue: "nexarm.motor.\(motor)"),
                        allowedOwners: motor == 6 ? [.assistant] : [.assistant, .photographer],
                        executionGroup: ResourceID(rawValue: "nexarm.writer"),
                        preempts: [.assistant: [.photographer]]
                    ) {
                        // Cancel and join software ownership; this is not a hardware stop acknowledgment.
                        await bluetooth.stopAgentActions()
                    }
                })
        self.resources = resources
        bluetooth.withMotorResources = { motors, operation in
            do {
                let requested = Set(motors.map { ResourceID(rawValue: "nexarm.motor.\($0)") })
                let owner = ResourceExecutionContext.owner
                let lease =
                    if let owner { await resources.lease(for: owner, resources: requested) } else {
                        nil as ResourceLease?
                    }
                try await resources.run(
                    resources: requested, owner: owner, lease: lease, operation: operation)
            } catch ResourceError.busy {
                throw NexArmExecutionError.resourceBusy
            } catch let error as ResourceError {
                throw NexArmExecutionError.resourceUnavailable(String(describing: error))
            }
        }
        let activity = ActionActivityWorkflow(state: ActionActivityState())
        let robot = NexArmBehaviorAdapter(bluetooth: bluetooth, activity: activity)
        let behaviors = try BehaviorAssembly(
            presentation: presentation, playback: presentation, pose: presentation,
            historyPresentation: historyPresentation, camera: presentation,
            history: HistoryQueryService(store: conversations),
            historyMutations: HistoryMutationService(store: conversations),
            gesture: { request, invocation in try await robot.gesture(request, invocation) },
            shakeBase: { cycles, invocation in try await robot.shakeBase(cycles, invocation) },
            aim: { base, pitch, invocation in try await robot.aim(base, pitch, invocation) })
        try BehaviorCoverage.validate(
            actions: behaviors.actions, toolPaths: behaviors.toolPaths,
            capabilities: [
                AssistantAgent.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities),
                SpeechPerceptionAgent.runtimeCapabilities(
                    AgentConfigurations.load(named: "SpeechPerception").capabilities),
                VisionPerceptionAgent.runtimeCapabilities(
                    AgentConfigurations.load(named: "VisionPerception").capabilities),
                PhotographerAgent.runtimeCapabilities(AgentConfigurations.load(named: "Photographer").capabilities),
                AgentConfigurations.load(named: "SpeechSynthesis").capabilities,
                historyAgent.descriptor.capabilities,
            ])
        let actions = ChannelScheduler(registry: behaviors.actions, resources: resources) {
            await input.deliverActionResult($0)
        }
        self.manager = manager
        self.input = input
        self.presentation = presentation
        self.actions = actions
        actionActivity = activity
        actionActivity.start { try await actions.observeExecutions() }
        let gateway = OutputGateway(
            manager: manager, requests: input, tools: behaviors.tools, actions: actions, policy: policy,
            actionFeedback: .terminal,
            observedContracts: ["speech.partial", "speech.final", "speech.phase"],
            observeEvent: { try await presentation.observe($0) }, sink: { await presentation.output($0) })
        output = gateway
        historyIntents = HistoryIntentRuntime(
            sessionID: historySessionID, manager: manager, input: input, output: gateway, agent: historyAgent)
        activity.startFailures { try await gateway.observeFailures() }
    }
    var voiceDependencies: VoiceRuntimeDependencies {
        VoiceRuntimeDependencies(
            manager: manager, input: input, output: output, presentation: presentation, conversations: conversations,
            makeAssistant: { [conversations] chat, modelName in
                try AssistantAgent(chat: chat, conversations: conversations, modelName: modelName)
            },
            makeSynthesis: { try SpeechSynthesisAgent(synthesis: $0, store: $1) },
            makePerception: { try SpeechPerceptionAgent(recognition: $0, vad: $1, sessionID: $2) })
    }
    var visionDependencies: VisionRuntimeDependencies {
        .init(
            makePhotographer: { [bluetooth] in
                let photographer = try PhotographerAgent(
                    sessionID: $0, controlsArm: true, controlAvailable: { await bluetooth.trackingAvailable })
                bluetooth.trackingInputAvailable = { [weak photographer] in
                    await photographer?.hasFreshPose() ?? false
                }
                return photographer
            },
            manager: manager, input: input, output: output, actions: actions, presentation: presentation)
    }
    var cameraDependencies: CameraRuntimeDependencies { .init(resources: resources, actions: actions) }
}

import Actions
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
import UI

/// Root-owned communication assembly, available before voice models are ready.
@MainActor
final class ApplicationRuntime {
    let conversations: ConversationHistoryStore
    let manager: AgentManager
    let input: InputGateway
    let output: OutputGateway
    let presentation: RuntimePresentation
    let actions: ChannelScheduler
    let actionActivity: ActionActivityWorkflow
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
        let resources = try ResourceCoordinator(
            definitions: [
                ResourceDefinition(
                    id: .cameraCapture, allowedOwners: [CameraCoordinator.resourceOwnerID], requiresLease: true
                ) {
                    await camera.stop()
                }
            ]
                + (1...6).map { motor in
                    ResourceDefinition(id: ResourceID(rawValue: "nexarm.motor.\(motor)"), allowedOwners: [.assistant]) {
                        // Cancel and join software ownership; this is not a hardware stop acknowledgment.
                        await bluetooth.stopActions()
                    }
                })
        self.resources = resources
        bluetooth.withMotorResources = { motors, operation in
            try await resources.run(
                resources: Set(motors.map { ResourceID(rawValue: "nexarm.motor.\($0)") }),
                owner: nil, lease: nil, operation: operation)
        }
        let behaviors = try BehaviorAssembly(
            presentation: presentation, playback: presentation, pose: presentation,
            gesture: { request, invocation in
                let composition = try ActionComposition(
                    .action("gesture", [], maximumResults: 100) {
                        do {
                            switch request.gesture {
                            case .reset:
                                try await bluetooth.resetArm(speed: request.speed, acceleration: request.acceleration)
                            case .moveMotor, .resetMotor:
                                guard let motor = request.motor else { throw NexArmError.invalidMotion }
                                try await bluetooth.moveMotor(
                                    id: motor, target: request.target, speed: request.speed,
                                    acceleration: request.acceleration)
                            default:
                                let gesture: NexArmGesture
                                switch request.gesture {
                                case .nod: gesture = .nod
                                case .shakeHead: gesture = .shakeHead
                                case .wave: gesture = .wave
                                case .tiltLeft: gesture = .tiltLeft
                                case .tiltRight: gesture = .tiltRight
                                case .lookAround: gesture = .lookAround
                                case .celebrate: gesture = .celebrate
                                case .dance: gesture = .dance
                                default: throw NexArmError.invalidMotion
                                }
                                try await bluetooth.performGesture(
                                    gesture, repetitions: request.repetitions,
                                    speed: request.speed, acceleration: request.acceleration)
                            }
                        } catch {
                            if let report = await bluetooth.lastActionReport {
                                return .report(report)
                            }
                            throw error
                        }
                        if let report = await bluetooth.lastActionReport { return .report(report) }
                        return .completed
                    })
                try await invocation.results.record(composition.run())
            },
            shakeBase: { cycles, invocation in
                do {
                    let args = ActionArguments(invocation.call.parameters)
                    let speed =
                        try invocation.call.parameters["speed"] == nil
                        ? 1400 : args.requiredInt("speed", range: 1...1400)
                    let acceleration =
                        try invocation.call.parameters["acceleration"] == nil
                        ? 30 : args.requiredInt("acceleration", range: 1...254)
                    try await bluetooth.performGesture(
                        .baseSway, repetitions: cycles, speed: speed, acceleration: acceleration)
                } catch {
                    if let report = await bluetooth.lastActionReport {
                        try await invocation.results.record(report)
                        if error is CancellationError { throw error }
                        return
                    }
                    throw error
                }
                if let report = await bluetooth.lastActionReport { try await invocation.results.record(report) }
            },
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
        actionActivity = ActionActivityWorkflow(state: ActionActivityState())
        actionActivity.start { try await actions.observeExecutions() }
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

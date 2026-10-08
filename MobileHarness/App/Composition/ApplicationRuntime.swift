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
import OSLog
import PlatformKit
import Storage
import StorageChat
import UI

/// Root-owned communication assembly, available before voice models are ready.
@MainActor
final class ApplicationRuntime {
    private let bluetooth: BluetoothWorkflow
    let resourceObservation: ResourceObservationWorkflow
    private let providerPresentation: ProviderPresentationAdapter
    private let providerSettings: ProviderSettingsRequests
    private let providerRequests: ProviderDiscoveryRequests
    private let applicationControlSessionID: UUID
    let applicationControlIntents: ApplicationControlIntentRuntime
    let photographerIntents: PhotographerIntentRuntime
    let historyIntents: HistoryIntentRuntime
    let conversations: ConversationHistoryStore
    let manager: AgentManager
    let input: InputGateway
    let output: OutputGateway
    let presentation: RuntimePresentation
    let actions: ChannelScheduler
    let actionActivity: ActionActivityWorkflow
    let resources: ResourceCoordinator

    func restoreProvider() async throws -> CloudSettingsDraft {
        let id = try providerSettings.stageRestore(sessionID: applicationControlSessionID)
        return try await finishProviderSettings(id, operation: .restore)
    }
    func saveProvider(_ draft: CloudSettingsDraft) async throws {
        let id = try providerSettings.stageSave(
            .init(enabled: draft.enabled, url: draft.url, key: draft.key, model: draft.model),
            sessionID: applicationControlSessionID)
        _ = try await finishProviderSettings(id, operation: .save)
    }
    private func finishProviderSettings(_ id: UUID, operation: ProviderSettingsIntent.Operation) async throws
        -> CloudSettingsDraft
    {
        defer {
            providerSettings.discard(id, sessionID: applicationControlSessionID)
            providerPresentation.discard(id)
        }
        try providerPresentation.register(id, operation: operation == .restore ? .restore : .save)
        try await applicationControlIntents.configureProvider(
            .init(operation: operation, requestID: id, presentation: true))
        let value = try providerSettings.take(id, sessionID: applicationControlSessionID)
        return .init(enabled: value.enabled, url: value.url, key: value.key, model: value.model)
    }
    func discoverProvider(_ draft: CloudSettingsDraft) async throws -> [String] {
        let id = try await providerRequests.stage(
            .init(url: draft.url, key: draft.key), sessionID: applicationControlSessionID)
        defer { providerPresentation.discard(id) }
        do {
            try providerPresentation.register(id, operation: .discovery)
            let raw = try await applicationControlIntents.discoverProvider(requestID: id, presentation: true)
            guard raw.utf8.count <= 65_536 else { throw ProviderDiscoveryError.invalidModels }
            let models = try JSONDecoder().decode([String].self, from: Data(raw.utf8))
            _ = try ProviderModelList.encoded(models)
            await providerRequests.discard(id, sessionID: applicationControlSessionID)
            return models
        } catch {
            await providerRequests.discard(id, sessionID: applicationControlSessionID)
            throw error
        }
    }

    init(
        camera: AppleCamera, cameraControl: any CameraControlCapability, bluetooth: BluetoothWorkflow,
        historyState: ConversationHistoryState, resourceState: ModelResourcesState, providerState: SettingsState,
        navigationState: NavigationState, device: DeviceControlAdapter,
        modelResources: any ModelResourceCapability,
        providerSettingsRuntime: ProviderSettingsRuntime,
        resourcePreferences: any ModelResourcePreferencesCapability,
        resourceInventory: any ModelResourceInventoryCapability,
        resourceFingerprint: @escaping @MainActor () async throws -> String,
        resourceSnapshotAccepted: @escaping @MainActor () -> Void,
        summarizeTitle: @escaping @Sendable (StoredConversation) async throws -> String
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
        let providerSettings = ProviderSettingsRequests(
            service: ProviderSettingsService(
                store: ProviderSettingsStore(credentials: SettingsCredentialAdapter()), runtime: providerSettingsRuntime
            ))
        self.providerSettings = providerSettings
        let applicationControlSessionID = UUID()
        self.applicationControlSessionID = applicationControlSessionID
        let providerRequests = ProviderDiscoveryRequests(discover: SettingsProviderAdapter.discoverModels)
        self.providerRequests = providerRequests
        let providerPresentation = ProviderPresentationAdapter(
            state: providerState, sessionID: applicationControlSessionID, settings: providerSettings,
            discovery: providerRequests)
        self.providerPresentation = providerPresentation
        let applicationControlAgent = try ApplicationControlAgent(sessionID: applicationControlSessionID)
        device.environment = { try await applicationControlAgent.environmentSnapshot() }
        let photographerSessionID = UUID()
        let photographerAgent = try PhotographerAgent(
            sessionID: photographerSessionID, controlsArm: true,
            controlAvailable: { await bluetooth.trackingAvailable })
        bluetooth.trackingInputAvailable = { [weak photographerAgent] in
            await photographerAgent?.hasFreshPose() ?? false
        }
        let historySessionID = UUID()
        let historyAgent = try MemoryAgent(sessionID: historySessionID)
        let historyPresentation = HistoryPresentationAdapter(
            state: historyState, store: conversations, sessionID: historySessionID)
        let policy = try CommunicationPolicy(
            contracts: AgentContracts.communication, externalSources: MediaInputAdapter.externalSources,
            configurations: [
                "Assistant", "SpeechPerception", "VisionPerception", "Photographer", "SpeechSynthesis",
                "Memory", "ApplicationControl",
            ]
            .map {
                try AgentConfigurations.load(named: $0)
            })
        let manager = AgentManager()
        let input = InputGateway(manager: manager, policy: policy)
        let presentation = RuntimePresentation(cameraControl: cameraControl, rootSessionID: photographerSessionID)
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
        device.input = input
        device.activity = activity
        let robot = NexArmBehaviorAdapter(bluetooth: bluetooth, activity: activity)
        let behaviors = try BehaviorAssembly(
            presentation: presentation, playback: presentation, pose: presentation,
            historyPresentation: historyPresentation, camera: presentation,
            history: HistoryQueryService(store: conversations),
            historyMutations: HistoryMutationService(store: conversations, summarizeTitle: summarizeTitle),
            modelResources: modelResources, resourcePreferences: resourcePreferences,
            resourceInventory: resourceInventory,
            resourcePresentation: ResourcePresentationAdapter(
                state: resourceState, sessionID: applicationControlSessionID, provider: providerPresentation,
                navigation: navigationState,
                acknowledge: resourceSnapshotAccepted),
            providerDiscovery: providerRequests, providerSettings: providerSettings, device: device,
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
                historyAgent.descriptor.capabilities, applicationControlAgent.descriptor.capabilities,
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
        let photography = PhotographerIntentRuntime(
            sessionID: photographerSessionID, manager: manager,
            input: input, output: gateway, agent: photographerAgent,
            report: { message in
                Logger(subsystem: "dev.mobileharness", category: "Photographer").error("\(message, privacy: .private)")
            })
        photographerIntents = photography
        presentation.cameraRequests = { operation, invocation in
            try await photography.perform(
                operation,
                delegate: { message in
                    try await gateway.delegate(message, context: invocation.context, to: .photographer)
                })
        }
        let intents = ApplicationControlIntentRuntime(
            sessionID: applicationControlSessionID, manager: manager, input: input, output: gateway,
            agent: applicationControlAgent)
        applicationControlIntents = intents
        resourceObservation = ResourceObservationWorkflow(
            read: resourceFingerprint,
            deliver: { sample, sequence in
                let generation = resourceState.beginRefresh()
                let observation: ModelResourceObservation
                switch sample {
                case .changed: observation = .changed(generation: generation)
                case .failed(let message): observation = .failed(generation: generation, message: message)
                }
                do {
                    try await intents.observe(observation, sequence: sequence)
                    return .accepted
                } catch ApplicationControlIntentFailure.presented(let message) {
                    return .retry(message)
                }
            },
            invalidate: { resourceState.beginRefresh() },
            report: { _ in resourceState.error = "资源状态更新失败，请稍后重试。" })
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
            photographer: photographerIntents,
            manager: manager, input: input, output: output, actions: actions, presentation: presentation)
    }
    var cameraDependencies: CameraRuntimeDependencies { .init(resources: resources, actions: actions) }
}

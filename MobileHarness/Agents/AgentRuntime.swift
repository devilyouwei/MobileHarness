import StorageCache
import StorageFiles

#if os(iOS)
    import Actions
    import AgentCore

    import CallRuntime
    import ExecutionRuntime
    import Foundation
    import FunctionContracts
    import Gateway
    import ModelKit
    import OSLog
    import PlatformKit
    import StorageCore
    import StorageChat
    import StorageTasks
    import UI

    /// Root-owned communication assembly, available before voice models are ready.
    @MainActor
    @available(iOS 27, *)
    final class AgentRuntime {
        private let uiHome: UIHomeContainer
        private let cacheStorage: CacheContainer
        private let bluetooth: BluetoothWorkflow
        let applicationControlSession: ApplicationControlExecutionSession
        let photographerSession: PhotographerExecutionSession
        let memorySession: MemoryExecutionSession
        let interaction: AssistantExecutionSession
        let interactionSessionID: String
        private var skillObservation: Task<Void, Never>?
        private let containerFailures: ContainerFailureChannel
        private var containerFailuresConnected = false
        func connectFailures() {
            startObservers()
            actionActivity.connectFailures { [applicationControlSession] event in
                try await applicationControlSession.agent.observeFailure(event)
            }
            guard !containerFailuresConnected else { return }
            containerFailuresConnected = true
            containerFailures.connect { [applicationControlSession, interaction] event in
                try await applicationControlSession.agent.observeFailure(event)
                try await interaction.agent.observeFailure(event)
            }
        }

        private var titleMutations: HistoryMutationService?
        func shutdown() async {
            containerFailures.disconnect()
            containerFailuresConnected = false
            await actionActivity.shutdown()
            skillObservation?.cancel()
            await skillObservation?.value
            await titleMutations?.shutdown()
            await manager.stopAll()
            await output.shutdown()
            await resources.shutdown()
            bluetooth.withMotorResources = nil
            bluetooth.trackingInputAvailable = { false }
            endpoints.tasks.handler = nil
        }
        private let assistantContext: AgentContextRepository<AssistantContextState>
        let conversations: ConversationHistoryStore
        let manager: AgentManager
        let input: InputGateway
        let output: OutputGateway
        let endpoints: ActionEndpoints
        var presentation: RuntimePresentation { endpoints.presentation }
        private let photoCamera: any CameraControlCapability
        let actions: ChannelScheduler
        let actionActivity: ActionActivityWorkflow
        let resources: ResourceCoordinator

        init(
            containerFailures: ContainerFailureChannel, home: UIHomeContainer,
            assistantContainer: AssistantContainer, applicationControlContainer: ApplicationControlContainer,
            memoryContainer: MemoryContainer, photographerContainer: PhotographerContainer,
            stateContext: AgentStateContext, cache: CacheContainer, files: FilesContainer,
            chatRecords: any ChatRepository, taskRecords: any TaskRepository, camera: any CameraCapturing,
            cameraUI: UICameraContainer, albumUI: UIAlbumContainer? = nil,
            album: (any PhotoAlbumCapability)? = nil, settingsUI: UISettingsContainer,
            resourcesUI: UIModelResourcesContainer, devicesUI: UIDeviceSettingsContainer, historyUI: UIHistoryContainer,
            diagnosticsUI: UIDiagnosticsContainer,
            readHistoryPhoto: @escaping @Sendable (String, String) async throws -> Data?,
            cameraControl: any CameraControlCapability,
            bluetooth: BluetoothWorkflow,
            historyState: any HistoryPresenting, resourceState: any ModelResourcesPresenting,
            providerState: any SettingsPresenting,
            navigationState: any NavigationPresenting, device: NexArmDeviceAdapter,
            modelResources: any ModelResourceCapability,
            providerSettingsRuntime: ProviderSettingsRuntime,
            resourcePreferences: any ModelResourcePreferencesCapability,
            resourceInventory: any ModelResourceInventoryCapability,
            resourceChanges: @escaping @MainActor @Sendable () async throws -> AsyncStream<UInt64>,
            resourceSnapshotAccepted: @escaping @MainActor () -> Void,
            summarizeTitle: @escaping @Sendable (StoredConversation) async throws -> String,
            modelName: @escaping @Sendable () async throws -> String = { "Unspecified model" },
            chatProvider: @escaping @Sendable () async throws -> any ChatCapability
        ) throws {
            let contextScope = UUID().uuidString
            self.contextScope = contextScope
            self.uiHome = home
            self.containerFailures = containerFailures
            self.cacheStorage = cache
            try AgentConfigurations.installDeclarations(CapabilityModules.declarations)
            self.photoCamera = cameraControl
            let assistantContext = try AgentContextRepository(
                agent: .assistant, scope: contextScope, state: AssistantContextState())
            self.assistantContext = assistantContext
            let historyStore = try AssistantConversationStorage.store(
                repository: assistantContext, chat: chatRecords, tasks: taskRecords)
            conversations = historyStore
            let providerSettings = ProviderSettingsRequests(
                service: ProviderSettingsService(
                    store: ProviderSettingsStore(
                        credentials: SettingsCredentialAdapter(),
                        document: {
                            try files.document(UserSettingsDocument.self, in: files.settings, name: "settings.json")
                        }), runtime: providerSettingsRuntime
                ))
            let applicationControlSessionID = UUID().uuidString
            self.interactionSessionID = applicationControlSessionID
            let providerRequests = ProviderDiscoveryRequests(discover: SettingsProviderAdapter.discoverModels)
            let providerPresentation = ProviderPresentationAdapter(
                state: providerState, sessionID: applicationControlSessionID, settings: providerSettings,
                discovery: providerRequests)
            let applicationContext = try Self.context(
                .applicationControl, ApplicationControlContextState(), scope: contextScope)
            let photographerContext = try Self.context(.photographer, PhotographerContextState(), scope: contextScope)
            let memoryContext = try Self.context(.memory, MemoryContextState(), scope: contextScope)
            let applicationControlAgent = try ApplicationControlAgent(
                sessionID: applicationControlSessionID,
                uiSettings: settingsUI, uiResources: resourcesUI, uiDevices: devicesUI, uiDiagnostics: diagnosticsUI,
                connectionFacts: { try bluetooth.service.observeConnectionFacts() },
                resourceChanges: resourceChanges,
                observationFailure: { error in
                    containerFailures.report(
                        module: "agents", component: "resources", operation: "observe", error: error)
                },
                uiProviderSettings: providerSettings, uiProviderDiscovery: providerRequests,
                uiProviderPresentation: providerPresentation,
                context: applicationContext)
            device.environment = { try await applicationControlAgent.environmentSnapshot() }
            let photographerSessionID = applicationControlSessionID
            let photographerAgent = try PhotographerAgent(
                sessionID: photographerSessionID, uiCamera: cameraUI, controlsArm: true, uiAlbum: albumUI,
                cameraObservationFailure: { error in
                    containerFailures.report(module: "agents", component: "camera", operation: "observe", error: error)
                },
                controlAvailable: { await bluetooth.trackingAvailable },
                context: photographerContext)
            bluetooth.trackingInputAvailable = { [weak photographerAgent] in
                await photographerAgent?.hasFreshPose() ?? false
            }
            let historySessionID = applicationControlSessionID
            let historyPresentation = HistoryPresentationAdapter(
                state: historyState, store: conversations, sessionID: historySessionID)
            let policy = try CommunicationPolicy(
                contracts: AgentContracts.communication,
                configurations: [
                    "Assistant", "SpeechPerception", "VisionPerception", "Photographer", "SpeechSynthesis",
                    "Memory", "ApplicationControl",
                ]
                .map {
                    try AgentConfigurations.load(named: $0)
                })
            let manager = AgentManager()
            let activity = ActionActivityWorkflow(state: home.activityPresentation)
            let input = InputGateway(
                manager: manager, policy: policy,
                signalSummary: { input in
                    switch input.payload {
                    case .text(let text): return String(text.prefix(256))
                    case .observation(let message):
                        if case .transcript(let text, _) = message.perception { return String(text.prefix(256)) }
                        if let task = message.content(as: AgentTaskSignal.self),
                            let content = try? AgentTaskContent.decode(task)
                        {
                            return String(content.text.prefix(256))
                        }
                        if let task = message.content(as: AgentTaskSignal.self),
                            task.businessContract == "runtime.taskTermination"
                        {
                            return String(String(decoding: task.data, as: UTF8.self).prefix(256))
                        }
                        return ""
                    case .toolResult(let result): return String(result.value.prefix(256))
                    default: return ""
                    }
                },
                publicationFailure: { _, _, _ in })
            let endpoints = ActionEndpoints(
                cameraControl: cameraControl, rootSessionID: photographerSessionID, activity: activity.state,
                effects: home.effects, expressions: home.expressions,
                homeBluetooth: home.conversation, deviceBluetooth: bluetooth.state)
            let presentation = endpoints.presentation
            let historyAgent = try MemoryAgent(
                sessionID: historySessionID, uiHistory: historyUI,
                beforeNewConversation: {
                    if try await assistantContext.snapshot().state.skillState?.activeTaskID != nil {
                        guard let control = await endpoints.tasks.handler else {
                            throw CommunicationError.unavailableTarget
                        }
                        _ = try await control(
                            "cancelTask", ["reason": "用户开始新对话"], "assistant",
                            applicationControlSessionID, UUID().uuidString, nil)
                    }
                }, context: memoryContext)
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
                            allowedOwners: [.assistant, .applicationControl, .photographer],
                            executionGroup: ResourceID(rawValue: "nexarm.writer"),
                            preempts: [.assistant: [.photographer], .applicationControl: [.photographer]]
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
            device.deliverActionResult = { result, report in
                let feedback = ActionResult(
                    executionID: result.executionID, owner: result.owner, path: result.path,
                    causality: result.causality,
                    status: result.status, effect: result.effect, completion: report.map { .report($0.agentValue) },
                    failure: result.failure, callID: result.callID, roundID: result.roundID)
                return await input.deliverActionResult(feedback) == .accepted
            }
            device.activity = activity
            let robot = NexArmBehaviorAdapter(bluetooth: bluetooth, activity: activity)
            let mutations = HistoryMutationService(
                store: conversations, summarizeTitle: summarizeTitle,
                archiveChanged: { message in
                    do {
                        try await historyPresentation.refreshAfterMutation(message: message)
                    } catch { await historyPresentation.recordRefreshFailure(error) }
                }, titlePositions: { ConversationTitleGenerator.samplePositions(count: $0) })
            titleMutations = mutations
            let behaviors = try BehaviorAssembly(
                presentation: presentation, playback: endpoints.speech, pose: presentation,
                historyPresentation: historyPresentation, camera: endpoints.camera,
                history: HistoryQueryService(store: conversations),
                historyMutations: mutations,
                fullHistory: HistoryFullReadService(store: historyStore, photo: readHistoryPhoto), album: album,
                modelResources: modelResources, resourcePreferences: resourcePreferences,
                resourceInventory: resourceInventory,
                resourcePresentation: ResourcePresentationAdapter(
                    state: resourceState, sessionID: applicationControlSessionID, provider: providerPresentation,
                    navigation: navigationState,
                    acknowledge: resourceSnapshotAccepted),
                providerDiscovery: providerRequests, providerSettings: providerSettings, device: device,
                feedback: presentation, effects: presentation, listening: endpoints.speech,
                listeningGesture: endpoints.speech, detection: endpoints.speech, taskControl: endpoints.tasks,
                loading: presentation, runtimeFailures: presentation, bluetoothStatus: presentation,
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
                ] + AgentConfigurations.skillRegistries())
            let actions = ChannelScheduler(registry: behaviors.actions, resources: resources) {
                await input.deliverActionResult($0)
            }
            self.manager = manager
            self.input = input
            self.endpoints = endpoints
            self.actions = actions
            actionActivity = activity
            let gateway = OutputGateway(
                manager: manager, requests: input, tools: behaviors.tools, actions: actions, policy: policy,
                actionFeedback: .terminal,
                observedContracts: ["speech.partial", "speech.final", "speech.phase"],
                observeEvent: { input in
                    guard let observation = input.payload.perception else { return }
                    switch observation {
                    case .transcript(let text, true):
                        try await presentation.observeTranscript(text, sessionID: input.sessionID)
                    case .speechPhase(.empty):
                        try await presentation.observeEmptyUtterance(sessionID: input.sessionID)
                    default: break
                    }
                }, sink: { await presentation.output($0) })
            output = gateway
            let photography = PhotographerExecutionSession(
                manager: manager,
                output: gateway, agent: photographerAgent,
                report: { message in
                    Logger(subsystem: "dev.mobileharness", category: "Photographer").error(
                        "\(message, privacy: .private)")
                })
            photographerSession = photography
            let intents = ApplicationControlExecutionSession(
                manager: manager, output: gateway,
                agent: applicationControlAgent)
            applicationControlSession = intents
            let history = MemoryExecutionSession(
                manager: manager, output: gateway, agent: historyAgent)
            memorySession = history
            let main = try AssistantAgent(
                stateContext: stateContext,
                uiHome: home, uiSessionID: applicationControlSessionID,
                reportsReplyActivity: true, chatProvider: chatProvider, conversations: conversations,
                modelName: modelName,
                observations: AssistantContextBuilder.photoObservationHandler(
                    read: { id, input in
                        try await ChatImage(
                            id: id,
                            data: cameraControl.readPhoto(
                                id, source: "assistant", sessionID: input.sessionID, inputID: input.id))
                    },
                    prepareJPEG: { data, policy in
                        try await NativeImageCompression.jpeg(
                            from: data,
                            limits: .init(
                                maximumDimension: policy.maximumDimension, maximumPixels: policy.maximumPixels,
                                maximumBytes: policy.maximumBytes, quality: policy.quality))
                    }), context: assistantContext)
            endpoints.tasks.handler = { operation, arguments, source, session, input, decision in
                try await main.controlTask(
                    operation, arguments: arguments, source: source, sessionID: session, inputID: input,
                    decisionID: decision)
            }
            let interaction = AssistantExecutionSession(
                agent: main, manager: manager, output: gateway,
                report: { message in
                    Logger(subsystem: "dev.mobileharness", category: "Agents").error("\(message, privacy: .private)")
                })
            self.interaction = interaction
            try assistantContainer.install(interaction)
            try applicationControlContainer.install(intents)
            try memoryContainer.install(history)
            try photographerContainer.install(photography)
        }
        private var observersStarted = false
        private func startObservers() {
            guard !observersStarted else { return }
            observersStarted = true
            let activity = actionActivity
            let input = input
            let manager = manager
            let main = interaction.agent
            let gateway = output
            let actions = actions
            activity.startTasks(
                observe: { try await input.observeTasks() },
                taskContent: { signal in
                    guard let content = try? AgentTaskContent.decode(signal) else { return ("", false) }
                    return (String(content.text.prefix(256)), content.stage == .waitingUser)
                })
            activity.startAgents {
                var values: [(String, AgentLifecycle)] = []
                for descriptor in await manager.descriptors() {
                    if let agent = try? await manager.agent(descriptor.id) {
                        values.append((descriptor.id.rawValue, await agent.status().lifecycle))
                    }
                }
                return values
            }
            activity.start { try await actions.observeExecutions() }
            skillObservation = Task { [activity] in
                var previous: [String: String] = [:]
                for await skills in main.skillUpdates {
                    guard !Task.isCancelled else { return }
                    let active = skills.tasks.first { $0.id == skills.activeTaskID }
                    activity.presentTaskState(
                        id: active?.id, title: active?.goal ?? "", status: active?.status ?? "",
                        ownership: Dictionary(
                            uniqueKeysWithValues: skills.loaded.map { ($0, (try? skills.ownership($0)) ?? "unknown") }),
                        loaded: skills.loaded)
                    for task in skills.tasks {
                        let marker = task.status + task.skills.joined(separator: ",") + (task.failure ?? "")
                        guard previous[task.id] != marker else { continue }
                        previous[task.id] = marker
                        let phase: TaskLogItem.Phase
                        switch task.status {
                        case "waitingUser": phase = .waitingUser
                        case "completed": phase = .succeeded
                        case "cancelled": phase = .cancelled
                        case "failed", "interrupted": phase = .failed
                        case "cancelling": phase = .cancelling
                        default: phase = .running
                        }
                        var item = TaskLogItem(
                            id: task.id, parentID: nil, requester: "", executor: "assistant", title: task.goal,
                            phase: phase
                        )
                        item.execution = "foreground"
                        item.mode = task.mode
                        item.skills = task.skills
                        item.failure = task.failure
                        activity.updateTask(
                            item,
                            event: .init(
                                id: UUID().uuidString, time: task.updatedAt ?? task.date, title: task.status,
                                detail: "前台任务 · Skills: " + task.skills.joined(separator: ",")))
                    }
                    previous = previous.filter { id, _ in skills.tasks.contains { $0.id == id } }
                }
            }

            activity.startFailures { try await gateway.observeFailures() }
        }
        private let contextScope: String
        private static func context<State: AgentContextState>(_ agent: AgentID, _ state: State, scope: String)
            throws -> AgentContextRepository<State>
        {
            try AgentContextRepository(agent: agent, scope: scope, state: state)
        }
        var voiceDependencies: VoiceRuntimeDependencies {
            VoiceRuntimeDependencies(
                cache: cacheStorage, manager: manager, output: output, endpoints: endpoints,
                reportFailure: containerFailures.sink(module: "agents"),
                interactionSessionID: interactionSessionID,
                startInteraction: { [interaction] in try await interaction.start() },
                cancelReply: { [interaction, interactionSessionID] in
                    try await interaction.interruptConversation(sessionID: interactionSessionID)
                },
                makeSynthesis: { [contextScope] in
                    try SpeechSynthesisAgent(
                        synthesis: $0, store: $1,
                        context: try Self.context(
                            AgentID(rawValue: "speechSynthesis"), SpeechSynthesisContextState(), scope: contextScope))
                },
                makePerception: { [interactionSessionID, uiHome, contextScope] in
                    try SpeechPerceptionAgent(
                        recognition: $0, vad: $1, sessionID: $2, interactionSessionID: interactionSessionID,
                        residentListening: true, uiHome: uiHome, microphoneInput: $3, microphoneSpectrum: $4,
                        context: try Self.context(
                            .speechPerception, SpeechPerceptionContextState(), scope: contextScope))
                })
        }
        func visionContext() throws -> AgentContextRepository<VisionPerceptionContextState> {
            try Self.context(.visionPerception, VisionPerceptionContextState(), scope: contextScope)
        }
        var cameraDependencies: CameraRuntimeDependencies {
            .init(resources: CameraResourceBinding(resources: resources, actions: actions))
        }
    }

#endif

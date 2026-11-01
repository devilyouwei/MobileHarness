import StorageCache
import StorageFiles

#if os(iOS)
    import FunctionContracts
    import AgentCore

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

    @MainActor @available(iOS 27, *)
    public final class AgentExecutionPreparation {
        public let request: AgentBusinessRequest
        private var operation: ((AgentBusinessBindings) throws -> AgentExecutionBinding)?
        init(
            request: AgentBusinessRequest, operation: @escaping (AgentBusinessBindings) throws -> AgentExecutionBinding
        ) {
            self.request = request
            self.operation = operation
        }
        public func validate(_ business: AgentBusinessBindings) throws -> AgentExecutionBinding {
            guard let operation else { throw AgentContainerError.unavailable }
            self.operation = nil
            return try operation(business)
        }
    }
    @MainActor @available(iOS 27, *)
    public final class AgentExecutionBinding {
        public let configuration: AgentGatewayConfiguration
        private var operation: ((AgentGatewayCapabilities) throws -> AgentRuntime)?
        init(
            configuration: AgentGatewayConfiguration,
            operation: @escaping (AgentGatewayCapabilities) throws -> AgentRuntime
        ) {
            self.configuration = configuration
            self.operation = operation
        }
        func finish(_ facilities: AgentGatewayCapabilities) throws -> AgentRuntime {
            guard let operation else { throw AgentContainerError.unavailable }
            self.operation = nil
            return try operation(facilities)
        }
    }

    /// Root-owned communication assembly, available before voice models are ready.
    @MainActor
    @available(iOS 27, *)
    final class AgentRuntime {
        private let uiHome: UIHomeContainer
        private let cacheStorage: CacheContainer
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

        func shutdown() async {
            containerFailures.disconnect()
            containerFailuresConnected = false
            await output.shutdown(closeResources: false)
            await actionActivity.shutdown()
            skillObservation?.cancel()
            await skillObservation?.value
            business.bindTracking { false }
            business.tasks.handler = nil
        }
        private let assistantContext: AgentContextRepository<AssistantContextState>
        let conversations: ConversationHistoryStore
        let observations: AgentObservationAccess
        let manager: AgentManager
        let input: InputGateway
        let output: OutputGateway
        let business: AgentBusinessBindings
        let actions: ChannelScheduler
        let actionActivity: ActionActivityWorkflow
        let resources: ResourceCoordinator

        static func prepare(
            maintenance: AgentMaintenancePorts,
            containerFailures: ContainerFailureChannel, home: UIHomeContainer,
            assistantContainer: AssistantContainer, applicationControlContainer: ApplicationControlContainer,
            memoryContainer: MemoryContainer, photographerContainer: PhotographerContainer,
            stateContext: AgentStateContext, cache: CacheContainer,
            chatRecords: any ChatRepository, taskRecords: any TaskRepository,
            cameraUI: UICameraContainer, albumUI: UIAlbumContainer? = nil, windowsUI: WindowState? = nil,
            settingsUI: UISettingsContainer,
            resourcesUI: UIModelResourcesContainer, devicesUI: UIDeviceSettingsContainer, historyUI: UIHistoryContainer,
            diagnosticsUI: UIDiagnosticsContainer, cameraControl: any AgentCameraAccess,
            resourceChanges: @escaping @MainActor @Sendable () async throws -> AsyncStream<UInt64>,
            summarizeTitle: @escaping @Sendable (StoredConversation) async throws -> String,
            modelName: @escaping @Sendable () async throws -> String = { "Unspecified model" },
            chatProvider: @escaping @Sendable () async throws -> any ChatCapability
        ) throws -> AgentExecutionPreparation {
            let contextScope = UUID().uuidString
            let assistantContext = try AgentContextRepository(
                agent: .assistant, scope: contextScope, state: AssistantContextState())
            let historyStore = try AssistantConversationStorage.store(
                repository: assistantContext, chat: chatRecords, tasks: taskRecords)
            let applicationControlSessionID = UUID().uuidString
            let activity = ActionActivityWorkflow(state: home.activityPresentation)
            let conversations = historyStore
            let request = AgentBusinessRequest(
                sessionID: applicationControlSessionID,
                conversations: conversations, activity: activity.state, failures: activity,
                maintenance: maintenance, summarizeTitle: summarizeTitle,
                titlePositions: { ConversationTitleGenerator.samplePositions(count: $0) },
                resourcePolicies: (1...6).map { motor in
                    ResourcePolicy(
                        id: ResourceID(rawValue: "nexarm.motor.\(motor)"),
                        allowedOwners: Set([
                            AgentID.assistant.rawValue, AgentID.applicationControl.rawValue,
                            AgentID.photographer.rawValue,
                        ]),
                        executionGroup: ResourceID(rawValue: "nexarm.writer"),
                        preempts: [
                            AgentID.assistant.rawValue: [AgentID.photographer.rawValue],
                            AgentID.applicationControl.rawValue: [AgentID.photographer.rawValue],
                        ])
                })
            return AgentExecutionPreparation(request: request) { business in
                let applicationContext = try Self.context(
                    .applicationControl, ApplicationControlContextState(), scope: contextScope)
                let photographerContext = try Self.context(
                    .photographer, PhotographerContextState(), scope: contextScope)
                let memoryContext = try Self.context(.memory, MemoryContextState(), scope: contextScope)
                let applicationControlAgent = try ApplicationControlAgent(
                    sessionID: applicationControlSessionID,
                    uiSettings: settingsUI, uiResources: resourcesUI, uiDevices: devicesUI,
                    uiDiagnostics: diagnosticsUI, uiWindows: windowsUI,
                    connectionFacts: business.connectionFacts,
                    resourceChanges: resourceChanges,
                    observationFailure: { error in
                        containerFailures.report(
                            module: "agents", component: "resources", operation: "observe", error: error)
                    },
                    uiProviderSettings: business.settings, uiProviderDiscovery: business.discovery,
                    uiProviderPresentation: business.providerPresentation, decodeResources: business.decodeResources,
                    context: applicationContext)
                let photographerSessionID = applicationControlSessionID
                let photographerAgent = try PhotographerAgent(
                    sessionID: photographerSessionID, uiCamera: cameraUI, controlsArm: true, uiAlbum: albumUI,
                    cameraObservationFailure: { error in
                        containerFailures.report(
                            module: "agents", component: "camera", operation: "observe", error: error)
                    },
                    controlAvailable: business.trackingAvailable,
                    context: photographerContext)
                business.bindTracking { [weak photographerAgent] in
                    await photographerAgent?.hasFreshPose() ?? false
                }
                let historySessionID = applicationControlSessionID
                let policy = try CommunicationPolicy(
                    contracts: AgentContracts.communication,
                    configurations: [
                        "Assistant", "SpeechPerception", "VisionPerception", "Photographer", "SpeechSynthesis",
                        "Memory", "ApplicationControl",
                    ]
                    .map {
                        try AgentConfigurations.load(named: $0)
                    })
                let historyAgent = try MemoryAgent(
                    sessionID: historySessionID, uiHistory: historyUI,
                    beforeNewConversation: {
                        if try await assistantContext.snapshot().state.skillState?.activeTaskID != nil {
                            guard let control = await business.tasks.handler else {
                                throw CommunicationError.unavailableTarget
                            }
                            _ = try await control(
                                "cancelTask", ["reason": "用户开始新对话"], "assistant",
                                applicationControlSessionID, UUID().uuidString, nil)
                        }
                    }, context: memoryContext)
                let execution = business.executor
                let catalog = business.catalog
                try BehaviorCoverage.validate(
                    catalog: catalog,
                    capabilities: [
                        AssistantAgent.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities),
                        SpeechPerceptionAgent.runtimeCapabilities(
                            AgentConfigurations.load(named: "SpeechPerception").capabilities),
                        VisionPerceptionAgent.runtimeCapabilities(
                            AgentConfigurations.load(named: "VisionPerception").capabilities),
                        PhotographerAgent.runtimeCapabilities(
                            AgentConfigurations.load(named: "Photographer").capabilities),
                        AgentConfigurations.load(named: "SpeechSynthesis").capabilities,
                        historyAgent.descriptor.capabilities, applicationControlAgent.descriptor.capabilities,
                    ] + AgentConfigurations.skillRegistries())
                let configuration = AgentGatewayConfiguration(
                    executor: execution, catalog: catalog, policy: policy, resources: business.resources,
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
                    observedContracts: ["speech.partial", "speech.final", "speech.phase"],
                    observeEvent: { input in
                        guard let observation = input.payload.perception else { return }
                        switch observation {
                        case .transcript(let text, true): try await business.observeTranscript(text, input.sessionID)
                        case .speechPhase(.empty): try await business.observeEmpty(input.sessionID)
                        default: break
                        }
                    }, sink: { await business.output($0.actionObservation) })
                return AgentExecutionBinding(configuration: configuration) { facilities in
                    try AgentRuntime(
                        facilities: facilities, business: business, contextScope: contextScope, home: home,
                        containerFailures: containerFailures, cache: cache, assistantContext: assistantContext,
                        conversations: conversations, applicationControlSessionID: applicationControlSessionID,
                        activity: activity, photographerAgent: photographerAgent,
                        applicationControlAgent: applicationControlAgent, historyAgent: historyAgent,
                        stateContext: stateContext, cameraControl: cameraControl, chatProvider: chatProvider,
                        modelName: modelName, assistantContainer: assistantContainer,
                        applicationControlContainer: applicationControlContainer, memoryContainer: memoryContainer,
                        photographerContainer: photographerContainer)
                }
            }
        }
        private init(
            facilities: AgentGatewayCapabilities, business: AgentBusinessBindings, contextScope: String,
            home: UIHomeContainer, containerFailures: ContainerFailureChannel, cache: CacheContainer,
            assistantContext: AgentContextRepository<AssistantContextState>, conversations: ConversationHistoryStore,
            applicationControlSessionID: String, activity: ActionActivityWorkflow, photographerAgent: PhotographerAgent,
            applicationControlAgent: ApplicationControlAgent, historyAgent: MemoryAgent,
            stateContext: AgentStateContext, cameraControl: any AgentCameraAccess,
            chatProvider: @escaping @Sendable () async throws -> any ChatCapability,
            modelName: @escaping @Sendable () async throws -> String, assistantContainer: AssistantContainer,
            applicationControlContainer: ApplicationControlContainer, memoryContainer: MemoryContainer,
            photographerContainer: PhotographerContainer
        ) throws {
            self.contextScope = contextScope
            self.uiHome = home
            self.containerFailures = containerFailures
            self.cacheStorage = cache
            self.assistantContext = assistantContext
            self.conversations = conversations
            self.interactionSessionID = applicationControlSessionID
            let manager = facilities.manager
            let input = facilities.input
            let resources = facilities.resources
            let actions = facilities.actions
            let gateway = facilities.output
            self.observations = facilities.observations
            self.manager = manager
            self.input = input
            self.resources = resources
            self.actions = actions
            self.output = gateway
            self.business = business
            actionActivity = activity
            business.bindResources(resources, actions)
            business.bindDeferredFailure { result in
                let feedback = ActionResult(
                    executionID: result.executionID, owner: result.owner,
                    path: .init(domain: result.path.domain, module: result.path.module, function: result.path.function),
                    causality: .init(inputID: result.context.inputID, rootID: result.context.inputID, hops: 0),
                    status: result.report?.status == .partialFailure ? .partialFailure : .failed,
                    effect: .unknown, completion: result.report.map { .report($0.agentValue) }, failure: .handlerFailed)
                return await input.deliverActionResult(feedback) == .accepted
            }
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
            business.tasks.handler = { operation, arguments, source, session, input, decision in
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
                cache: cacheStorage, manager: manager, output: output,
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

    }

#endif

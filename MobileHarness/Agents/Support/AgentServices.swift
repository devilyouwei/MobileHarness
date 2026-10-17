import StorageCache
import StorageFiles
import StorageState

#if os(iOS)
    import Actions
    import AgentCore
    import Agents
    import ActionBindings
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
    final class AgentServices {
        private let cacheStorage: CacheContainer
        private let bluetooth: BluetoothWorkflow
        let resourceObservation: ResourceObservationWorkflow
        private let providerPresentation: ProviderPresentationAdapter
        private let providerSettings: ProviderSettingsRequests
        private let providerRequests: ProviderDiscoveryRequests
        private let applicationControlSessionID: String
        let applicationControlIntents: ApplicationControlIntentRuntime
        let photographerIntents: PhotographerIntentRuntime
        let historyIntents: HistoryIntentRuntime
        let interaction: AgentInteractionRuntime
        let interactionSessionID: String
        private var skillObservation: Task<Void, Never>?
        func setForeground(_ foreground: Bool) async throws {
            try await interaction.setForeground(foreground)
        }

        func start() async throws { try await interaction.start() }

        private var titleMutations: HistoryMutationService?
        func shutdown() async {
            skillObservation?.cancel()
            await skillObservation?.value
            await interaction.shutdown()
            await photographerIntents.shutdown()
            await historyIntents.shutdown()
            await titleMutations?.shutdown()
            await applicationControlIntents.shutdown()
            await manager.stopAll()
            bluetooth.service.nativeObservation = nil
            await output.shutdown()
        }
        private let assistantContext: AgentContextRepository<AssistantContextState>
        let conversations: ConversationHistoryStore
        let manager: AgentManager
        let input: InputGateway
        let output: OutputGateway
        let presentation: RuntimePresentation
        private let photoCamera: any CameraControlCapability
        let actions: ChannelScheduler
        let actionActivity: ActionActivityWorkflow
        let resources: ResourceCoordinator

        func startNewConversation() async throws {
            if try await assistantContext.snapshot().state.skillState?.activeTaskID != nil {
                guard let control = presentation.taskControl else { throw CommunicationError.unavailableTarget }
                _ = try await control(
                    "cancelTask", ["reason": "用户开始新对话"], "assistant", interactionSessionID, UUID().uuidString,
                    nil)
            }
            try await historyIntents.startNew()
        }

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
        private func finishProviderSettings(_ id: String, operation: ProviderSettingsIntent.Operation) async throws
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
            state: StateContainer, cache: CacheContainer, files: FilesContainer,
            chatRecords: any ChatRepository, taskRecords: any TaskRepository, camera: any CameraCapturing,
            readHistoryPhoto: @escaping @Sendable (String, String) async throws -> Data?,
            cameraControl: any CameraControlCapability,
            bluetooth: BluetoothWorkflow,
            historyState: ConversationHistoryState, resourceState: ModelResourcesState, providerState: SettingsState,
            navigationState: NavigationState, device: DeviceControlAdapter,
            modelResources: any ModelResourceCapability,
            providerSettingsRuntime: ProviderSettingsRuntime,
            resourcePreferences: any ModelResourcePreferencesCapability,
            resourceInventory: any ModelResourceInventoryCapability,
            resourceFingerprint: @escaping @MainActor () async throws -> String,
            resourceSnapshotAccepted: @escaping @MainActor () -> Void,
            summarizeTitle: @escaping @Sendable (StoredConversation) async throws -> String,
            modelName: @escaping @Sendable () async throws -> String = { "Unspecified model" },
            chatProvider: @escaping @Sendable () async throws -> any ChatCapability
        ) throws {
            self.cacheStorage = cache
            try AgentConfigurations.installDeclarations(CapabilityModules.declarations)
            self.photoCamera = cameraControl
            let assistantContext = try AgentContextRepository(
                agent: .assistant, scope: Self.contextScope, state: AssistantContextState())
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
            self.providerSettings = providerSettings
            let applicationControlSessionID = UUID().uuidString
            self.applicationControlSessionID = applicationControlSessionID
            self.interactionSessionID = applicationControlSessionID
            let providerRequests = ProviderDiscoveryRequests(discover: SettingsProviderAdapter.discoverModels)
            self.providerRequests = providerRequests
            let providerPresentation = ProviderPresentationAdapter(
                state: providerState, sessionID: applicationControlSessionID, settings: providerSettings,
                discovery: providerRequests)
            self.providerPresentation = providerPresentation
            let applicationContext = try Self.context(
                .applicationControl, ApplicationControlContextState())
            let photographerContext = try Self.context(.photographer, PhotographerContextState())
            let memoryContext = try Self.context(.memory, MemoryContextState())
            let applicationControlAgent = try ApplicationControlAgent(
                sessionID: applicationControlSessionID,
                context: applicationContext)
            device.environment = { try await applicationControlAgent.environmentSnapshot() }
            let photographerSessionID = applicationControlSessionID
            let photographerAgent = try PhotographerAgent(
                sessionID: photographerSessionID, controlsArm: true,
                controlAvailable: { await bluetooth.trackingAvailable },
                context: photographerContext)
            bluetooth.trackingInputAvailable = { [weak photographerAgent] in
                await photographerAgent?.hasFreshPose() ?? false
            }
            let historySessionID = applicationControlSessionID
            let historyReads = MemoryHistoryReadRequests { query in
                switch query {
                case .conversation(let id): return .conversation(try await historyStore.page(id))
                case .message(let id): return .conversation(try await historyStore.message(id))
                case .page(let id, let after, let taskID):
                    return .conversation(try await historyStore.page(id, after: after, taskID: taskID))
                case .archives(let cursor): return .archives(try await historyStore.archivePage(before: cursor))
                case .photo(let id, let inputID): return .photo(try await readHistoryPhoto(id, inputID))
                }
            }
            let historyAgent = try MemoryAgent(
                sessionID: historySessionID, historyReads: historyReads, context: memoryContext)
            let historyPresentation = HistoryPresentationAdapter(
                state: historyState, store: conversations, sessionID: historySessionID)
            let policy = try CommunicationPolicy(
                contracts: AgentContracts.communication,
                externalSources: DeviceInputAdapter.sources.union([
                    "user", "runtime", ModelResourceObservation.source, ModelResourceHostFailure.source,
                    AppEnvironmentFact.source,
                ]),
                configurations: [
                    "Assistant", "SpeechPerception", "VisionPerception", "Photographer", "SpeechSynthesis",
                    "Memory", "ApplicationControl",
                ]
                .map {
                    try AgentConfigurations.load(named: $0)
                })
            let manager = AgentManager()
            let activity = ActionActivityWorkflow(state: ActionActivityState())
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
                publicationFailure: { input, _, reason in
                    await historyReads.reject(
                        input.id, sessionID: input.sessionID,
                        error: HistoryIntentFailure.execution(reason))
                })
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
            let presentation = RuntimePresentation(
                cameraControl: cameraControl, rootSessionID: photographerSessionID, activity: activity.state)
            self.bluetooth = bluetooth
            bluetooth.service.nativeObservation = { value in
                try await input.publish(DeviceInputAdapter.bluetooth(value))
            }
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
                        let presentation = try await HistoryPresentationAdapter.listPresentation(historyStore)
                        await MainActor.run {
                            historyState.archive = presentation
                            historyState.status = message
                        }
                    } catch { await MainActor.run { historyState.status = "历史刷新失败：\(error)" } }
                }, titlePositions: { ConversationTitleGenerator.samplePositions(count: $0) })
            titleMutations = mutations
            let behaviors = try BehaviorAssembly(
                presentation: presentation, playback: presentation, pose: presentation,
                historyPresentation: historyPresentation, camera: presentation,
                history: HistoryQueryService(store: conversations),
                historyMutations: mutations,
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
                ] + AgentConfigurations.skillRegistries())
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
                    Logger(subsystem: "dev.mobileharness", category: "Photographer").error(
                        "\(message, privacy: .private)")
                })
            photographerIntents = photography
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
                    try await intents.observe(observation, sequence: sequence)
                    // Local publication submission, not subscriber admission or business completion.
                    return .accepted
                },
                invalidate: { resourceState.beginRefresh() },
                report: { _ in resourceState.error = "资源状态更新失败，请稍后重试。" })
            let history = HistoryIntentRuntime(
                sessionID: historySessionID, manager: manager, input: input, output: gateway, agent: historyAgent)
            historyIntents = history
            let main = try AssistantAgent(
                stateContext: AgentStateContext(storage: state, agent: .assistant),
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
            presentation.taskControl = { operation, arguments, source, session, input, decision in
                try await main.controlTask(
                    operation, arguments: arguments, source: source, sessionID: session, inputID: input,
                    decisionID: decision)
            }
            let interaction = AgentInteractionRuntime(
                agent: main, manager: manager, input: input, output: gateway,
                startChildren: {
                    try await photography.prepareForInteraction()
                    try await history.prepareForInteraction()
                    try await intents.prepareForInteraction()
                },
                report: { message in
                    Logger(subsystem: "dev.mobileharness", category: "Agents").error("\(message, privacy: .private)")
                },
                inputRejected: { id, reason in
                    await photography.rejectInput(id, reason: reason)
                    await history.rejectInput(id, reason: reason)
                    await intents.rejectInput(id, reason: reason)
                })
            self.interaction = interaction
            skillObservation = Task { [activity] in
                var previous: [String: String] = [:]
                for await skills in main.skillUpdates {
                    guard !Task.isCancelled else { return }
                    let active = skills.tasks.first { $0.id == skills.activeTaskID }
                    activity.state.currentTaskID = active?.id
                    activity.state.skillOwnership = Dictionary(
                        uniqueKeysWithValues: skills.loaded.map { ($0, (try? skills.ownership($0)) ?? "unknown") })
                    activity.state.currentTaskTitle = active?.goal ?? ""
                    activity.state.currentTaskStatus = active?.status ?? ""
                    activity.state.loadedSkills = skills.loaded
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
                        activity.state.updateTask(
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
        private static let contextScope = "00000000-0000-0000-0000-000000000001"
        private static func context<State: AgentContextState>(_ agent: AgentID, _ state: State)
            throws -> AgentContextRepository<State>
        {
            try AgentContextRepository(agent: agent, scope: contextScope, state: state)
        }
        var voiceDependencies: VoiceRuntimeDependencies {
            VoiceRuntimeDependencies(
                cache: cacheStorage, manager: manager, input: input, output: output, presentation: presentation,
                conversations: conversations,
                interactionSessionID: interactionSessionID,
                startInteraction: { [interaction] in try await interaction.start() },
                cancelReply: { [interaction, interactionSessionID] in
                    try await interaction.interruptConversation(sessionID: interactionSessionID)
                },
                stopInteraction: { [weak self] in await self?.shutdown() },
                makeSynthesis: {
                    try SpeechSynthesisAgent(
                        synthesis: $0, store: $1,
                        context: try Self.context(
                            AgentID(rawValue: "speechSynthesis"), SpeechSynthesisContextState()))
                },
                makePerception: { [interactionSessionID] in
                    try SpeechPerceptionAgent(
                        recognition: $0, vad: $1, sessionID: $2, interactionSessionID: interactionSessionID,
                        residentListening: true,
                        context: try Self.context(
                            .speechPerception, SpeechPerceptionContextState()))
                })
        }
        func visionContext() throws -> AgentContextRepository<VisionPerceptionContextState> {
            try Self.context(.visionPerception, VisionPerceptionContextState())
        }
        var cameraDependencies: CameraRuntimeDependencies {
            .init(resources: GatewayCameraResources(resources: resources, actions: actions))
        }
    }

#endif

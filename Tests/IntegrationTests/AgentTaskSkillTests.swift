import Actions
import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
@_spi(ModelManagement) import ModelKit
import ModelKitOpenAI
import PlatformKit
import StorageChat
import StorageCore
import StorageSQLite
import Testing

@testable import Agents

@Test(.actionCatalog) func skillTransitionsAreAtomicAndCatalogsStayImmutable() throws {
    let fixedCapabilities = try AssistantAgent.runtimeCapabilities(
        AgentConfigurations.load(named: "Assistant").capabilities)
    var state = AgentTaskSkillState()
    try state.initialize(fixed: fixedCapabilities, baseSkills: try AgentConfigurations.baseSkills(named: "Assistant"))
    let old = try state.registry(fixed: fixedCapabilities)
    let input = UUID().uuidString
    _ = try state.control(
        "task.start", arguments: ["skills": "[\"photography\"]", "description": "拍照"], inputID: input,
        fixed: fixedCapabilities,
        taskID: try fixtureTaskID())
    #expect(!old.actions.contains { $0.alias == "takePhoto" })
    #expect(try state.registry(fixed: fixedCapabilities).actions.contains { $0.alias == "takePhoto" })
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let encoded = try encoder.encode(state)
    #expect(throws: (any Error).self) {
        try state.control(
            "task.start", arguments: ["skills": "[\"history-query\"]", "description": "另一个任务"],
            inputID: UUID().uuidString,
            fixed: fixedCapabilities, taskID: try fixtureTaskID())
    }
    #expect(try encoder.encode(state) == encoded)
    #expect(throws: (any Error).self) {
        try state.control(
            "loadSkills", arguments: ["skills": "[\"missing\"]"], inputID: input, fixed: fixedCapabilities)
    }
    #expect(try encoder.encode(state) == encoded)
    #expect(throws: CommunicationError.unauthorized) {
        try state.control(
            "releaseSkills", arguments: ["skills": "[\"expression-interaction\"]"], inputID: input,
            fixed: fixedCapabilities)
    }
    try state.decisionCompleted(failed: false, fixed: fixedCapabilities)
    #expect(state.tasks.last?.status == "waitingUser")
    let task = try #require(state.activeTaskID)
    _ = try state.control("task.end", arguments: ["summary": "已保存"], inputID: input, fixed: fixedCapabilities)
    #expect(state.activeTaskID == task && state.mode == "task")
    try state.decisionCompleted(failed: false, fixed: fixedCapabilities)
    #expect(state.activeTaskID == nil && state.mode == "default" && state.tasks.last?.status == "completed")
    #expect(state.events.contains { $0.operation == "release" && $0.skill == "photography" && $0.taskID == task })
    #expect(throws: CommunicationError.scopeClosed) { try state.bind(UUID().uuidString, task: task) }
}

@Test(.actionCatalog) func foregroundTasksCanRestartOnlyAfterClosure() throws {
    let fixed = try AssistantAgent.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities)
    var state = AgentTaskSkillState()
    try state.initialize(fixed: fixed, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    let input = UUID().uuidString
    _ = try state.control(
        "task.start", arguments: ["description": "旧目标", "skills": "[\"photography\"]"], inputID: input, fixed: fixed,
        taskID: try fixtureTaskID())
    let first = try #require(state.activeTaskID)
    try state.decisionCompleted(failed: false, fixed: fixed)
    #expect(state.tasks.last?.status == "waitingUser")
    _ = try state.control("task.end", arguments: ["summary": "用户改为新目标，旧目标未完成"], inputID: input, fixed: fixed)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let closing = try encoder.encode(state)
    #expect(throws: CommunicationError.invalidPayload) {
        try state.control(
            "task.start", arguments: ["description": "新目标"], inputID: input, fixed: fixed, taskID: try fixtureTaskID())
    }
    #expect(try encoder.encode(state) == closing)
    try state.decisionCompleted(failed: false, fixed: fixed)
    #expect(state.activeTaskID == nil)
    _ = try state.control(
        "task.start", arguments: ["description": "后置镜头拍照", "skills": "[\"photography\"]"], inputID: input, fixed: fixed,
        taskID: try fixtureTaskID())
    let second = try #require(state.activeTaskID)
    #expect(first != second && state.taskID(for: input) == second)
    #expect(state.tasks.first?.summary == "用户改为新目标，旧目标未完成")
    _ = try state.control("task.end", arguments: ["summary": "已保存"], inputID: input, fixed: fixed)
    try state.decisionCompleted(failed: false, fixed: fixed)
    _ = try state.control(
        "task.start", arguments: ["description": "再拍一张", "skills": "[\"photography\"]"], inputID: UUID().uuidString,
        fixed: fixed, taskID: try fixtureTaskID())
    #expect(state.tasks.count == 3 && state.activeTaskID != second)
}

@Test(.actionCatalog) func allBundledSkillsHaveValidBoundedEffectiveCatalogs() throws {
    let fixedCapabilities = try AssistantAgent.runtimeCapabilities(
        AgentConfigurations.load(named: "Assistant").capabilities)
    for skill in ["photography", "history-query", "application-control", "web-browsing"] {
        var state = AgentTaskSkillState()
        try state.initialize(
            fixed: fixedCapabilities, baseSkills: try AgentConfigurations.baseSkills(named: "Assistant"))
        _ = try state.control(
            "task.start", arguments: ["skills": "[\"\(skill)\"]", "description": "fixture"],
            inputID: UUID().uuidString,
            fixed: fixedCapabilities, taskID: try fixtureTaskID())
        let registry = try state.registry(fixed: fixedCapabilities)
        let paths = registry.actions.map { $0.path.description } + registry.tools.map(\.path)
        #expect(Set(paths).count == paths.count)
        #expect(registry.tools.allSatisfy { !$0.path.hasSuffix(".send") })
        state.recover()
        #expect(state.activeTaskID == nil && state.mode == "default" && state.tasks.last?.status == "interrupted")
    }
    // Loading a bundled Skill grants its declared Actions, including query Actions.
    let fixed = try CapabilityRegistry()
    var state = AgentTaskSkillState()
    try state.initialize(fixed: fixed, baseSkills: [])
    let before = try state.registry(fixed: fixed)
    #expect(throws: GenerationError.unknownCapability) { try before.resolveAction("takePhoto", parameters: [:]) }
    _ = try state.control(
        "task.start", arguments: ["skills": "[\"photography\",\"history-query\"]", "description": "fixture"],
        inputID: UUID().uuidString, fixed: fixed, taskID: try fixtureTaskID())
    let loaded = try state.registry(fixed: fixed)
    #expect(try loaded.resolveAction("takePhoto", parameters: [:]).actionPath.description == "Camera.Capture.takePhoto")
    #expect(loaded.actions.contains { $0.path.description == "History.Conversation.read" })
    #expect(loaded.tools.isEmpty)
    #expect(!before.actions.contains { $0.alias == "takePhoto" })

}

private actor SkillModel: ChatCapability {
    nonisolated let availability: CapabilityAvailability = .available
    nonisolated let supportsImages: Bool
    nonisolated let supportsToolCalls = true
    let mediaID: String
    let rejectFirst: Bool
    let replaceForeground: Bool
    let captureOnly: Bool
    let followUpAlias: String?
    let expireBeforeFollowUp: Bool
    private(set) var requests: [ChatRequest] = []
    init(
        mediaID: String, rejectFirst: Bool = false, replaceForeground: Bool = false, captureOnly: Bool = false,
        supportsImages: Bool = false, followUpAlias: String? = nil, expireBeforeFollowUp: Bool = false
    ) {
        self.supportsImages = supportsImages
        self.mediaID = mediaID
        self.rejectFirst = rejectFirst
        self.replaceForeground = replaceForeground
        self.captureOnly = captureOnly
        self.followUpAlias = followUpAlias
        self.expireBeforeFollowUp = expireBeforeFollowUp
    }
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        requests.append(request)
        let output: String
        if captureOnly {
            if let followUpAlias, requests.count > 4 {
                let round = requests.count - (expireBeforeFollowUp ? 5 : 0)
                if expireBeforeFollowUp && requests.count <= 9 {
                    output = "无关话题已回复。"
                } else if !expireBeforeFollowUp {
                    let parameters = followUpAlias == "closeCamera" ? "" : " previewID=\"\(mediaID)\""
                    output = requests.count == 5 ? "<\(followUpAlias)\(parameters)/>" : "处理完成。"
                } else {
                    switch round {
                    case 5, 7:
                        let alias = followUpAlias
                        let parameters = alias == "closeCamera" ? "" : " previewID=\"\(mediaID)\""
                        output = "<\(alias)\(parameters)/>"
                    case 6: output = "<loadSkills skills='[\"photography\"]'/>"
                    default: output = "处理完成。"
                    }
                }
            } else {
                switch requests.count {
                case 1: output = "<loadSkills skills='[\"photography\"]'/>"
                case 2: output = "<openCamera/>"
                case 3: output = "<takePhoto/>"
                default: output = "拍好了。"
                }
            }
        } else if replaceForeground && requests.count >= 4 {
            switch requests.count {
            case 4: output = "<task.end summary=\"用户切换目标，旧照片未保存\" continueDecision=\"true\"/>"
            case 5: output = "<task.start description=\"新拍照目标\" skills='[\"photography\"]'/>"
            case 6: output = "<takePhoto/>"
            default: output = "新照片需要保存吗？"
            }
        } else {
            switch requests.count - (rejectFirst ? 1 : 0) {
            case 0: output = "<photography/>"
            case 1: output = "<task.start description=\"拍照 fixture\" skills='[\"photography\"]'/>"
            case 2: output = "<takePhoto/>"
            case 3: output = "需要保存吗？"
            case 4: output = "<savePhoto previewID=\"\(mediaID)\"/>"
            case 5: output = "<task.end summary=\"照片已保存\"/>"
            case 6: output = "<task.start description=\"再拍一张 fixture\" skills='[\"photography\"]'/>"
            case 7: output = "<takePhoto/>"
            case 8: output = "需要保存新照片吗？"
            default: output = "<express emotion=\"happy\"/>"
            }
        }
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        try pair.emitter.yield(.text(output))
        try pair.emitter.yield(.finished(.stop))
        pair.emitter.finish()
        return pair.session
    }
}
private struct SkillControls: TaskControlCapability {
    let agent: AssistantAgent
    func controlTask(_ operation: String, arguments: [String: String], invocation: any FunctionInput) async throws
        -> String
    {
        try await agent.controlTask(
            operation, arguments: arguments, source: invocation.context.source,
            sessionID: invocation.context.sessionID, inputID: invocation.context.inputID,
            decisionID: invocation.context.decisionID)
    }
}
private actor SkillEffects {
    private(set) var owners: [String] = []
    private(set) var completed = 0
    private(set) var failures: [String] = []
    private(set) var paths: [String] = []
    private(set) var currentPhoto: String?
    private var cameraSequence: UInt64 = 1
    func nextCameraSequence() -> UInt64 {
        cameraSequence += 1
        return cameraSequence
    }
    func newPhoto() -> String {
        let id = "preview_\(max(1, paths.filter { $0 == "Camera.Capture.takePhoto" }.count))"
        currentPhoto = id
        return id
    }
    func resolvePhoto(_ id: String?) throws {
        guard id != nil && id == currentPhoto else { throw CommunicationError.invalidPayload }
    }
    func performed(_ path: String) { paths.append(path) }
    func capture(_ owner: String) { owners.append(owner) }
    func finish() { completed += 1 }
    func fail(_ failure: String) { failures.append(failure) }
}
private func skillEventually(_ predicate: @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(90))
    while !(try await predicate()) {
        guard ContinuousClock.now < deadline else { throw CommunicationError.expired }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) func assistantPhotographyUsesLocalTaskAcrossUserInputsAndReACT()
    async throws
{
    try await photographyAcceptance(live: false)
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func rejectedSkillTagCorrectsThroughTaskLoadingAndCapture() async throws {
    try await photographyAcceptance(live: false, rejectFirst: true)
}

@Test(
    .actionCatalog, .enabled(if: ProcessInfo.processInfo.environment["MH_OPENAI_ACCEPTANCE"] == "1"),
    .timeLimit(.minutes(12)))
func liveResponsesPhotographySkillsAndTitle() async throws {
    for cameraFacts in [true, false] {
        for run in 0..<3 {
            try await photographyAcceptance(live: true, cameraFacts: cameraFacts, run: run)
        }
    }
}

private actor LiveTextChat: ChatCapability {
    nonisolated let availability: CapabilityAvailability = .available
    nonisolated let supportsImages = false
    nonisolated let supportsToolCalls = true
    let model: OpenAIChat
    init(key: String) throws {
        model = try OpenAIChat(
            context: ModelContext(loadGate: ModelLoadGate(maximumConcurrentLoads: 4), maximumLoadWaiters: 32),
            configuration: OpenAIChatConfiguration(
                baseURL: OpenAIChatConfiguration.endpoint(""), apiKey: key, model: "gpt-4.1"))
    }
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        try await model.chat(request)
    }
}

private func photographyAcceptance(
    live: Bool, cameraFacts: Bool = true, rejectFirst: Bool = false, run: Int = 0, replaceForeground: Bool = false,
    captureOnly: Bool = false, supportsImages: Bool = false, followUpAlias: String? = nil,
    expireBeforeFollowUp: Bool = false, persistent: Bool = false
)
    async throws
{
    let photo = "preview_1"
    let session = UUID().uuidString
    let stub = SkillModel(
        mediaID: photo, rejectFirst: rejectFirst, replaceForeground: replaceForeground, captureOnly: captureOnly,
        supportsImages: supportsImages, followUpAlias: followUpAlias, expireBeforeFollowUp: expireBeforeFollowUp)
    let model: any ChatCapability
    if live {
        let key = try #require(ProcessInfo.processInfo.environment["OPENAI_API_KEY"])
        model = try LiveTextChat(key: key)
    } else {
        model = stub
    }
    let context = try AgentContextRepository(
        agent: AgentID.assistant, scope: UUID().uuidString, state: AssistantContextState()
    )
    let persistentRecords = try persistent ? SQLiteRepositories.temporary() : nil
    let store: AssistantHistoryStore
    if let persistentRecords {
        store = try AssistantConversationStorage.store(
            repository: context, messages: persistentRecords.assistantMessages, tasks: persistentRecords.assistantTasks,
            conversations: persistentRecords.assistantConversations, logs: persistentRecords.logs)
    } else {
        store = AssistantHistoryStore()
    }
    let publicOwner = PublicStateFixtureOwner(ready: cameraFacts)
    let publicContext = try publicOwner.context()
    let agent = try AssistantAgent(
        stateContext: publicContext,
        chat: model, conversations: store, communications: persistentRecords?.agentMessages,
        observations: { values, input, chat in
            try await AssistantContextBuilder.webImageObservations(
                values, input: input, chat: chat,
                read: { id, _ in try ChatImage(id: id, data: Data([1])) },
                prepareJPEG: { data, _ in data })
        }, context: context)
    _ = try await bindSpeechRequests(agent)
    let manager = AgentManager()
    try await manager.register(agent)
    let input = InputGateway(manager: manager)
    let effects = SkillEffects()
    let definitions = [
        "Camera.Capture.takePhoto", "Camera.Capture.savePhoto", "Camera.Capture.open",
        "Camera.Capture.close", "Camera.Capture.flip", "Camera.Capture.retry", "NexArm.Gesture.nodHead",
        "NexArm.Gesture.waveWrist", "UI.Caption.beginReplyTurn", "UI.Caption.print",
        "Speech.Playback.speak", "UI.Expression.express",
    ].map { path in
        let parts = path.split(separator: ".").map(String.init)
        return ActionBinding(
            path: .init(domain: parts[0], module: parts[1], function: parts[2]), displayName: path,
            kind: .finite, completion: "Synthetic confirmed effect",
            completing: { invocation in
                if path == "Camera.Capture.takePhoto" {
                    publicOwner.application.update { $0["modelPreparation"] = "loading" }
                }
                await effects.performed(path)
                if path.hasPrefix("Camera.") {
                    await effects.capture(invocation.context.source)
                    if path == "Camera.Capture.close" || path == "Camera.Capture.open" {
                        let enabled = path == "Camera.Capture.open"
                        publicOwner.camera.update {
                            $0 = FixtureCameraFact(enabled: enabled, running: enabled)
                        }
                        return .value(
                            String(
                                decoding: try JSONEncoder().encode(
                                    CameraCommandReceipt(operation: enabled ? "open" : "close", enabled: enabled)),
                                as: UTF8.self))
                    }
                    let id: String
                    let captureCount = await effects.paths.filter { $0 == "Camera.Capture.takePhoto" }.count
                    if path == "Camera.Capture.takePhoto" && (live || captureCount > 1) {
                        id = await effects.newPhoto()
                    } else if live && ["Camera.Capture.savePhoto"].contains(path) {
                        id = try #require(invocation.call.parameters["previewID"])
                        try await effects.resolvePhoto(id)
                    } else {
                        id = photo
                    }
                    publicOwner.camera.update { state in
                        var fact = state
                        if path == "Camera.Capture.takePhoto" { fact.displayedMediaID = id }
                        if path == "Camera.Capture.savePhoto" {
                            fact.savedMediaID = id
                            fact.displayedMediaID = nil
                        }
                        state = fact
                    }
                    if live && ["Camera.Capture.savePhoto"].contains(path) {
                        return .value(
                            String(
                                decoding: try JSONEncoder().encode(
                                    CameraPhotoCommandReceipt(
                                        previewID: id, state: .saved)),
                                as: UTF8.self))
                    }
                    return .value(
                        String(
                            decoding: try JSONEncoder().encode(
                                CameraPhotoReceipt(previewID: id, width: 640, height: 480)), as: UTF8.self))
                }
                return .completed
            })
    }
    struct Module: ActionModule { let definitions: [ActionBinding] }
    let controls = TaskControlModule(capability: SkillControls(agent: agent))
    let controlAssembly = try BehaviorAssembly(capabilityModules: [controls])
    let controlBindings = try controls.definitions.map { try controlAssembly.actions.definition(for: $0.path) }
    for control in controlBindings {
        #expect(control.protocols == [.action])
        #expect(await controlAssembly.tools.handler(for: control.path.description) == nil)
    }
    let history = HistoryModule(
        history: HistoryQueryService(store: store),
        mutations: HistoryMutationService(
            store: store, summarizeTitle: { try await ConversationTitleGenerator.summarize($0, using: model) }))
    let historyAssembly = try BehaviorAssembly(capabilityModules: [controls, history])
    let historyBindings = try history.definitions.filter { ["list", "read"].contains($0.path.function) }
        .map { try historyAssembly.actions.definition(for: $0.path) }
    let scheduler = ChannelScheduler(
        registry: try ActionRegistry(modules: [
            Module(definitions: definitions + controlBindings + historyBindings)
        ])
    ) { await input.deliverActionResult($0) }
    let tools = historyAssembly.tools
    let gateway = await OutputGateway(
        manager: manager, requests: input, tools: tools, actions: scheduler, sink: { _ in })
    try await agent.start()
    let consumer = try await gateway.consumer(for: agent)
    let pump = Task {
        try await IndependentOutputWorkflow.consumeGeneration(fixtureOutputs(agent)) { output in
            let result = try await consumer.execute(output)
            if result.isError {
                await effects.fail(result.failure ?? result.tool?.value ?? "execution failed")
                if live {
                    print("Live fixture rejected output: \(output.output); tool=\(result.tool?.value ?? "none")")
                }
            }
            if case .control(let text) = output.output {
                if text == "agent.finished" { await effects.finish() }
                if text.hasPrefix("agent.error:") { await effects.fail(text) }
            }
        }
    }
    let first = AgentInput(
        id: UUID().uuidString,
        sessionID: session,
        payload: .text(captureOnly ? "可以帮我拍张照吗，但是不需要后续操作" : (live ? "你好，帮我拍张照。" : "拍照 fixture")))
    _ = try await manager.receiveLocally(first, to: .assistant)
    try await skillEventually {
        let completed = await effects.completed
        let failures = await effects.failures
        return completed == 1 || failures.contains { $0.hasPrefix("agent.error:") }
    }
    let failures = await effects.failures
    if !live && !rejectFirst {
        let evidence = try await store.snapshot()
        try JSONEncoder().encode(evidence.current).write(
            to: URL(fileURLWithPath: "/tmp/mh-compaction-current-fixture.json"), options: .atomic)
    }
    if live {
        let evidence = try await store.snapshot()
        try JSONEncoder().encode(evidence.current).write(
            to: URL(fileURLWithPath: "/tmp/mh-live-photography-evidence.json"), options: .atomic)
    }
    if rejectFirst {
        #expect(
            failures.count == 1 && failures[0].contains("unknownCapability"),
            Comment(rawValue: failures.joined(separator: "\n")))
    } else {
        #expect(failures == [], Comment(rawValue: failures.joined(separator: "\n")))
    }
    if captureOnly {
        let snapshot = try await context.snapshot()
        let requests = await stub.requests
        let history = try #require(snapshot.state.history.current.turns.first)
        #expect(snapshot.state.skillState?.activeTaskID == nil && snapshot.state.skillState?.tasks.isEmpty == true)
        #expect(history.state == .completed && history.error == nil)
        #expect(requests.count == 4)
        #expect(requests.last?.messages.contains { $0.content.contains(photo) } == true)
        #expect(
            requests.last?.messages.contains { $0.images?.contains { $0.id == photo } == true }
                == supportsImages)
        #expect(history.modelRequests?.allSatisfy { $0.decisionMetadata?.taskID == nil } == true)
        #expect(
            await effects.paths.filter { $0.hasPrefix("Camera.") } == [
                "Camera.Capture.open", "Camera.Capture.takePhoto",
            ])
        #expect(
            !history.raw.contains("task.start") && !history.raw.contains("task.end") && !history.raw.contains("保存"))
        #expect(snapshot.state.skillState?.recentSkills["photography"]?.remainingDecisions == 5)
        if followUpAlias == nil {
            _ = try await manager.receiveLocally(
                .init(id: UUID().uuidString, sessionID: session, payload: .text("继续看这张图片")), to: .assistant)
            try await skillEventually { await effects.completed == 2 }
            let followUpRequests = await stub.requests
            let images = followUpRequests.last?.messages.flatMap { $0.images ?? [] } ?? []
            #expect(images.map(\.id) == (supportsImages ? [photo] : []))
            let latestInput = try #require(followUpRequests.last?.messages.last { $0.content == "继续看这张图片" })
            #expect(latestInput.images?.map(\.id) ?? [] == (supportsImages ? [photo] : []))
            #expect(followUpRequests.last?.messages.filter { $0.content == "继续看这张图片" }.count == 1)
            #expect(await effects.paths.filter { $0 == "Camera.Capture.takePhoto" }.count == 1)
        }
        if let alias = followUpAlias {
            if expireBeforeFollowUp {
                for index in 1...5 {
                    _ = try await manager.receiveLocally(
                        AgentInput(id: UUID().uuidString, sessionID: session, payload: .text("无关聊天 \(index)")),
                        to: .assistant)
                    try await skillEventually { await effects.completed == 1 + index }
                    let remaining = try await context.snapshot().state.skillState?.recentSkills["photography"]?
                        .remainingDecisions
                    #expect(remaining == (index == 5 ? nil : 5 - index))
                }
            }
            let followUp = AgentInput(id: UUID().uuidString, sessionID: session, payload: .text("处理当前预览：\(alias)"))
            _ = try await manager.receiveLocally(followUp, to: .assistant)
            try await skillEventually { await effects.completed == (expireBeforeFollowUp ? 7 : 2) }
            let requests = await stub.requests
            #expect(requests.count == (expireBeforeFollowUp ? 13 : 6))
            if expireBeforeFollowUp {
                let failure = try #require(requests[10].messages.last { $0.content.contains("unknownCapability") })
                #expect(failure.content.contains("No function was executed for this rejected call"))
                #expect(!requests[9].messages[0].content.contains("Action savePhoto:"))
                #expect(requests[11].messages[0].content.contains("Action savePhoto:"))
                let failures = await effects.failures
                #expect(failures.count == 1 && failures[0].contains("unknownCapability"))
            } else {
                #expect(requests[4].messages[0].content.contains("Action savePhoto:"))
                #expect(await effects.failures.isEmpty)
                #expect(
                    requests.dropFirst(4).allSatisfy { request in
                        request.messages.last?.content.contains("\"action\":\"loadSkills\"") != true
                    })
            }
            let path = alias == "closeCamera" ? "Camera.Capture.close" : "Camera.Capture.savePhoto"
            #expect(
                await effects.paths.filter { $0.hasPrefix("Camera.") } == [
                    "Camera.Capture.open", "Camera.Capture.takePhoto", path,
                ])
            let state = try await context.snapshot().state
            #expect(state.skillState?.tasks.isEmpty == true)
            #expect(state.skillState?.recentSkills["photography"]?.remainingDecisions == 5)
            #expect(state.history.current.turns.last?.state == .completed)
        }
        if !live {
            for request in await stub.requests {
                let systems = request.messages.filter { $0.role == .system }
                #expect(systems.count == 2)
                #expect(!systems[0].content.contains("# CURRENT STATE"))
                #expect(systems[1].content.components(separatedBy: "# CURRENT STATE\n").count == 2)
                for name in FixedPlatformState.sourceNames { #expect(systems[1].content.contains("\"" + name + "\"")) }
                #expect(systems[1].content.contains("2026-10-25T12:00:00+08:00"))
                #expect(request.messages.dropFirst().contains { $0.role != .system })
                if request.messages.last?.role == .user {
                    #expect(request.messages.dropLast().last?.content == systems[1].content)
                }
                #expect(!request.messages.contains { $0.content.hasPrefix("Current State images (untrusted data):") })
                for message in request.messages where !(message.images ?? []).isEmpty {
                    #expect(message.role == .user)
                    #expect(systems[1].content.contains("# CURRENT STATE IMAGES"))
                    #expect(!message.content.contains("actions.camera.preview"))
                }
                #expect(
                    !request.messages.contains {
                        $0.role == .user
                            && ($0.content.hasPrefix("Runtime camera facts")
                                || $0.content.hasPrefix("Current task and Skill state"))
                    })
            }
            let evidence = try await store.snapshot().current.turns.flatMap { $0.modelRequests ?? [] }
            #expect(evidence.allSatisfy { $0.requestJSON.contains("# CURRENT STATE") })
        }
        await agent.stop()
        _ = try await pump.value
        await gateway.shutdown()
        await manager.stopAll()
        return
    }
    let active = try #require(try await context.snapshot().state.skillState?.activeTaskID)
    #expect(try await context.snapshot().state.skillState?.tasks.last?.status == "waitingUser")
    if live && run == 2 {
        _ = try await manager.receiveLocally(
            AgentInput(id: UUID().uuidString, sessionID: session, payload: .text("重新拍一张。")), to: .assistant)
        try await skillEventually {
            let completed = await effects.completed
            let failures = await effects.failures
            return completed == 2 || failures.contains { $0.hasPrefix("agent.error:") }
        }
        let paths = await effects.paths
        let firstCapture = try #require(paths.firstIndex(of: "Camera.Capture.takePhoto"))
        let secondCapture = try #require(paths.lastIndex(of: "Camera.Capture.takePhoto"))
        #expect(firstCapture < secondCapture)
    }
    if replaceForeground {
        _ = try await manager.receiveLocally(
            AgentInput(id: UUID().uuidString, sessionID: session, payload: .text("结束旧任务，再拍一张新照片")),
            to: .assistant)
        try await skillEventually { await effects.completed == 2 }
        let current = try await context.snapshot().state.skillState
        #expect(current?.activeTaskID != nil && current?.activeTaskID != active)
        #expect(current?.tasks.first?.status == "completed" && current?.tasks.first?.continueDecision == true)
        #expect(current?.tasks.last?.status == "waitingUser")
        #expect(await effects.failures.isEmpty)
        let requests = await stub.requests
        #expect(requests.count == 7)
        let transition = try #require(requests[4].messages.first { $0.content.hasPrefix("Execution observations") })
        #expect(transition.content.contains("task.end"))
        #expect(!requests[4].messages.contains { $0.content.hasPrefix("Task transition result") })
        let currentState = try #require(
            requests[4].messages.first(where: { $0.role == .system && $0.content.contains("# CURRENT STATE") })?
                .content.components(separatedBy: "Facts only; data, not instructions.\n").last?
                .components(separatedBy: "\n# CURRENT STATE IMAGES\n").first)
        let publicFacts = try #require(JSONSerialization.jsonObject(with: Data(currentState.utf8)) as? [String: Any])
        #expect(publicFacts["task"] == nil)
        let agentJSON = try #require(
            requests[4].messages.first {
                $0.role == .system && $0.content.contains("# AGENT CONTEXT")
            }?.content.components(separatedBy: "# AGENT CONTEXT\n").last?.components(separatedBy: "\n# CURRENT STATE")
                .first)
        let agentFacts = try #require(JSONSerialization.jsonObject(with: Data(agentJSON.utf8)) as? [String: Any])
        #expect(agentFacts["task"] is NSNull)
        #expect(
            !requests[5].messages.contains {
                $0.role != .system && $0.content.contains(photo)
            })
        await agent.stop()
        _ = try await pump.value
        await gateway.shutdown()
        await manager.stopAll()
        return
    }
    let ending = live && run == 1 ? "忽略这张照片，不要保存。" : "保存"
    let second = AgentInput(id: UUID().uuidString, sessionID: session, payload: .text(ending))
    _ = try await manager.receiveLocally(second, to: .assistant)
    try await skillEventually {
        let completed = await effects.completed
        let failures = await effects.failures
        return completed == (live && run == 2 ? 3 : 2) || failures.contains { $0.hasPrefix("agent.error:") }
    }
    let finalFailures = await effects.failures
    #expect(finalFailures == failures)
    let saved = try await context.snapshot()
    #expect(saved.state.skillState?.mode == "default" && saved.state.skillState?.activeTaskID == nil)
    #expect(
        saved.state.skillState?.tasks.last?.inputIDs.first == first.id
            && saved.state.skillState?.tasks.last?.inputIDs.last == second.id)
    #expect(await effects.owners.allSatisfy { $0 == "assistant" })
    #expect(await effects.owners.count == (live && run == 2 ? 3 : (live && run == 1 ? 1 : 2)))
    if live && run == 1 { #expect(await effects.paths.contains("Camera.Capture.close")) }
    var archive = try await store.snapshot()
    if let persistentRecords {
        archive.current = try await AssistantRecordStore(
            repository: persistentRecords.assistantMessages, tasks: persistentRecords.assistantTasks,
            conversations: persistentRecords.assistantConversations, logs: persistentRecords.logs
        )
        .read(archive.current.id)
    }
    let requests = try #require(archive.current.turns.first?.modelRequests)
    let rounds = try #require(archive.current.turns.first?.generationRounds)
    #expect(rounds[rejectFirst ? 1 : 0].resultsJSON.contains("Agent.Task.startTask"))
    #expect(rounds.first?.resultsJSON.contains("\"protocol\":\"action\"") == true)
    #expect(rounds.contains { $0.resultsJSON.contains("Camera.Capture.takePhoto") })
    if live {
        let query = AgentInput(
            id: UUID().uuidString, sessionID: session, payload: .text("只列出最近的对话标题，不要读取详情，不需要创建任务。"))
        _ = try await manager.receiveLocally(query, to: .assistant)
        try await skillEventually {
            let completed = await effects.completed
            return completed == (run == 2 ? 4 : 3)
        }
        let queried = try await store.snapshot()
        let queryRequests = try #require(queried.current.turns.last?.modelRequests)
        #expect(queryRequests.contains { $0.response.contains("<loadSkills") })
        #expect(
            queryRequests.contains { $0.response.contains("<History.list") && $0.state == .completed })
        #expect(try await context.snapshot().state.skillState?.loaded.contains("history-query") == true)
        #expect(await effects.failures == [])
        #expect(requests.contains { $0.response.contains("<task.start") })
        #expect(requests.contains { $0.decisionMetadata?.skills["photography"] != nil })
        if run == 0 {
            for (offset, command) in ["机械臂点一次头，不用说话。", "先说你好，再挥手一次。", "关闭摄像头。"].enumerated() {
                if offset == 2 {
                    publicOwner.camera.update { $0 = FixtureCameraFact(enabled: true, running: true) }
                }
                _ = try await manager.receiveLocally(
                    AgentInput(id: UUID().uuidString, sessionID: session, payload: .text(command)),
                    to: .assistant)
                try await skillEventually {
                    let completed = await effects.completed
                    let failures = await effects.failures
                    return completed == 4 + offset || failures.contains { $0.hasPrefix("agent.error:") }
                }
            }
            let paths = await effects.paths
            let commandFailures = await effects.failures
            let diagnostic = try await store.snapshot()
            try JSONEncoder().encode(diagnostic.current).write(
                to: URL(fileURLWithPath: "/tmp/mh-compaction-commands-\(cameraFacts ? "facts" : "query").json"),
                options: .atomic)
            if !commandFailures.isEmpty { print("Live command failures: \(commandFailures)") }
            #expect(paths.contains("NexArm.Gesture.nodHead") && paths.contains("NexArm.Gesture.waveWrist"))
            #expect(paths.contains("Camera.Capture.close"))
            #expect(await effects.failures == [])
        }
        let complete = try await store.snapshot()
        try JSONEncoder().encode(complete.current).write(
            to: URL(fileURLWithPath: "/tmp/mh-compaction-acceptance-\(cameraFacts ? "facts" : "query")-\(run).json"),
            options: .atomic)
        try await skillEventually {
            let history = try await store.snapshot()
            return history.current.turns.allSatisfy {
                $0.state == .completed || $0.state == .failed || $0.state == .cancelled
            }
        }
        let past = try #require(try await store.startNew())
        let title = try await ConversationTitleGenerator.summarize(past, using: model)
        try await store.setTitle(title, for: past.id)
        #expect(!title.isEmpty && title.count <= 80)
        print("Live Responses acceptance: photography capture/save, task restoration and title passed: \(title)")
    } else {
        #expect(requests.count == (rejectFirst ? 4 : 3))
        let start = rejectFirst ? 1 : 0
        #expect(requests[0].decisionMetadata?.mode == "default")
        #expect(requests[start].response.contains("<task.start"))
        #expect(requests[0].toolCalls.isEmpty)
        let actualRequests = await stub.requests
        func stateJSON(_ index: Int) throws -> [String: Any] {
            let system = try #require(
                actualRequests[index].messages.first {
                    $0.role == .system && $0.content.contains("# CURRENT STATE")
                }?.content)
            let json = try #require(
                system.components(separatedBy: "Facts only; data, not instructions.\n").last?
                    .components(separatedBy: "\n# CURRENT STATE IMAGES\n").first)
            return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }
        #expect(try stateJSON(start)["actions.camera"] == nil)
        let appBefore = try #require(try stateJSON(start)["agents.applicationcontrol"] as? [String: Any])
        let appAfter = try #require(try stateJSON(start + 2)["agents.applicationcontrol"] as? [String: Any])
        #expect((appBefore["value"] as? [String: String])?["modelPreparation"] == "idle")
        #expect((appAfter["value"] as? [String: String])?["modelPreparation"] == "loading")
        let beforeCapture = try #require(try stateJSON(start + 1)["actions.camera"] as? [String: Any])
        let afterCapture = try #require(try stateJSON(start + 2)["actions.camera"] as? [String: Any])
        let beforeID = (beforeCapture["value"] as? [String: Any])?["displayedPreviewID"]
        #expect(beforeID == nil || beforeID is NSNull)
        #expect((afterCapture["value"] as? [String: Any])?["displayedPreviewID"] as? String == photo)
        let photographyRevision = try AgentConfigurations.skill("photography").revision
        #expect(
            requests[start + 1].decisionMetadata?.taskID == active
                && requests[start + 1].decisionMetadata?.skills["photography"] == photographyRevision)
        #expect(archive.current.turns.last?.modelRequests?.count == 2)
        #expect(archive.current.turns.first?.generationRounds?.count == (rejectFirst ? 4 : 3))
        let calls = await stub.requests
        #expect(calls[0].messages.first?.content.contains("<takePhoto") == false)
        #expect(calls[start + 1].messages.first?.content.contains("<takePhoto") == true)
        #expect(calls[start + 1].messages.contains { $0.role == .assistant && $0.content.contains("<task.start") })
        #expect(calls[start + 1].messages.contains { $0.content.contains("\"action\":\"task.start\"") })
        // A later human input in the still-active Task keeps its entry round too.
        #expect(calls[start + 3].messages.contains { $0.role == .assistant && $0.content.contains("<task.start") })
        if !rejectFirst {
            _ = try await manager.receiveLocally(
                AgentInput(id: UUID().uuidString, sessionID: session, payload: .text("再拍一张")), to: .assistant
            )
            try await skillEventually { await effects.completed == 3 }
            let restarted = try await context.snapshot().state.skillState
            #expect(restarted?.activeTaskID != nil && restarted?.activeTaskID != active)
            #expect(restarted?.tasks.count == 2 && restarted?.tasks.last?.status == "waitingUser")
            #expect(await effects.failures.isEmpty)
            var history = try await store.snapshot()
            if let persistentRecords {
                history.current = try await AssistantRecordStore(
                    repository: persistentRecords.assistantMessages, tasks: persistentRecords.assistantTasks,
                    conversations: persistentRecords.assistantConversations, logs: persistentRecords.logs
                )
                .read(history.current.id)
            }
            #expect(history.current.turns.count == 3)
            let allRequests = await stub.requests
            #expect(allRequests[5].messages.contains { $0.content.contains("Task history") })
            #expect(!allRequests[5].messages.contains { $0.role != .system && $0.content.contains(photo) })
            #expect(!allRequests[6].messages.contains { $0.role != .system && $0.content.contains(photo) })
            #expect(allRequests[6].messages.contains { $0.content.contains("Task history") })
            #expect(history.current.turns.first?.modelRequests?.count == 3)
            let photoEvidence = try #require(history.current.turns.first?.modelRequests?.last)
            #expect((photoEvidence.requestParametersJSON ?? photoEvidence.requestJSON).contains(photo))

            #expect(history.current.turns.last?.modelRequests?.first?.decisionMetadata?.mode == "default")
            #expect(
                history.current.turns.last?.modelRequests?.last?.decisionMetadata?.taskID == restarted?.activeTaskID)
        }
    }
    if let persistentRecords {
        let id = try await store.readCurrent().current.id
        let raw = try await AssistantRecordStore(
            repository: persistentRecords.assistantMessages, tasks: persistentRecords.assistantTasks,
            conversations: persistentRecords.assistantConversations, logs: persistentRecords.logs
        )
        .read(id)
        let taskRequests = raw.turns.flatMap { $0.modelRequests ?? [] }.filter { $0.response.contains("<task.start") }
        #expect(taskRequests.count == 2)
        #expect(taskRequests.allSatisfy { $0.historyTaskID != nil && $0.state == .completed })
        #expect(try await persistentRecords.assistantConversations.dialog(id).count == 3)
    }
    await agent.stop()
    _ = try await pump.value
    await gateway.shutdown()
    await manager.stopAll()
    if let persistentRecords { try await persistentRecords.shutdown() }
}

@Test(.actionCatalog) func cancelledTaskRejectsLateASRInsteadOfCapturingNewTask() async throws {
    let fixedCapabilities = try AssistantAgent.runtimeCapabilities(
        AgentConfigurations.load(named: "Assistant").capabilities)
    var initial = AssistantContextState()
    var skills = AgentTaskSkillState()
    try skills.initialize(fixed: fixedCapabilities, baseSkills: try AgentConfigurations.baseSkills(named: "Assistant"))
    _ = try skills.control(
        "task.start", arguments: ["skills": "[\"photography\"]", "description": "original"],
        inputID: UUID().uuidString,
        fixed: fixedCapabilities, taskID: try fixtureTaskID())
    initial.skillState = skills
    let context = try AgentContextRepository(
        agent: AgentID.assistant, scope: UUID().uuidString, state: initial
    )
    let model = SkillModel(mediaID: "preview_1")
    let agent = try AssistantAgent(stateContext: try publicStateFixture(), chat: model, context: context)
    try await agent.start()
    let session = UUID().uuidString
    let turn = AgentTurn(id: UUID().uuidString, ordinal: 1)
    try await agent.receive(
        .init(
            id: UUID().uuidString, sessionID: session, payload: .observation(.speechPhase(.speaking)),
            turn: turn))
    try await context.update {
        var state = try #require($0.state.skillState)
        _ = try state.control(
            "task.cancel", arguments: ["reason": "cancelled"], inputID: UUID().uuidString,
            fixed: fixedCapabilities)
        try state.decisionCompleted(failed: false, fixed: fixedCapabilities)
        _ = try state.control(
            "task.start", arguments: ["skills": "[\"history-query\"]", "description": "new task"],
            inputID: UUID().uuidString,
            fixed: fixedCapabilities, taskID: try fixtureTaskID())
        $0.state.skillState = state
    }
    let current = try await context.snapshot().state.skillState?.activeTaskID
    await #expect(throws: CommunicationError.scopeClosed) {
        try await agent.receive(
            .init(
                id: UUID().uuidString, sessionID: session,
                payload: .observation(.transcript("保存", final: true)), turn: turn))
    }
    #expect(try await context.snapshot().state.skillState?.activeTaskID == current)
    #expect(await model.requests.count == 0)
    await agent.stop()
}

@Test(.actionCatalog) func failedSkillPersistenceLeavesCommittedModeAndCatalogUnchanged() async throws {
    struct WriteFailure: Error {}
    let fixedCapabilities = try AssistantAgent.runtimeCapabilities(
        AgentConfigurations.load(named: "Assistant").capabilities)
    var initial = AssistantContextState()
    var skills = AgentTaskSkillState()
    try skills.initialize(fixed: fixedCapabilities, baseSkills: try AgentConfigurations.baseSkills(named: "Assistant"))
    initial.skillState = skills
    let repository = try AgentContextRepository(
        agent: AgentID.assistant, scope: UUID().uuidString, state: initial,
        persistence: AgentContextPersistence(load: { nil }, commit: { _, _ in throw WriteFailure() })
    )
    await #expect(throws: WriteFailure.self) {
        try await repository.transaction {
            try $0.state.skillState?.control(
                "task.start", arguments: ["skills": "[\"photography\"]", "description": "fixture"],
                inputID: UUID().uuidString,
                fixed: fixedCapabilities, taskID: try fixtureTaskID())
        }
    }
    let committed = try await repository.snapshot().state.skillState
    #expect(committed?.mode == "default" && committed?.activeTaskID == nil)
    #expect(try committed?.registry(fixed: fixedCapabilities).actions.contains { $0.path.domain == "Camera" } == false)
}

@Test(.actionCatalog) func trustedIdleControlsReuseTaskActionsWithoutStartingConversation() async throws {
    let context = try AgentContextRepository(
        agent: AgentID.assistant, scope: UUID().uuidString, state: AssistantContextState()
    )
    let model = SkillModel(mediaID: "preview_1")
    let agent = try AssistantAgent(stateContext: try publicStateFixture(), chat: model, context: context)
    try await agent.start()
    let session = UUID().uuidString
    _ = try await agent.controlTask(
        "task.start", arguments: ["skills": "[\"photography\"]", "description": "fixed fixture"], source: "assistant",
        sessionID: session, inputID: UUID().uuidString, decisionID: nil)
    #expect(try await context.snapshot().state.skillState?.mode == "task")
    await #expect(throws: CommunicationError.unauthorized) {
        try await agent.controlTask(
            "task.cancel", arguments: ["reason": "spoofed"], source: "photographer", sessionID: session,
            inputID: UUID().uuidString,
            decisionID: nil)
    }
    _ = try await agent.controlTask(
        "task.cancel", arguments: ["reason": "fixed cancelled"], source: "assistant", sessionID: session,
        inputID: UUID().uuidString, decisionID: nil)
    #expect(try await context.snapshot().state.skillState?.tasks.last?.status == "cancelled")
    #expect(try await context.snapshot().state.skillState?.mode == "default")
    #expect(await model.requests.isEmpty)
    await agent.stop()
}

@Test(.actionCatalog) func taskOwnsRequestedSkillsAndReleasesThemAtClosure() throws {
    let fixed = try AssistantAgent.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities)
    var state = AgentTaskSkillState()
    try state.initialize(fixed: fixed, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    let input = UUID().uuidString
    try state.beginDecision(input)
    _ = try state.control(
        "loadSkills", arguments: ["skills": "[\"history-query\",\"photography\"]"], inputID: input, fixed: fixed)
    try state.decisionCompleted(failed: false, fixed: fixed, inputID: input)
    #expect(try state.ownership("photography") == "recent")
    let taskInput = UUID().uuidString
    try state.beginDecision(taskInput)
    _ = try state.control(
        "task.start", arguments: ["description": "拍照", "skills": "[\"photography\"]"], inputID: taskInput, fixed: fixed,
        taskID: try fixtureTaskID())
    #expect(try state.ownership("photography") == "task")
    #expect(try state.ownership("history-query") == "recent")
    #expect(state.tasks.last?.skills.contains("history-query") == false)
    _ = try state.control("task.end", arguments: ["summary": "完成"], inputID: taskInput, fixed: fixed)
    try state.settleTask(failed: false, fixed: fixed)
    #expect(!state.loaded.contains("photography") && state.loaded.contains("history-query"))
    try state.decisionCompleted(failed: false, fixed: fixed, inputID: taskInput)
    #expect(state.recentSkills["history-query"]?.remainingDecisions == 5)
}

@Test(.actionCatalog) func genericBackgroundCapacityAndInvalidVersionsAreExplicit() throws {
    var registry = AgentTaskRegistry()
    let session = UUID().uuidString
    for _ in 0..<16 {
        try registry.register(
            AgentTaskScope(
                id: UUID().uuidString, requester: .assistant, executor: .memory, sessionID: session,
                execution: .background))
    }
    #expect(throws: CommunicationError.capacityExceeded) {
        try registry.register(
            AgentTaskScope(
                id: UUID().uuidString, requester: .assistant, executor: .memory, sessionID: session,
                execution: .background))
    }
    let cancelling = try #require(registry.records.first?.scope.id)
    try registry.delivered(cancelling, kind: .cancel, accepted: false)
    #expect(registry.task(cancelling)?.state == .requested)
    try registry.delivered(cancelling, kind: .cancel, accepted: true)
    #expect(registry.task(cancelling)?.state == .cancelling)
    registry.recover()
    #expect(registry.records.allSatisfy { $0.state == .interrupted })
    try registry.register(
        AgentTaskScope(
            id: UUID().uuidString, requester: .assistant, executor: .memory, sessionID: session,
            execution: .background))
    #expect(throws: CommunicationError.unsupportedContract) {
        try AgentConfigurations.backgroundSupport(target: .memory, contract: "demo.background", skills: [])
    }
    var old = AgentTaskSkillState()
    old.version = 1
    let fixedCapabilities = try AssistantAgent.runtimeCapabilities(
        AgentConfigurations.load(named: "Assistant").capabilities)
    #expect(throws: CommunicationError.invalidPayload) {
        try old.initialize(fixed: fixedCapabilities, baseSkills: try AgentConfigurations.baseSkills(named: "Assistant"))
    }
    #expect(old.version == 1)
    let legacyScope: [String: Any] = [
        "id": UUID().uuidString, "requester": "assistant", "executor": "memory",
        "sessionID": session,
    ]
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(AgentTaskScope.self, from: JSONSerialization.data(withJSONObject: legacyScope))
    }
    #expect(throws: CommunicationError.invalidPayload) {
        try AgentBackgroundTaskRequest(arguments: ["goal": "后台", "execution": "background"])
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func legacyBackgroundStartIsRejectedWithoutChangingForegroundOrInvokingChat()
    async throws
{
    let database = try SQLiteRepositories.temporary()
    let history = AssistantHistoryStore(
        records: try AssistantRecordStore(
            repository: database.assistantMessages, tasks: database.assistantTasks,
            conversations: database.assistantConversations, logs: database.logs))
    let session = UUID().uuidString
    let context = try AgentContextRepository(
        agent: AgentID.assistant, scope: UUID().uuidString, state: AssistantContextState()
    )
    let model = SkillModel(mediaID: "preview_1")
    let assistant = try AssistantAgent(
        stateContext: try publicStateFixture(),
        chat: model, conversations: history, communications: database.agentMessages, context: context,
        backgroundSupport: { target, contract, skills in
            guard target == .memory, contract == "demo.background", skills.isEmpty else {
                throw CommunicationError.unsupportedContract
            }
        })
    let child = ObservationRecorder(id: "memory", tasks: database.writerExecutions)
    let configurations = try AgentConfigurations.all()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, configurations: configurations)
    let manager = AgentManager()
    try await manager.register(assistant, sessionID: session)
    try await manager.register(child, sessionID: session)
    let input = InputGateway(manager: manager, policy: policy)
    let output = await OutputGateway(
        manager: manager, requests: input, tools: ToolRegistry(), policy: policy, sink: { _ in })
    try bindFixtureCommunications(assistant, port: await output.messaging(for: .assistant))
    try await assistant.start()
    await child.start()
    _ = try await assistant.controlTask(
        "task.start", arguments: ["description": "继续拍摄", "skills": "[\"photography\"]"], source: "assistant",
        sessionID: session, inputID: UUID().uuidString, decisionID: nil)
    let before = try await context.snapshot().state.skillState
    await #expect(throws: CommunicationError.invalidPayload) {
        try await assistant.controlTask(
            "task.start", arguments: ["description": "obsolete", "execution": "background", "executor": "memory"],
            source: "assistant", sessionID: session, inputID: UUID().uuidString, decisionID: nil)
    }
    #expect(try await context.snapshot().state.skillState?.activeTaskID == before?.activeTaskID)
    #expect(try await context.snapshot().state.skillState?.loaded == before?.loaded)
    #expect(await child.inputs.isEmpty)
    #expect(await model.requests.isEmpty)
    await assistant.stop()
    await child.stop()
    await output.shutdown()
    try await database.shutdown()
}

@Test(.actionCatalog) func agentCatalogLookupUsesBundleResourceSemantics() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    for layout in ["flat", "Resources"] {
        let bundleURL = directory.appendingPathComponent("\(layout).bundle")
        let root = layout == "flat" ? bundleURL : bundleURL.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = root.appendingPathComponent("Catalog.json")
        try Data("{}".utf8).write(to: catalog)
        let bundle = try #require(Bundle(url: bundleURL))
        #expect(try AgentConfigurations.resourceRoot(in: bundle).standardizedFileURL == root.standardizedFileURL)
        #expect(
            try Data(contentsOf: AgentConfigurations.resourceRoot(in: bundle).appendingPathComponent("Catalog.json"))
                == Data("{}".utf8))
    }
    let missing = directory.appendingPathComponent("missing.bundle")
    try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
    #expect(throws: AgentConfigurationError.self) {
        try AgentConfigurations.resourceRoot(in: #require(Bundle(url: missing)))
    }
}

private struct TaskControlAcknowledgmentFixture: TaskControlCapability {
    func controlTask(_ operation: String, arguments: [String: String], invocation: any FunctionInput) async throws
        -> String
    {
        "Committed \(operation)"
    }
}

@Test(.actionCatalog) func everyTaskControlCompletionIsAcceptedByCanonicalExecutor() async throws {
    let module = TaskControlModule(capability: TaskControlAcknowledgmentFixture())
    for function in module.definitions {
        let invocation = ActionInvocation(
            call: .init(
                actionPath: function.path, channel: "Control",
                parameters: [
                    "loadSkills": ["skills": "[]"], "releaseSkills": ["skills": "[]"],
                    "startTask": ["description": "fixture"],
                    "finishTask": ["summary": "fixture"], "cancelTask": ["reason": "fixture"],
                    "sendMessage": ["agent_id": "writer", "text": "answer"],
                    "delegateTask": ["agent_id": "writer", "description": "draw"],
                ][function.path.function] ?? [:]),
            context: .init(
                source: "assistant", sessionID: UUID().uuidString, inputID: UUID().uuidString,
                sequence: 0), executionID: UUID().uuidString)
        #expect(
            try await FunctionExecutor.perform(invocation, definition: function)
                == .value(
                    "Committed \(["startTask":"task.start","finishTask":"task.end","cancelTask":"task.cancel","sendMessage":"task.send","delegateTask":"task.delegate"][function.path.function] ?? function.path.function)"
                ))
    }
}

@Test(.actionCatalog) func baseSkillsAreTheOnlyRoleModelFunctionSource() throws {
    for name in [
        "Assistant", "Photographer", "Memory", "ApplicationControl", "SpeechPerception", "SpeechSynthesis",
        "VisionPerception",
    ] {
        let configuration = try AgentConfigurations.load(named: name)
        let ids = try AgentSkillLoader.expand(AgentConfigurations.baseSkills(named: name))
        let composed = try AgentSkillLoader.registry(ids, fixed: CapabilityRegistry())
        #expect(composed.actions.map(\.path) == configuration.capabilities.actions.map(\.path))
        #expect(composed.tools.map(\.path) == configuration.capabilities.tools.map(\.path))
    }
    let assistant = try AgentConfigurations.load(named: "Assistant")
    let expression = try AgentSkillLoader.registry(["expression-interaction"], fixed: assistant.capabilities)
    #expect(expression.tools.isEmpty)
    #expect(expression.actions.count == 2)
    #expect(!expression.actions.contains { $0.alias == "send" || $0.alias == "readEnvironment" })
    let unregistered = try AgentCommunicationAdapter.catalog(expression, policy: assistant.communication)
    #expect(!unregistered.actions.contains { $0.alias == "send" })
    let basic = try AgentSkillLoader.registry(["basic-skill"], fixed: CapabilityRegistry())
    #expect(basic.tools.isEmpty)
    #expect(basic.actions.contains { $0.alias == "task.start" })
    #expect(!basic.actions.contains { $0.alias == "send" })
    #expect(!basic.actions.contains { $0.alias == "readEnvironment" })
    let identity = try AgentConfigurations.identityInstructions(named: "Assistant")
    #expect(!identity.contains("task.start") && !identity.contains("task.delegate"))
    #expect(!identity.contains("<task.start") && !identity.contains("<loadSkills"))
}

@Test(.actionCatalog) func assistantRobotSkillIsDiscoverableButRequiresExplicitLoading() throws {
    let configuration = try AgentConfigurations.load(named: "Assistant")
    let fixed = try AssistantAgent.runtimeCapabilities(configuration.capabilities)
    let base = try AgentConfigurations.baseSkills(named: "Assistant")
    #expect(Set(base) == ["basic-skill", "expression-interaction"])
    var state = AgentTaskSkillState()
    try state.initialize(fixed: fixed, baseSkills: base)
    let before = try state.registry(fixed: fixed)
    #expect(!before.actions.contains { $0.path.domain == "NexArm" })
    #expect(!((try AgentSkillLoader.useStates(state.loaded)).contains("actions.robot")))
    let prompt = try AssistantContextState.systemPrompt(before, skills: state)
    #expect(prompt.contains("robot-interaction") && !prompt.contains("Action nodHead:"))
    #expect(!prompt.contains(try AgentConfigurations.skillInstructions("robot-interaction")))
    #expect(throws: GenerationError.unknownCapability) {
        try before.resolveAction("nodHead", parameters: ["cycles": "1"])
    }
    _ = try state.control(
        "loadSkills", arguments: ["skills": "[\"robot-interaction\"]"],
        inputID: "load", fixed: fixed)
    #expect(state.activeTaskID == nil)
    let loaded = try state.registry(fixed: fixed)
    #expect(try loaded.resolveAction("nodHead", parameters: ["cycles": "1"]).channel == "Robot")
    #expect(try AgentSkillLoader.useStates(state.loaded).contains("actions.robot"))
    #expect(try AgentSkillLoader.useStates(state.loaded).contains("actions.robot.motion"))
    #expect(!before.actions.contains { $0.path.domain == "NexArm" })
    _ = try state.control(
        "releaseSkills", arguments: ["skills": "[\"robot-interaction\"]"],
        inputID: "release", fixed: fixed)
    #expect(!state.loaded.contains("robot-interaction"))
    #expect(!((try state.registry(fixed: fixed)).actions.contains { $0.path.domain == "NexArm" }))
    #expect(!((try AgentSkillLoader.useStates(state.loaded)).contains("actions.robot.motion")))
}

@Test(.actionCatalog) func foregroundTaskRejectsBackgroundFieldsWithoutChangingState() throws {
    let fixed = try AssistantAgent.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities)
    var state = AgentTaskSkillState()
    try state.initialize(fixed: fixed, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let before = try encoder.encode(state)
    #expect(throws: CommunicationError.invalidPayload) {
        try state.control(
            "task.start",
            arguments: [
                "description": "拍照", "skills": "[\"photography\"]",
                "target": "photographer", "businessContract": "photography", "payload": "{}",
            ], inputID: UUID().uuidString, fixed: fixed, taskID: try fixtureTaskID())
    }
    #expect(try encoder.encode(state) == before)
    _ = try state.control(
        "task.start", arguments: ["description": "拍照", "skills": "[\"photography\"]"],
        inputID: UUID().uuidString, fixed: fixed, taskID: try fixtureTaskID())
    #expect(state.activeTaskID != nil && state.loaded.contains("photography"))
}

@Test(.actionCatalog) func unstartedAssistantRejectsInputWithoutEmittingRuntimeError() async throws {
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(),
        chat: SkillModel(mediaID: "preview_1"),
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "assistant"), scope: UUID().uuidString, state: AssistantContextState())
    )
    await #expect(throws: HarnessError.notRunning) {
        try await agent.receive(
            AgentInput(
                id: UUID().uuidString, sessionID: UUID().uuidString,
                payload: .text("startup input")))
    }
    await agent.stop()
    for await output in agent.outputs {
        if case .control(let text) = output.output { #expect(!text.hasPrefix("agent.error:")) }
    }
}

@Test(.actionCatalog) func taskFailureRetainsActualCauseAndTransitionTime() throws {
    let fixed = try AssistantAgent.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities)
    var state = AgentTaskSkillState()
    try state.initialize(fixed: fixed, baseSkills: try AgentConfigurations.baseSkills(named: "Assistant"))
    let input = UUID().uuidString
    _ = try state.control(
        "task.start", arguments: ["description": "拍照", "skills": "[\"photography\"]"], inputID: input, fixed: fixed,
        taskID: try fixtureTaskID())
    let before = Date()
    try state.decisionCompleted(failed: true, fixed: fixed, inputID: input, failure: "Capture denied by device")
    let saved = try JSONDecoder().decode(AgentTaskSkillState.self, from: JSONEncoder().encode(state))
    let task = try #require(saved.tasks.last)
    #expect(task.status == "failed" && task.failure == "Capture denied by device")
    #expect(try #require(task.updatedAt) >= before)
    #expect(saved.activeTaskID == nil && !saved.loaded.contains("photography"))
}

@Test(.actionCatalog) func applicationOperationsAndQueriesUseActions() throws {
    let registry = try AgentSkillLoader.registry(
        AgentConfigurations.baseSkills(named: "Assistant") + ["application-control"], fixed: CapabilityRegistry())
    let commands: [(String, String, [String: String])] = [
        ("Bluetooth.control", "System.Device.control", ["operation": "scan"]),
        (
            "ModelResources.download", "System.ModelResources.download",
            ["id": "fixture", "endpoint": "https://example.test/model", "allowsCellular": "false"]
        ),
        ("ModelResources.cancel", "System.ModelResources.cancel", ["id": "fixture"]),
    ]
    for (alias, path, arguments) in commands {
        let call = try registry.resolveAction(alias, parameters: arguments)
        #expect(call.actionPath.description == path && call.channel == "System")
        #expect(throws: GenerationError.unknownCapability) { try registry.resolveTool(alias, arguments: arguments) }
        var parser = FunctionTokenParser()
        let attributes = arguments.sorted { $0.key < $1.key }.map { "\($0.key)=\"\($0.value)\"" }.joined(separator: " ")
        let tokens = try parser.append("<\(alias) \(attributes)/>") + parser.finish()
        #expect(tokens.count == 1)
        guard case .action(let parsedAlias, let parameters) = tokens[0] else {
            Issue.record("Expected a parsed Action")
            continue
        }
        #expect(
            try registry.resolveAction(parsedAlias, parameters: parameters).actionPath.description
                == path)
    }
    for alias in ["ModelResources.snapshot", "Provider.readSettings", "Bluetooth.readStatus"] {
        #expect(try registry.resolveAction(alias, parameters: [:]).channel == "Query")
        #expect(throws: GenerationError.unknownCapability) { try registry.resolveTool(alias, arguments: [:]) }
    }
    #expect(!registry.actions.contains { $0.path.domain == "NexArm" })
    #expect(Set(registry.actions.map(\.path)).count == registry.actions.count)
}

@Test(.actionCatalog) func registeredCameraCallsDoNotRequireTaskOrPhotoOwner() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    var skills = AgentTaskSkillState()
    try skills.initialize(fixed: config.capabilities, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("拍张照，不要后续操作"))
    #expect(throws: GenerationError.unknownCapability) {
        try skills.registry(fixed: config.capabilities).resolveAction("takePhoto", parameters: [:])
    }
    _ = try skills.control(
        "loadSkills", arguments: ["skills": "[\"photography\"]"], inputID: input.id, fixed: config.capabilities)
    let registry = try skills.registry(fixed: config.capabilities)
    let photo = "preview_1"
    for (alias, parameters) in [
        ("takePhoto", [:]), ("savePhoto", ["previewID": photo]),
    ] {
        let call = try registry.resolveAction(alias, parameters: parameters)
        #expect(call.channel == "Camera")
    }
    #expect(skills.activeTaskID == nil)
    #expect(try AgentSkillLoader.useStates(skills.loaded).contains("actions.camera"))
    #expect(try AgentSkillLoader.useStates(skills.loaded).contains("ui.navigation"))
}

@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: [false, true])
func assistantCapturesWithoutTaskWhenNoFollowUpIsRequested(supportsImages: Bool) async throws {
    try await photographyAcceptance(live: false, captureOnly: true, supportsImages: supportsImages)
}

@Test(.actionCatalog) func explicitTaskReplacementContinuesOnlyAfterClosedState() async throws {
    try await photographyAcceptance(live: false, replaceForeground: true)
}

@Test(.actionCatalog) func taskClosureContinuationIsOptInAndValidated() throws {
    let fixed = try AssistantAgent.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities)
    var state = AgentTaskSkillState()
    try state.initialize(fixed: fixed, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    let input = UUID().uuidString
    _ = try state.control(
        "task.start", arguments: ["description": "fixture"], inputID: input, fixed: fixed, taskID: try fixtureTaskID())
    #expect(throws: CommunicationError.invalidPayload) {
        try state.control(
            "task.end", arguments: ["summary": "done", "continueDecision": "yes"], inputID: input, fixed: fixed)
    }
    #expect(state.tasks.last?.status == "running")
    _ = try state.control("task.end", arguments: ["summary": "done"], inputID: input, fixed: fixed)
    #expect(state.tasks.last?.continueDecision == false)
}

@Test(.actionCatalog) func bundledSkillsKeepPresentationAndDeviceProceduresSeparate() throws {
    let expression = try AgentConfigurations.skill("expression-interaction")
    #expect(Set(expression.useActions.map(\.path)) == ["UI.Expression.express", "UI.Expression.setExpression"])
    let application = try AgentConfigurations.skill("application-control")
    #expect(application.useActions.count == 18 && !application.useActions.contains { $0.path.hasPrefix("NexArm.") })
    let robot = try AgentConfigurations.skill("robot-interaction")
    #expect(robot.useActions.count == 11 && robot.useActions.allSatisfy { $0.path.hasPrefix("NexArm.") })
    for registry in try AgentConfigurations.skillRegistries() {
        #expect(!registry.actions.contains { $0.path.description.hasPrefix("UI.Feedback.") })
        #expect(!registry.actions.contains { $0.path.description == "Agent.Communication.send" })
    }
    let base = try AgentConfigurations.load(named: "Assistant").capabilities
    #expect(throws: GenerationError.unknownCapability) { try base.resolveAction("vibrate", parameters: [:]) }
    #expect(throws: GenerationError.unknownCapability) {
        try base.resolveAction("updateLight", parameters: ["enabled": "true"])
    }
    #expect(throws: GenerationError.unknownCapability) {
        try base.resolveAction("send", parameters: ["target": "memory", "kind": "request", "content": "x"])
    }
    #expect(!base.actions.contains { $0.alias == "nodHead" })
}

@Test(.actionCatalog, arguments: [false, true])
func taskEntryRetainsConversationAndNativePairsUntilClosure(replacingWithinInput: Bool) async throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    var skills = AgentTaskSkillState()
    try skills.initialize(fixed: config.capabilities, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    let ordinaryID = UUID().uuidString
    let oldInputID = UUID().uuidString
    let newInputID = replacingWithinInput ? oldInputID : UUID().uuidString
    _ = try skills.control(
        "task.start", arguments: ["description": "旧拍照目标"], inputID: oldInputID, fixed: config.capabilities,
        taskID: try fixtureTaskID())
    let oldTaskID = try #require(skills.activeTaskID)
    _ = try skills.control(
        "task.end", arguments: ["summary": "旧照片已保存"], inputID: oldInputID, fixed: config.capabilities)
    try skills.decisionCompleted(failed: false, fixed: config.capabilities)
    _ = try skills.control(
        "task.start", arguments: ["description": "后置拍照"], inputID: newInputID, fixed: config.capabilities,
        taskID: try fixtureTaskID())
    let newTaskID = try #require(skills.activeTaskID)
    let store = AssistantHistoryStore()
    func record(_ inputID: String, requests: [(String?, String)], nativePair: Bool = false) async throws {
        let current = try await store.readCurrent()
        _ = try await store.begin(
            id: inputID, user: "fixture input",
            request: [.init(role: .system, content: "fixture"), .init(role: .user, content: "fixture input")],
            expecting: current.token, model: "stub")
        for (taskID, output) in requests {
            let request = AssistantModelRequest(
                id: UUID().uuidString, input: "fixture input", requestJSON: "[]",
                decisionMetadata: .init(
                    taskID: taskID, mode: taskID == nil ? "default" : "task", skills: [:], catalogJSON: "{}"),
                historyTaskID: taskID
                    ?? (output == "OLD_ENTRY" ? oldTaskID : (output.hasPrefix("<task.start") ? newTaskID : nil)))
            try await store.beginModelRequest(request, for: inputID)
            try await store.append(output, to: inputID)
            if nativePair {
                let call = ModelToolCall(
                    id: UUID().uuidString, providerID: "background-query", name: "History.list",
                    argumentsJSON: "{}")
                try await store.recordToolCall(call, for: inputID)
                try await store.recordToolOutcome(call.id, for: inputID, state: .completed, output: "用户偏好红帽子")
            }
            try await store.finishModelRequest(inputID, reason: "stop")
        }
        try await store.finish(inputID, state: .completed)
    }
    try await record(ordinaryID, requests: [(nil, "普通对话背景")], nativePair: true)
    let oldRequests: [(String?, String)] = [(nil, "OLD_ENTRY"), (oldTaskID, "OLD_PHOTO_RAW")]
    let newRequests: [(String?, String)] = [
        (nil, "<task.start description=\"后置拍照\"/>"), (newTaskID, "CURRENT_TASK_RAW"),
    ]
    if replacingWithinInput {
        try await record(oldInputID, requests: oldRequests + newRequests)
    } else {
        try await record(oldInputID, requests: oldRequests)
        try await record(newInputID, requests: newRequests)
    }
    var state = AssistantContextState()
    state.skillState = skills
    state.history = try await store.snapshot()
    state.reconcileTaskCompressions()
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let originalHistory = try encoder.encode(state.history.current.turns)
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("保存当前照片"))
    func projected(_ value: AssistantContextState) throws -> [ChatMessage] {
        let snapshot = AgentContext(agentID: .assistant, scopeID: UUID().uuidString, state: value)
        let decision = AgentDecisionContext(snapshot: snapshot, input: input)
        return try AgentChatRequestBuilder<AssistantContextState>().build(state: decision, batch: decision.batch())
            .messages(system: "fixture", user: "保存当前照片")
    }
    let active = try projected(state)
    #expect(active.contains { $0.role == .assistant && $0.content == "普通对话背景" })
    #expect(active.contains { $0.role == .assistant && $0.content.hasPrefix("<task.start") })
    #expect(active.contains { $0.content == "CURRENT_TASK_RAW" })
    #expect(!active.contains { $0.content.contains("OLD_ENTRY") || $0.content.contains("OLD_PHOTO_RAW") })
    #expect(active.contains { $0.content.contains("Task history") && $0.content.contains("旧照片已保存") })
    let paired = try #require(active.firstIndex { !$0.toolCalls.isEmpty })
    #expect(active[paired].toolCalls.first?.id == "background-query")
    #expect(active[paired + 1].role == .tool && active[paired + 1].toolCallID == "background-query")
    #expect(active[paired + 1].content == "用户偏好红帽子")
    _ = try skills.control(
        "task.end", arguments: ["summary": "新照片已保存"], inputID: newInputID, fixed: config.capabilities)
    try skills.decisionCompleted(failed: false, fixed: config.capabilities)
    state.skillState = skills
    state.reconcileTaskCompressions()
    let closed = try projected(state)
    #expect(closed.contains { $0.content == "普通对话背景" })
    #expect(!closed.contains { $0.content.contains("CURRENT_TASK_RAW") || $0.content.contains("<task.start") })
    #expect(closed.contains { $0.content.contains("Task history") && $0.content.contains("新照片已保存") })
    #expect(try encoder.encode(state.history.current.turns) == originalHistory)
}

@Test(.actionCatalog) func historyTaskAssignmentRefreshesStoreAndRejectsStaleAdmission() async throws {
    let context = try AgentContextRepository(
        agent: .assistant, scope: UUID().uuidString, state: AssistantContextState()
    )
    let store = AgentChatHistoryContext.store(repository: context)
    let input = UUID().uuidString
    let request = UUID().uuidString
    let task = UUID().uuidString
    let token = try await store.readCurrent().token
    _ = try await store.begin(id: input, user: "start goal", request: [], expecting: token, model: "stub")
    try await store.beginModelRequest(
        .init(
            id: request, input: "start goal", requestJSON: "[]",
            decisionMetadata: .init(taskID: nil, mode: "default", skills: [:], catalogJSON: "{}")), for: input)
    let stale = try await store.readCurrent().token
    try await context.update { try $0.state.history.assignHistoryTask(task, inputID: input, requestID: request) }
    await #expect(throws: AssistantHistoryError.conflict) {
        _ = try await store.begin(
            id: UUID().uuidString, user: "stale", request: [], expecting: stale, model: "stub")
    }
    try await store.append("started", to: input)
    try await store.finish(input, state: .completed)
    let saved = try #require(try await store.snapshot().current.turns.first?.modelRequests?.first)
    #expect(saved.historyTaskID == task && saved.decisionMetadata?.taskID == nil)
    #expect(saved.decisionMetadata?.mode == "default" && saved.response == "started")
    #expect(try await context.snapshot().state.history.current.turns.first?.modelRequests?.first?.historyTaskID == task)
}

@Test(.actionCatalog, arguments: ["completed", "failed", "cancelled", "interrupted"])
func terminalTaskCompressionKeepsChronologyAndAllSourceEvidence(status: String) async throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    var skills = AgentTaskSkillState()
    try skills.initialize(fixed: config.capabilities, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    _ = try skills.control(
        "task.start", arguments: ["description": "目标"], inputID: UUID().uuidString, fixed: config.capabilities,
        taskID: try fixtureTaskID())
    let task = try #require(skills.activeTaskID)
    skills.tasks[0].status = status
    skills.tasks[0].summary = "用户选择了第一张"
    skills.tasks[0].failure = status == "failed" ? "真实执行失败" : nil
    skills.activeTaskID = nil
    let store = AssistantHistoryStore()
    func add(_ text: String, taskID: String? = nil) async throws -> String {
        let input = UUID().uuidString
        let token = try await store.readCurrent().token
        _ = try await store.begin(id: input, user: text, request: [], expecting: token, model: "stub")
        try await store.beginModelRequest(
            .init(id: UUID().uuidString, input: text, requestJSON: "[]", historyTaskID: taskID), for: input)
        try await store.append(text + " output", to: input)
        try await store.finish(input, state: .completed)
        return input
    }
    _ = try await add("聊天A")
    _ = try await add("任务入口", taskID: task)
    _ = try await add("独立对话")
    _ = try await add("任务结束", taskID: task)
    _ = try await add("聊天B")
    var state = AssistantContextState()
    state.history = try await store.snapshot()
    state.skillState = skills
    let evidenceEncoder = JSONEncoder()
    evidenceEncoder.outputFormatting = .sortedKeys
    let before = try evidenceEncoder.encode(state.history.current.turns)
    state.reconcileTaskCompressions()
    state.reconcileTaskCompressions()
    let compression = try #require(state.history.current.taskCompressions.first)
    #expect(state.history.current.taskCompressions.count == 1 && compression.sources.count == 2)
    #expect(compression.status.rawValue == status && compression.failure == skills.tasks[0].failure)
    #expect(try evidenceEncoder.encode(state.history.current.turns) == before)
    let messages = try AgentChatContextBuilder.request(
        system: "system", user: "next", conversation: state.history.current,
        templates: AgentPrompts.load(named: "Assistant"))
    let texts = messages.map(\.content)
    let summary = try #require(texts.firstIndex { $0.contains("Task history") })
    #expect(texts[summary - 1] == "聊天A output" && texts[summary + 1] == "独立对话")
    #expect(texts[summary].contains("用户选择了第一张"))
    #expect(!texts.contains("任务入口 output") && !texts.contains("任务结束 output"))
    let rawRequests = state.history.current.turns.flatMap { $0.modelRequests ?? [] }
    #expect(rawRequests.count == 5)
}

@Test(.actionCatalog) func terminalCompressionAndTaskStateRollBackTogetherOnWriteFailure() async throws {
    struct WriteFailure: Error {}
    let fixed = try AgentConfigurations.load(named: "Assistant").capabilities
    var skills = AgentTaskSkillState()
    try skills.initialize(fixed: fixed, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    let input = UUID().uuidString
    _ = try skills.control(
        "task.start", arguments: ["description": "description"], inputID: input, fixed: fixed,
        taskID: try fixtureTaskID())
    let task = try #require(skills.activeTaskID)
    _ = try skills.control("task.end", arguments: ["summary": "done"], inputID: input, fixed: fixed)
    let store = AssistantHistoryStore()
    _ = try await store.begin(id: input, user: "goal", request: [], expecting: store.readCurrent().token, model: "stub")
    try await store.beginModelRequest(
        .init(id: UUID().uuidString, input: "goal", requestJSON: "[]", historyTaskID: task), for: input)
    try await store.append("done", to: input)
    try await store.finish(input, state: .completed)
    var state = AssistantContextState()
    state.skillState = skills
    state.history = try await store.snapshot()
    let repository = try AgentContextRepository(
        agent: .assistant, scope: UUID().uuidString, state: state,
        persistence: AgentContextPersistence(load: { nil }, commit: { _, _ in throw WriteFailure() })
    )
    await #expect(throws: WriteFailure.self) {
        try await repository.update {
            try $0.state.skillState?.decisionCompleted(failed: false, fixed: fixed)
            $0.state.reconcileTaskCompressions()
        }
    }
    let retained = try await repository.snapshot().state
    #expect(retained.skillState?.activeTaskID == task && retained.skillState?.tasks.first?.status == "finishing")
    #expect(retained.history.current.taskCompressions.isEmpty)
    #expect(retained.history.current.turns.first?.raw == "done")
}

@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: ["savePhoto", "closeCamera"])
func cameraFollowUpReplansRejectedAliasAfterTemporarySkillExpires(alias: String) async throws {
    try await photographyAcceptance(live: false, captureOnly: true, followUpAlias: alias, expireBeforeFollowUp: true)
}

@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: ["savePhoto", "closeCamera"])
func cameraFollowUpReusesSkillAcrossUserDecisions(alias: String) async throws {
    try await photographyAcceptance(live: false, captureOnly: true, followUpAlias: alias)
}

private func retentionFixture() throws -> (AgentTaskSkillState, CapabilityRegistry) {
    let fixed = try AssistantAgent.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities)
    var state = AgentTaskSkillState()
    try state.initialize(fixed: fixed, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    return (state, fixed)
}

private func retainedLoad(_ skill: String, state: inout AgentTaskSkillState, fixed: CapabilityRegistry) throws {
    let id = UUID().uuidString
    try state.beginDecision(id)
    _ = try state.control("loadSkills", arguments: ["skills": "[\"\(skill)\"]"], inputID: id, fixed: fixed)
    try state.decisionCompleted(failed: false, fixed: fixed, inputID: id)
}

@Test(.actionCatalog) func skillIdleCounterSettlesOncePerCompleteUserDecision() throws {
    var (state, fixed) = try retentionFixture()
    try retainedLoad("photography", state: &state, fixed: fixed)
    let frozen = try state.registry(fixed: fixed)
    #expect(state.recentSkills["photography"]?.remainingDecisions == 5)
    let system = UUID().uuidString
    try state.beginDecision(system, countsIdle: false)
    try state.decisionCompleted(failed: false, fixed: fixed, inputID: system)
    #expect(state.recentSkills["photography"]?.remainingDecisions == 5)
    for count in 1...5 {
        let input = UUID().uuidString
        for _ in 0..<10 { try state.beginDecision(input) }  // Internal ReACT never adds a second owner.
        #expect(state.recentSkills["photography"]?.remainingDecisions == 6 - count)
        try state.decisionCompleted(failed: false, fixed: fixed, inputID: input)
        try state.decisionCompleted(failed: false, fixed: fixed, inputID: input)
        #expect(state.recentSkills["photography"]?.remainingDecisions == (count == 5 ? nil : 5 - count))
    }
    #expect(throws: GenerationError.unknownCapability) {
        try state.registry(fixed: fixed).resolveAction("closeCamera", parameters: [:])
    }
    #expect(try frozen.resolveAction("closeCamera", parameters: [:]).actionPath.description == "Camera.Capture.close")
}

@Test(.actionCatalog, arguments: ["effect", "query"])
func admittedSkillCallsRenewRetentionIncludingExecutionFailure(kind: String) throws {
    var (state, fixed) = try retentionFixture()
    let callType = "action"
    let skill = kind == "query" ? "history-query" : "photography"
    let path = kind == "query" ? "History.Conversation.list" : "Camera.Capture.close"
    try retainedLoad(skill, state: &state, fixed: fixed)
    for _ in 0..<3 {
        let id = UUID().uuidString
        try state.beginDecision(id)
        try state.decisionCompleted(failed: false, fixed: fixed, inputID: id)
    }
    #expect(state.recentSkills[skill]?.remainingDecisions == 2)
    let id = UUID().uuidString
    try state.beginDecision(id)
    try state.recordUse(path: path, callType: callType, inputID: id, snapshotSkills: state.loaded)
    try state.decisionCompleted(failed: true, fixed: fixed, inputID: id, failure: "real execution failure")
    #expect(state.recentSkills[skill]?.remainingDecisions == 5)
    let rejected = UUID().uuidString
    try state.beginDecision(rejected)
    try state.recordUse(
        path: "Unknown.Function.call", callType: callType, inputID: rejected, snapshotSkills: state.loaded)
    try state.decisionCompleted(failed: false, fixed: fixed, inputID: rejected)
    #expect(state.recentSkills[skill]?.remainingDecisions == 4)
}

@Test(.actionCatalog) func skillBudgetEvictsLeastRecentAndRollsBackWhenProtectedOrTooLarge() throws {
    var (state, fixed) = try retentionFixture()
    state.policy.maximumNonBaseSkills = 2
    try retainedLoad("history-query", state: &state, fixed: fixed)
    try retainedLoad("photography", state: &state, fixed: fixed)
    let use = UUID().uuidString
    try state.beginDecision(use)
    try state.recordUse(
        path: "History.Conversation.list", callType: "action", inputID: use, snapshotSkills: state.loaded)
    try state.decisionCompleted(failed: false, fixed: fixed, inputID: use)
    try retainedLoad("application-control", state: &state, fixed: fixed)
    #expect(!state.loaded.contains("photography") && state.loaded.contains("history-query"))
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let id = UUID().uuidString
    try state.beginDecision(id)
    try state.recordUse(
        path: "History.Conversation.list", callType: "action", inputID: id, snapshotSkills: state.loaded)
    try state.recordUse(
        path: "System.Provider.readSettings", callType: "action", inputID: id, snapshotSkills: state.loaded)
    let before = try encoder.encode(state)
    #expect(throws: CommunicationError.capacityExceeded) {
        try state.control("loadSkills", arguments: ["skills": "[\"photography\"]"], inputID: id, fixed: fixed)
    }
    #expect(try encoder.encode(state) == before)
    var (small, _) = try retentionFixture()
    small.policy.maximumNonBaseBytes = 1
    let empty = try encoder.encode(small)
    #expect(throws: CommunicationError.capacityExceeded) {
        try small.control("loadSkills", arguments: ["skills": "[\"photography\"]"], inputID: id, fixed: fixed)
    }
    #expect(try encoder.encode(small) == empty)
}

@Test(.actionCatalog) func inFlightDecisionProtectsSkillAndTaskUseAdoptsOnlyUsedRoots() throws {
    var (state, fixed) = try retentionFixture()
    try retainedLoad("photography", state: &state, fixed: fixed)
    try retainedLoad("history-query", state: &state, fixed: fixed)
    let inFlight = UUID().uuidString
    try state.beginDecision(inFlight)
    try state.recordUse(
        path: "Camera.Capture.close", callType: "action", inputID: inFlight, snapshotSkills: state.loaded)
    for _ in 0..<5 {
        let other = UUID().uuidString
        try state.beginDecision(other)
        try state.decisionCompleted(failed: false, fixed: fixed, inputID: other)
    }
    #expect(state.recentSkills["photography"]?.remainingDecisions == 5)
    #expect(!state.loaded.contains("history-query"))
    try state.decisionCompleted(failed: false, fixed: fixed, inputID: inFlight)
    let taskInput = UUID().uuidString
    try state.beginDecision(taskInput)
    _ = try state.control(
        "task.start", arguments: ["description": "关闭相机"], inputID: taskInput, fixed: fixed, taskID: try fixtureTaskID())
    #expect(try state.ownership("photography") == "recent")
    try state.recordUse(
        path: "Camera.Capture.close", callType: "action", inputID: taskInput, snapshotSkills: state.loaded)
    #expect(try state.ownership("photography") == "task")
    try state.decisionCompleted(failed: true, fixed: fixed, inputID: taskInput, failure: "failed Task")
    #expect(!state.loaded.contains("photography") && state.tasks.last?.status == "failed")
}

@Test(.actionCatalog) func skillDefinitionsDoNotBecomeConversationOrRestartActivation() throws {
    var (state, fixed) = try retentionFixture()
    try retainedLoad("photography", state: &state, fixed: fixed)
    try state.resetConversation()
    #expect(!state.loaded.contains("photography") && state.decisions.isEmpty)
    try retainedLoad("photography", state: &state, fixed: fixed)
    state.recover()
    try state.initialize(fixed: fixed, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    #expect(!state.loaded.contains("photography") && state.recentSkills.isEmpty)
}

private actor QueryRetentionModel: ChatCapability {
    let availability: CapabilityAvailability = .available
    let supportsToolCalls = true
    private var count = 0
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        count += 1
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        if count == 1 || count == 3 {
            try pair.emitter.yield(
                .text(count == 1 ? #"<History.list offset="0" limit="1"/>"# : "<History.list/>"))
        } else {
            try pair.emitter.yield(.text("已处理真实结果。"))
        }
        try pair.emitter.yield(.finished(.stop))
        pair.emitter.finish()
        return pair.session
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: [false, true])
func queryActionAdmissionRenewsButParameterRejectionDoesNot(executionFails: Bool) async throws {
    var (skills, fixed) = try retentionFixture()
    try retainedLoad("history-query", state: &skills, fixed: fixed)
    for _ in 0..<3 {
        let id = UUID().uuidString
        try skills.beginDecision(id)
        try skills.decisionCompleted(failed: false, fixed: fixed, inputID: id)
    }
    var initial = AssistantContextState()
    initial.skillState = skills
    let context = try AgentContextRepository(
        agent: .assistant, scope: UUID().uuidString, state: initial
    )
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(), chat: QueryRetentionModel(), context: context)
    _ = try await bindSpeechRequests(agent)
    try await agent.start()
    var outputs = FixtureGenerationOutputs(
        agent: agent,
        actionCompletion: { call in
            call.actionPath.description == "History.Conversation.list"
                ? (.value(executionFails ? "Synthetic execution failure" : "[]"), executionFails ? .handlerFailed : nil)
                : (.completed, nil)
        }
    ).makeAsyncIterator()
    let session = UUID().uuidString
    for index in 0..<2 {
        try await agent.receive(.init(id: UUID().uuidString, sessionID: session, payload: .text("读取历史")))
        while let output = try await outputs.next() {
            if case .control(let value) = output.output {
                try #require(value == "agent.finished", Comment(rawValue: value))
                break
            }
        }
        #expect(
            try await context.snapshot().state.skillState?.recentSkills["history-query"]?.remainingDecisions == 5
                - index)
    }
    await agent.stop()
}

@Test(.actionCatalog) func newConversationDropsRecentSkillsThroughHistoryCommit() async throws {
    let context = try AgentContextRepository(
        agent: .assistant, scope: UUID().uuidString, state: AssistantContextState()
    )
    let store = AgentChatHistoryContext.store(repository: context)
    let input = UUID().uuidString
    _ = try await store.begin(
        id: input, user: "hello", request: [], expecting: store.readCurrent().token, model: "stub")
    try await store.finish(input, state: .completed)
    let fixed = try AssistantAgent.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities)
    try await context.update {
        var skills = AgentTaskSkillState()
        try skills.initialize(fixed: fixed, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
        try retainedLoad("photography", state: &skills, fixed: fixed)
        $0.state.skillState = skills
    }
    _ = try await store.startNew()
    #expect(try await context.snapshot().state.skillState?.loaded.contains("photography") == false)
}

@Test(.actionCatalog) func recentSkillCancellationPreservesOtherSessions() throws {
    var (state, fixed) = try retentionFixture()
    let input = UUID().uuidString
    try state.beginDecision(input, sessionID: "owner")
    _ = try state.control("loadSkills", arguments: ["skills": "[\"photography\"]"], inputID: input, fixed: fixed)
    try state.decisionCompleted(failed: false, fixed: fixed, inputID: input)
    try state.cancelSession("unrelated", inputs: [], fixed: fixed)
    #expect(state.recentSkills["photography"]?.remainingDecisions == 5)
    try state.cancelSession("owner", inputs: [], fixed: fixed)
    #expect(!state.loaded.contains("photography"))
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) func providerSelectionFailureSettlesIdleSkillDecisionOnce() async throws
{
    var (skills, fixed) = try retentionFixture()
    try retainedLoad("photography", state: &skills, fixed: fixed)
    var initial = AssistantContextState()
    initial.skillState = skills
    let context = try AgentContextRepository(
        agent: .assistant, scope: UUID().uuidString, state: initial
    )
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(),
        chatProvider: { throw CapabilityError.unavailable("Synthetic provider failure") }, context: context)
    try await agent.start()
    try await agent.receive(.init(id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("hello")))
    try await skillEventually {
        let state = try await context.snapshot().state.skillState
        return state?.decisions.isEmpty == true && state?.recentSkills["photography"]?.remainingDecisions == 4
    }
    await agent.stop()
}

private func lifecycleSnapshot(_ state: AgentTaskSkillState) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(state)
}

private func idleSkillDecision(_ state: inout AgentTaskSkillState, fixed: CapabilityRegistry) throws {
    let input = UUID().uuidString
    try state.beginDecision(input)
    try state.decisionCompleted(failed: false, fixed: fixed, inputID: input)
}

@Test(
    .actionCatalog, arguments: ["specified", "loaded", "action", "queryAction"],
    ["completed", "failed", "cancelled"])
func preloadedSkillAdoptionReleasesOnlyTaskOwnedSkills(adoption: String, terminal: String) throws {
    var (state, fixed) = try retentionFixture()
    let owned = adoption == "queryAction" ? "history-query" : "photography"
    let unrelated = adoption == "queryAction" ? "photography" : "history-query"
    try retainedLoad(owned, state: &state, fixed: fixed)
    try retainedLoad(unrelated, state: &state, fixed: fixed)
    let frozen = try state.registry(fixed: fixed)
    let remaining = try #require(state.recentSkills[unrelated]?.remainingDecisions)
    let input = UUID().uuidString
    try state.beginDecision(input)
    var arguments = ["description": "接管预加载能力"]
    if adoption == "specified" { arguments["skills"] = "[\"\(owned)\"]" }
    _ = try state.control("task.start", arguments: arguments, inputID: input, fixed: fixed, taskID: fixtureTaskID())
    if adoption == "loaded" {
        _ = try state.control("loadSkills", arguments: ["skills": "[\"\(owned)\"]"], inputID: input, fixed: fixed)
    } else if adoption == "action" || adoption == "queryAction" {
        #expect(try state.ownership(owned) == "recent")
        try state.recordUse(
            path: adoption == "queryAction" ? "History.Conversation.list" : "Camera.Capture.close",
            callType: "action", inputID: input, snapshotSkills: state.loaded)
    }
    let task = try #require(state.activeTaskID)
    #expect(try state.ownership(owned) == "task")
    #expect(state.recentSkills[owned] == nil && state.tasks.last?.skills.contains(unrelated) == false)
    try state.decisionCompleted(failed: false, fixed: fixed, inputID: input)
    #expect(state.tasks.last?.status == "waitingUser" && state.loaded.contains(owned))
    let finish = UUID().uuidString
    try state.beginDecision(finish)
    try state.bind(finish, task: task)
    if terminal != "failed" {
        _ = try state.control(
            terminal == "completed" ? "task.end" : "task.cancel",
            arguments: terminal == "completed" ? ["summary": "完成"] : ["reason": "用户取消"],
            inputID: finish, fixed: fixed)
        #expect(state.loaded.contains(owned))  // Admission alone must not release before the barrier.
    }
    try state.decisionCompleted(
        failed: terminal == "failed", fixed: fixed, inputID: finish,
        failure: terminal == "failed" ? "Synthetic device failure" : nil)
    #expect(state.activeTaskID == nil && state.tasks.last?.status == terminal)
    #expect(!state.loaded.contains(owned) && state.recentSkills[owned] == nil)
    #expect(state.recentSkills[unrelated]?.remainingDecisions == remaining)
    #expect(state.tasks.last?.skills.contains(owned) == true)
    #expect(state.events.filter { $0.skill == owned && $0.reason == "taskEnded" && $0.taskID == task }.count == 1)
    let settled = try lifecycleSnapshot(state)
    try state.decisionCompleted(failed: false, fixed: fixed, inputID: finish)
    #expect(try lifecycleSnapshot(state) == settled)
    #expect(frozen.actions.contains { $0.alias == "closeCamera" })
    #expect(frozen.actions.contains { $0.path.description == "History.Conversation.list" })
    try state.validate()
}

@Test(.actionCatalog) func waitingTaskPausesUnrelatedSkillUntilFirstPostTaskDecision() throws {
    var (state, fixed) = try retentionFixture()
    try retainedLoad("history-query", state: &state, fixed: fixed)
    for _ in 0..<4 { try idleSkillDecision(&state, fixed: fixed) }
    #expect(state.recentSkills["history-query"]?.remainingDecisions == 1)
    let input = UUID().uuidString
    try state.beginDecision(input)
    _ = try state.control(
        "task.start", arguments: ["description": "等待选择"], inputID: input, fixed: fixed, taskID: fixtureTaskID())
    let task = try #require(state.activeTaskID)
    try state.decisionCompleted(failed: false, fixed: fixed, inputID: input)
    for _ in 0..<6 {
        let next = UUID().uuidString
        try state.beginDecision(next)
        try state.bind(next, task: task)
        try state.decisionCompleted(failed: false, fixed: fixed, inputID: next)
        #expect(state.tasks.last?.status == "waitingUser")
        #expect(state.recentSkills["history-query"]?.remainingDecisions == 1)
    }
    let finish = UUID().uuidString
    try state.beginDecision(finish)
    _ = try state.control("task.end", arguments: ["summary": "选择完成"], inputID: finish, fixed: fixed)
    try state.settleTask(failed: false, fixed: fixed)
    try state.decisionCompleted(failed: false, fixed: fixed, inputID: finish)
    #expect(state.recentSkills["history-query"]?.remainingDecisions == 1)
    try idleSkillDecision(&state, fixed: fixed)
    #expect(!state.loaded.contains("history-query"))
}

@Test(.actionCatalog) func skillUsedBeforeTaskInSameDecisionIsNotImplicitlyAdopted() throws {
    var (state, fixed) = try retentionFixture()
    let input = UUID().uuidString
    try state.beginDecision(input)
    _ = try state.control("loadSkills", arguments: ["skills": "[\"photography\"]"], inputID: input, fixed: fixed)
    try state.recordUse(path: "Camera.Capture.close", callType: "action", inputID: input, snapshotSkills: state.loaded)
    _ = try state.control(
        "task.start", arguments: ["description": "另外的目标"], inputID: input, fixed: fixed, taskID: fixtureTaskID())
    _ = try state.control("task.end", arguments: ["summary": "完成"], inputID: input, fixed: fixed)
    try state.decisionCompleted(failed: false, fixed: fixed, inputID: input)
    #expect(state.taskSkillRoots.isEmpty && state.recentSkills["photography"]?.remainingDecisions == 5)
    #expect(state.tasks.last?.skills.contains("photography") == false)
}

@Test(.actionCatalog, arguments: [false, true])
func skillReloadAtLastChanceOrAfterExpiryStartsFreshFiveDecisionWindow(afterExpiry: Bool) throws {
    var (state, fixed) = try retentionFixture()
    try retainedLoad("photography", state: &state, fixed: fixed)
    for _ in 0..<(afterExpiry ? 5 : 4) { try idleSkillDecision(&state, fixed: fixed) }
    let oldLoads = state.events.filter { $0.operation == "load" && $0.skill == "photography" }.count
    try retainedLoad("photography", state: &state, fixed: fixed)
    #expect(state.recentSkills["photography"]?.remainingDecisions == 5)
    #expect(
        state.events.filter { $0.operation == "load" && $0.skill == "photography" }.count == oldLoads
            + (afterExpiry ? 1 : 0))
    #expect(try state.registry(fixed: fixed).actions.filter { $0.alias == "closeCamera" }.count == 1)
    for _ in 0..<4 { try idleSkillDecision(&state, fixed: fixed) }
    #expect(state.recentSkills["photography"]?.remainingDecisions == 1)
    try idleSkillDecision(&state, fixed: fixed)
    #expect(!state.loaded.contains("photography"))
}

@Test(.actionCatalog) func lastChanceActionRenewsOnlyItsProvidingSkill() throws {
    var (state, fixed) = try retentionFixture()
    let load = UUID().uuidString
    try state.beginDecision(load)
    _ = try state.control(
        "loadSkills", arguments: ["skills": "[\"photography\",\"history-query\"]"], inputID: load, fixed: fixed)
    try state.decisionCompleted(failed: false, fixed: fixed, inputID: load)
    for _ in 0..<4 { try idleSkillDecision(&state, fixed: fixed) }
    let input = UUID().uuidString
    try state.beginDecision(input)
    for _ in 0..<3 {
        try state.recordUse(
            path: "Camera.Capture.close", callType: "action", inputID: input, snapshotSkills: state.loaded)
    }
    try state.decisionCompleted(failed: false, fixed: fixed, inputID: input)
    #expect(state.recentSkills["photography"]?.remainingDecisions == 5)
    #expect(!state.loaded.contains("history-query"))
    #expect(state.events.filter { $0.skill == "history-query" && $0.reason == "idle" }.count == 1)
}

@Test(.actionCatalog, arguments: ["wrongType", "absentSnapshot", "unknownPath", "baseFunction"])
func unrelatedOrUnexposedCallsCannotRenewOrAdoptSkill(reason: String) throws {
    var (state, fixed) = try retentionFixture()
    try retainedLoad("photography", state: &state, fixed: fixed)
    for _ in 0..<4 { try idleSkillDecision(&state, fixed: fixed) }
    let input = UUID().uuidString
    try state.beginDecision(input)
    try state.recordUse(
        path: reason == "unknownPath"
            ? "Unknown.Function.call" : (reason == "baseFunction" ? "UI.Expression.express" : "Camera.Capture.close"),
        callType: reason == "wrongType" ? "tool" : "action", inputID: input,
        snapshotSkills: reason == "absentSnapshot" ? [] : state.loaded)
    try state.decisionCompleted(failed: false, fixed: fixed, inputID: input)
    #expect(!state.loaded.contains("photography"))
    #expect(state.decisions.isEmpty)
}

@Test(.actionCatalog) func pendingDecisionCapacityRejectsAtomicallyAndDiscardReleasesProtection() throws {
    var (state, fixed) = try retentionFixture()
    try retainedLoad("photography", state: &state, fixed: fixed)
    let inputs = (0..<32).map { _ in UUID().uuidString }
    for input in inputs { try state.beginDecision(input, sessionID: "owner") }
    try state.recordUse(
        path: "Camera.Capture.close", callType: "action", inputID: inputs[0], snapshotSkills: state.loaded)
    try state.beginDecision(inputs[0], sessionID: "foreign", countsIdle: false)
    #expect(state.decisions[inputs[0]]?.sessionID == "owner" && state.decisions[inputs[0]]?.countsIdle == true)
    let before = try lifecycleSnapshot(state)
    #expect(throws: CommunicationError.capacityExceeded) { try state.beginDecision(UUID().uuidString) }
    #expect(try lifecycleSnapshot(state) == before)
    state.discardDecision(inputs[0])
    for input in inputs.dropFirst() { state.discardDecision(input) }
    #expect(state.recentSkills["photography"]?.remainingDecisions == 5)
    for _ in 0..<5 { try idleSkillDecision(&state, fixed: fixed) }
    #expect(!state.loaded.contains("photography") && state.decisions.isEmpty)
}

@Test(.actionCatalog, arguments: ["[\"basic-skill\"]", "[\"missing\"]", "[\"photography\",\"basic-skill\"]"])
func invalidSkillReleaseCannotPartiallyRemoveRecentSkills(skills: String) throws {
    var (state, fixed) = try retentionFixture()
    try retainedLoad("photography", state: &state, fixed: fixed)
    let before = try lifecycleSnapshot(state)
    #expect(throws: CommunicationError.unauthorized) {
        try state.control("releaseSkills", arguments: ["skills": skills], inputID: UUID().uuidString, fixed: fixed)
    }
    #expect(try lifecycleSnapshot(state) == before)
}

@Test(.actionCatalog) func explicitTaskSkillReleaseKeepsHistoricalEvidenceAndNeverResurrects() throws {
    var (state, fixed) = try retentionFixture()
    let input = UUID().uuidString
    try state.beginDecision(input)
    _ = try state.control(
        "task.start", arguments: ["description": "主动释放", "skills": "[\"photography\"]"], inputID: input, fixed: fixed,
        taskID: fixtureTaskID())
    let snapshot = state.loaded
    _ = try state.control("releaseSkills", arguments: ["skills": "[\"photography\"]"], inputID: input, fixed: fixed)
    #expect(state.activeTaskID != nil && state.taskSkillRoots.isEmpty)
    try state.recordUse(path: "Camera.Capture.close", callType: "action", inputID: input, snapshotSkills: snapshot)
    #expect(!state.loaded.contains("photography"))
    _ = try state.control("task.end", arguments: ["summary": "完成"], inputID: input, fixed: fixed)
    try state.decisionCompleted(failed: false, fixed: fixed, inputID: input)
    #expect(state.tasks.last?.skills.contains("photography") == true)
    #expect(
        state.events.filter { $0.skill == "photography" && $0.operation == "release" }.map(\.reason) == ["explicit"])
}

@Test(.actionCatalog, arguments: [0, -1]) func skillByteBudgetAcceptsExactLimitAndRejectsOneByteLess(delta: Int) throws
{
    var (state, fixed) = try retentionFixture()
    let base = state.loaded
    let expanded = try AgentSkillLoader.expand(base + ["photography"])
    state.policy.maximumNonBaseBytes = try AgentSkillLoader.nonBaseBytes(expanded, base: base) + delta
    let before = try lifecycleSnapshot(state)
    if delta == 0 {
        try retainedLoad("photography", state: &state, fixed: fixed)
        #expect(state.loaded.contains("photography"))
    } else {
        #expect(throws: CommunicationError.capacityExceeded) {
            try state.control(
                "loadSkills", arguments: ["skills": "[\"photography\"]"], inputID: UUID().uuidString, fixed: fixed)
        }
        #expect(try lifecycleSnapshot(state) == before)
    }
}

@Test(.actionCatalog) func allThreeNonBaseSkillsFitAndRepeatedLoadDoesNotDuplicateCatalog() throws {
    var (state, fixed) = try retentionFixture()
    let input = UUID().uuidString
    try state.beginDecision(input)
    let arguments = ["skills": "[\"photography\",\"history-query\",\"application-control\"]"]
    _ = try state.control("loadSkills", arguments: arguments, inputID: input, fixed: fixed)
    let loaded = state.loaded
    let events = state.events.count
    for _ in 0..<8 { _ = try state.control("loadSkills", arguments: arguments, inputID: input, fixed: fixed) }
    try state.decisionCompleted(failed: false, fixed: fixed, inputID: input)
    #expect(state.loaded == loaded && state.events.count == events)
    #expect(state.recentSkills.count == 3 && state.recentSkills.values.allSatisfy { $0.remainingDecisions == 5 })
    let catalog = try state.registry(fixed: fixed)
    #expect(Set(catalog.actions.map(\.alias)).count == catalog.actions.count)
    try state.validate()
}

@Test(.actionCatalog) func capacityCannotEvictTaskSkillAndRecoversAfterTaskEnds() throws {
    var (state, fixed) = try retentionFixture()
    state.policy.maximumNonBaseSkills = 1
    let input = UUID().uuidString
    try state.beginDecision(input)
    _ = try state.control(
        "task.start", arguments: ["description": "保留相机", "skills": "[\"photography\"]"], inputID: input, fixed: fixed,
        taskID: fixtureTaskID())
    let before = try lifecycleSnapshot(state)
    #expect(throws: CommunicationError.capacityExceeded) {
        try state.control("loadSkills", arguments: ["skills": "[\"history-query\"]"], inputID: input, fixed: fixed)
    }
    #expect(try lifecycleSnapshot(state) == before)
    _ = try state.control("task.end", arguments: ["summary": "完成"], inputID: input, fixed: fixed)
    try state.decisionCompleted(failed: false, fixed: fixed, inputID: input)
    try retainedLoad("history-query", state: &state, fixed: fixed)
    #expect(state.recentSkills["history-query"]?.remainingDecisions == 5 && !state.loaded.contains("photography"))
}

@Test(.actionCatalog) func oversizedBatchLoadRollsBackTentativeEvictionsAndEvents() throws {
    var (state, fixed) = try retentionFixture()
    state.policy.maximumNonBaseSkills = 1
    try retainedLoad("application-control", state: &state, fixed: fixed)
    let before = try lifecycleSnapshot(state)
    #expect(throws: CommunicationError.capacityExceeded) {
        try state.control(
            "loadSkills", arguments: ["skills": "[\"photography\",\"history-query\"]"], inputID: UUID().uuidString,
            fixed: fixed)
    }
    #expect(try lifecycleSnapshot(state) == before)
    #expect(state.loaded.contains("application-control"))
}

@Test(.actionCatalog) func recentSkillLatestUsingSessionOwnsCancellation() throws {
    var (state, fixed) = try retentionFixture()
    let first = UUID().uuidString
    try state.beginDecision(first, sessionID: "first")
    _ = try state.control("loadSkills", arguments: ["skills": "[\"photography\"]"], inputID: first, fixed: fixed)
    try state.decisionCompleted(failed: false, fixed: fixed, inputID: first)
    let second = UUID().uuidString
    try state.beginDecision(second, sessionID: "second")
    try state.recordUse(path: "Camera.Capture.close", callType: "action", inputID: second, snapshotSkills: state.loaded)
    try state.decisionCompleted(failed: false, fixed: fixed, inputID: second)
    #expect(state.recentSkills["photography"]?.sessionID == "second")
    try state.cancelSession("first", inputs: [first], fixed: fixed)
    #expect(state.recentSkills["photography"]?.remainingDecisions == 5)
    try state.cancelSession("second", inputs: [second], fixed: fixed)
    #expect(!state.loaded.contains("photography"))
}

@Test(.actionCatalog) func cancellingUnrelatedSessionKeepsTaskAndClearsOnlyItsPendingDecision() throws {
    var (state, fixed) = try retentionFixture()
    let owner = UUID().uuidString
    try state.beginDecision(owner, sessionID: "task-owner")
    _ = try state.control(
        "task.start", arguments: ["description": "等待用户", "skills": "[\"photography\"]"], inputID: owner, fixed: fixed,
        sessionID: "task-owner", taskID: fixtureTaskID())
    try state.decisionCompleted(failed: false, fixed: fixed, inputID: owner)
    let other = UUID().uuidString
    try state.beginDecision(other, sessionID: "other")
    try state.cancelSession("other", inputs: [other], fixed: fixed)
    #expect(state.activeTaskID != nil && state.tasks.last?.status == "waitingUser")
    #expect(state.loaded.contains("photography") && state.decisions.isEmpty)
    try state.cancelSession("task-owner", inputs: [], fixed: fixed)
    #expect(state.activeTaskID == nil && !state.loaded.contains("photography"))
}

@Test(.actionCatalog) func globalSessionResetReleasesRecentAndTaskSkillsButKeepsBaseAndEvidence() throws {
    var (state, fixed) = try retentionFixture()
    let base = state.loaded
    try retainedLoad("history-query", state: &state, fixed: fixed)
    let input = UUID().uuidString
    try state.beginDecision(input)
    _ = try state.control(
        "task.start", arguments: ["description": "关闭宿主", "skills": "[\"photography\"]"], inputID: input, fixed: fixed,
        taskID: fixtureTaskID())
    try state.resetSession(fixed: fixed)
    #expect(
        state.loaded == base && state.recentSkills.isEmpty && state.taskSkillRoots.isEmpty && state.decisions.isEmpty)
    #expect(state.activeTaskID == nil && state.tasks.last?.status == "cancelled")
    #expect(state.tasks.last?.skills.contains("photography") == true)
    let settled = try lifecycleSnapshot(state)
    try state.resetSession(fixed: fixed)
    #expect(try lifecycleSnapshot(state) == settled)
}

@Test(.actionCatalog, arguments: [false, true]) func restartInterruptsTaskAndDiscardsAllNonBaseActivation(waiting: Bool)
    throws
{
    var (state, fixed) = try retentionFixture()
    let base = state.loaded
    try retainedLoad("history-query", state: &state, fixed: fixed)
    let input = UUID().uuidString
    try state.beginDecision(input)
    _ = try state.control(
        "task.start", arguments: ["description": "重启前任务", "skills": "[\"photography\"]"], inputID: input, fixed: fixed,
        taskID: fixtureTaskID())
    if waiting { try state.decisionCompleted(failed: false, fixed: fixed, inputID: input) }
    state.recover()
    try state.initialize(fixed: fixed, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    #expect(state.tasks.last?.status == "interrupted" && state.tasks.last?.skills.contains("photography") == true)
    #expect(state.loaded == base && state.activeTaskID == nil && state.decisions.isEmpty && state.recentSkills.isEmpty)
    try state.validate()
}

@Test(.actionCatalog, arguments: ["idle", "release", "terminal"])
func failedLifecycleCommitCanRetryWithoutDoubleReleaseOrCountdown(operation: String) async throws {
    struct SyntheticWriteFailure: Error {}
    final class FailOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false
        func commit() throws {
            try lock.withLock {
                if !failed {
                    failed = true
                    throw SyntheticWriteFailure()
                }
            }
        }
    }
    var (skills, fixed) = try retentionFixture()
    try retainedLoad("photography", state: &skills, fixed: fixed)
    if operation == "idle" {
        for _ in 0..<4 { try idleSkillDecision(&skills, fixed: fixed) }
    }
    let input = UUID().uuidString
    try skills.beginDecision(input)
    if operation == "terminal" {
        _ = try skills.control(
            "task.start", arguments: ["description": "提交失败重试", "skills": "[\"photography\"]"], inputID: input,
            fixed: fixed,
            taskID: fixtureTaskID())
        _ = try skills.control("task.end", arguments: ["summary": "完成"], inputID: input, fixed: fixed)
    }
    var initial = AssistantContextState()
    initial.skillState = skills
    let failure = FailOnce()
    let repository = try AgentContextRepository(
        agent: .assistant, scope: UUID().uuidString, state: initial,
        persistence: AgentContextPersistence(load: { nil }, commit: { _, _ in try failure.commit() })
    )
    let original = try lifecycleSnapshot(skills)
    let mutate: @Sendable (inout AgentContext<AssistantContextState>) throws -> Void = { [fixed] context in
        if operation == "release" {
            _ = try context.state.skillState?.control(
                "releaseSkills", arguments: ["skills": "[\"photography\"]"], inputID: input, fixed: fixed)
        } else {
            try context.state.skillState?.decisionCompleted(failed: false, fixed: fixed, inputID: input)
        }
    }
    await #expect(throws: SyntheticWriteFailure.self) { try await repository.update(mutate) }
    #expect(try lifecycleSnapshot(try #require(try await repository.snapshot().state.skillState)) == original)
    try await repository.update(mutate)
    let committed = try #require(try await repository.snapshot().state.skillState)
    #expect(!committed.loaded.contains("photography"))
    #expect(committed.events.filter { $0.skill == "photography" && $0.operation == "release" }.count == 1)
    if operation == "terminal" { #expect(committed.tasks.last?.status == "completed") }
}

@Test(.actionCatalog, arguments: [false, true]) func activeTaskRejectsConversationResetWithoutLosingSkills(
    waiting: Bool
) async throws {
    var (skills, fixed) = try retentionFixture()
    let input = UUID().uuidString
    try skills.beginDecision(input)
    _ = try skills.control(
        "task.start", arguments: ["description": "保持任务", "skills": "[\"photography\"]"], inputID: input, fixed: fixed,
        taskID: fixtureTaskID())
    if waiting { try skills.decisionCompleted(failed: false, fixed: fixed, inputID: input) }
    var initial = AssistantContextState()
    initial.skillState = skills
    let context = try AgentContextRepository(
        agent: .assistant, scope: UUID().uuidString, state: initial
    )
    let store = AgentChatHistoryContext.store(repository: context)
    _ = try await store.begin(id: input, user: "保持任务", request: [], expecting: store.readCurrent().token, model: "stub")
    try await store.finish(input, state: .completed)
    let before = try lifecycleSnapshot(try #require(try await context.snapshot().state.skillState))
    await #expect(throws: CommunicationError.scopeClosed) { _ = try await store.startNew() }
    #expect(try lifecycleSnapshot(try #require(try await context.snapshot().state.skillState)) == before)
}

private actor SkillLifecycleModel: ChatCapability {
    let availability: CapabilityAvailability = .available
    let supportsToolCalls = true
    let queryRounds: Int
    private(set) var requests: [ChatRequest] = []
    init(queryRounds: Int = 0) { self.queryRounds = queryRounds }
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        requests.append(request)
        let pair = InferenceSession<ChatEvent>.make(limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        if requests.count <= queryRounds {
            try pair.emitter.yield(.text(#"<History.list offset="0" limit="1"/>"#))
        } else {
            try pair.emitter.yield(.text("已完成第 \(requests.count) 次请求。"))
        }
        try pair.emitter.yield(.finished(.stop))
        pair.emitter.finish()
        return pair.session
    }
}

private func completeLifecycleDecision(
    agent: AssistantAgent, outputs: inout FixtureGenerationOutputs.Iterator, session: String
) async throws -> Int {
    let input = UUID().uuidString
    try await agent.receive(.init(id: input, sessionID: session, payload: .text("继续对话 \(input)")))
    var queryCalls = 0
    while let output = try await outputs.next() {
        if case .actionCall(let call) = output.output, call.actionPath.description == "History.Conversation.list" {
            queryCalls += 1
        }
        if case .control(let value) = output.output {
            try #require(!value.hasPrefix("agent.error:"), Comment(rawValue: value))
            if value == "agent.finished" { return queryCalls }
        }
    }
    throw CapabilityError.unavailable("Synthetic lifecycle stream ended before decision completion")
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func assistantIdleExpiryChangesNextRequestCatalogButKeepsEarlierConversationEvidence() async throws {
    var (skills, fixed) = try retentionFixture()
    try retainedLoad("photography", state: &skills, fixed: fixed)
    var initial = AssistantContextState()
    initial.skillState = skills
    let context = try AgentContextRepository(
        agent: .assistant, scope: UUID().uuidString, state: initial
    )
    let model = SkillLifecycleModel()
    let agent = try AssistantAgent(stateContext: try publicStateFixture(), chat: model, context: context)
    _ = try await bindSpeechRequests(agent)
    try await agent.start()
    var outputs = FixtureGenerationOutputs(agent: agent).makeAsyncIterator()
    let session = UUID().uuidString
    for index in 0..<7 {
        #expect(try await completeLifecycleDecision(agent: agent, outputs: &outputs, session: session) == 0)
        let state = try #require(try await context.snapshot().state.skillState)
        #expect(state.recentSkills["photography"]?.remainingDecisions == (index < 4 ? 4 - index : nil))
    }
    let requests = await model.requests
    try #require(requests.count == 7)
    for (index, request) in requests.enumerated() {
        #expect(request.messages.first?.content.contains("Action closeCamera:") == (index < 5))
    }
    let history = try await context.snapshot().state.history.current
    #expect(history.turns.count == 7)
    #expect(history.turns.first?.modelRequests?.first?.decisionMetadata?.skills["photography"] != nil)
    #expect(history.turns.last?.modelRequests?.first?.decisionMetadata?.skills["photography"] == nil)
    for turn in history.turns {
        let metadata = try #require(turn.modelRequests?.first?.decisionMetadata)
        #expect(metadata.states == (try AgentSkillLoader.useStates(Array(metadata.skills.keys))))
    }
    #expect(requests.last?.messages.contains { $0.role == .assistant && $0.content == "已完成第 1 次请求。" } == true)
    await agent.stop()
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) func assistantLongReACTRenewsUsedSkillAndDecrementsUnusedSkillOnlyOnce()
    async throws
{
    var (skills, fixed) = try retentionFixture()
    try retainedLoad("photography", state: &skills, fixed: fixed)
    try retainedLoad("history-query", state: &skills, fixed: fixed)
    var initial = AssistantContextState()
    initial.skillState = skills
    let context = try AgentContextRepository(
        agent: .assistant, scope: UUID().uuidString, state: initial
    )
    let model = SkillLifecycleModel(queryRounds: 8)
    let agent = try AssistantAgent(stateContext: try publicStateFixture(), chat: model, context: context)
    _ = try await bindSpeechRequests(agent)
    try await agent.start()
    var outputs = FixtureGenerationOutputs(
        agent: agent,
        actionCompletion: { call in
            (call.actionPath.description == "History.Conversation.list" ? .value("[]") : .completed, nil)
        }
    ).makeAsyncIterator()
    let session = UUID().uuidString
    #expect(try await completeLifecycleDecision(agent: agent, outputs: &outputs, session: session) == 8)
    let first = try #require(try await context.snapshot().state.skillState)
    #expect(first.recentSkills["photography"]?.remainingDecisions == 3)
    #expect(first.recentSkills["history-query"]?.remainingDecisions == 5 && first.decisions.isEmpty)
    #expect(await model.requests.count == 9)
    #expect(try await completeLifecycleDecision(agent: agent, outputs: &outputs, session: session) == 0)
    let second = try #require(try await context.snapshot().state.skillState)
    #expect(second.recentSkills["photography"]?.remainingDecisions == 2)
    #expect(second.recentSkills["history-query"]?.remainingDecisions == 4)
    let history = try await context.snapshot().state.history.current
    #expect(history.turns.count == 2 && history.turns.first?.modelRequests?.count == 9)
    #expect(history.turns.first?.toolCalls?.isEmpty != false)
    #expect(
        history.turns.first?.generationRounds?.filter { $0.resultsJSON.contains("History.Conversation.list") }.count
            == 8)
    await agent.stop()
}

@Test(.actionCatalog) func migratedSkillQueriesHaveExecutableActionBindingsAndRetainedToolViews() async throws {
    let catalog = try AgentSkillLoader.registry(
        ["application-control", "history-query"], fixed: CapabilityRegistry())
    let queries = catalog.actions.filter { $0.defaultChannel == "Query" }
    try #require(queries.count == 5 && catalog.tools.isEmpty)
    struct Module: CapabilityModule { let definitions: [ActionFunction] }
    let definitions = try queries.map { query in
        let declaration = try #require(
            CapabilityModules.declarations.first { $0.path.description == query.path.description })
        return ActionFunction(
            path: declaration.path, declaration: declaration, displayName: query.alias, kind: .finite,
            completion: "Return synthetic query evidence.", completing: { _ in .value(query.alias) })
    }
    let assembly = try BehaviorAssembly(capabilityModules: [Module(definitions: definitions)])
    for query in queries {
        #expect(await assembly.tools.handler(for: query.path.description) != nil)
        let parameters: [String: String] =
            query.alias == "History.list"
            ? ["offset": "0", "limit": "1"]
            : (query.alias == "History.read" ? ["id": "dialog_17", "offset": "0", "limit": "1"] : [:])
        let input = AgentInput(id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("query fixture"))
        let call = try catalog.resolveAction(query.alias, parameters: parameters)
        let invocation = try ActionInvocation(
            envelope: OutputEnvelope(
                source: .assistant, context: input.context, output: .actionCall(call), taskScope: input.taskScope))
        #expect(try await ActionExecutor(registry: assembly.actions).execute(invocation) == .value(query.alias))
    }
}

@Test(
    .actionCatalog, .timeLimit(.minutes(1)), arguments: [false, true],
    [
        "completed", "failed", "failedRetry", "failedDiagnostic", "rejected", "rejectedRetry", "coalesced",
        "liveProgress", "closed", "switched", "playback", "completionFacts",
        "peerReply", "deferredNew", "task.cancel",
    ])
func writerWaitingAndCompletionEnterAssistantModelFIFO(foreground: Bool, outcome: String)
    async throws
{
    let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let database = try SQLiteRepositories(url: databaseURL)
    let history = AssistantHistoryStore(
        records: try AssistantRecordStore(
            repository: database.assistantMessages, tasks: database.assistantTasks,
            conversations: database.assistantConversations, logs: database.logs))
    let session = UUID().uuidString
    let context = try AgentContextRepository(
        agent: AgentID.assistant, scope: UUID().uuidString, state: AssistantContextState())
    let model = WriterNoticeModel(
        delegate: true, retryFailed: outcome == "failedRetry", retryRejected: outcome == "rejectedRetry")
    let assistant = try AssistantAgent(
        stateContext: try publicStateFixture(),
        reportsReplyActivity: ["completionFacts", "peerReply"].contains(outcome),
        chat: model, conversations: history, communications: database.agentMessages, context: context,
        backgroundSupport: { target, _, _ in
            guard target == .writer else { throw CommunicationError.unsupportedContract }
        })
    let child = ObservationRecorder(
        id: "writer", reject: outcome.hasPrefix("rejected"), tasks: database.writerExecutions)
    let speech = ObservationRecorder(id: "speechSynthesis")
    let manager = AgentManager()
    try await manager.register(assistant, sessionID: session)
    try await manager.register(child, sessionID: session)
    try await manager.register(speech, sessionID: session)
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, configurations: AgentConfigurations.all())
    let input = InputGateway(manager: manager, policy: policy)
    struct Module: ActionModule { let definitions: [ActionBinding] }
    let playbackGate = WriterReplyPlaybackGate(blocked: outcome == "playback" && !foreground)
    let definitions = ["UI.Caption.print", "UI.Caption.beginReplyTurn", "Speech.Playback.speak"].map { path in
        let parts = path.split(separator: ".").map(String.init)
        return ActionBinding(
            path: .init(domain: parts[0], module: parts[1], function: parts[2]),
            displayName: path, kind: .finite, completion: "Fixture",
            completing: { _ in
                if path == "Speech.Playback.speak" { await playbackGate.wait() }
                return .completed
            })
    }
    let assembly = try BehaviorAssembly(capabilityModules: [
        TaskControlModule(capability: SkillControls(agent: assistant))
    ])
    let taskBindings = assembly.bindings.filter { $0.protocols == [.action] }
    #expect(taskBindings.allSatisfy { if case .scheduled = $0.executionPolicy { true } else { false } })
    let scheduler = ChannelScheduler(
        registry: try ActionRegistry(modules: [Module(definitions: definitions + taskBindings)])
    ) {
        await input.deliverActionResult($0)
    }
    let output = await OutputGateway(
        manager: manager, requests: input, tools: assembly.tools, actions: scheduler, policy: policy, sink: { _ in })
    try await assistant.start()
    await child.start()
    await speech.start()
    let log = WriterOutputLog()
    let consumer = try await output.consumer(for: assistant)
    let collection = Task {
        do {
            try await IndependentOutputWorkflow.consumeGeneration(assistant.outputs) { envelope in
                await log.append(envelope)
                _ = try await consumer.execute(envelope)
            }
        } catch {
            await log.failed(String(describing: error))
            throw error
        }
    }
    if foreground {
        _ = try await assistant.controlTask(
            "task.start", arguments: ["description": "继续处理独立任务"],
            source: "assistant", sessionID: session, inputID: UUID().uuidString, decisionID: nil)
    }
    let priorTask = try await context.snapshot().state.skillState?.activeTaskID
    try await assistant.receive(.init(id: UUID().uuidString, sessionID: session, payload: .text("帮我画一个蓝色的流程图")))
    if outcome == "playback", !foreground {
        try await skillEventually { await playbackGate.entered }
    } else {
        try await skillEventually { try await context.snapshot().work.values.contains { $0.state == .completed } }
    }
    let taskStateAfterDelegation = try await context.snapshot().state
    #expect(
        taskStateAfterDelegation.skillState?.activeTaskID == priorTask,
        Comment(
            rawValue:
                "history=\(taskStateAfterDelegation.history.current.turns.map { $0.error ?? "none" }); tasks=\(taskStateAfterDelegation.skillState?.tasks.map { $0.status + ":" + ($0.failure ?? "") } ?? [])"
        ))
    if outcome.hasPrefix("rejected") {
        if outcome == "rejectedRetry" { #expect(await model.requests.count == 3) }
        let views = try await context.snapshot().state.taskViews ?? [:]
        #expect(views.count == 1)
        #expect(views.values.allSatisfy { $0.terminal && $0.stage == .completed })
        try await skillEventually { await log.values.contains { $0.output == .control("agent.finished") } }
        await model.delegateAgain()
        try await assistant.receive(.init(id: UUID().uuidString, sessionID: session, payload: .text("再委托一次")))
        try await skillEventually {
            let views = try await context.snapshot().state.taskViews ?? [:]
            let finished = await log.finishedDecisions.count
            return views.count == 2 && views.values.allSatisfy { $0.terminal } && finished == 2
        }
        // Failed delegation must not leave a generating history row that blocks archival.
        if foreground {
            _ = try await assistant.controlTask(
                "task.cancel", arguments: ["reason": "test cleanup"], source: "assistant", sessionID: session,
                inputID: UUID().uuidString, decisionID: nil)
        }
        _ = try await history.startNew()
        await assistant.stop()
        try await collection.value
        await child.stop()
        await speech.stop()
        await output.shutdown()
        try await database.shutdown()
        return
    }
    let received = try #require(await child.inputs.last)
    guard case .observation(let message) = received.payload else { throw CommunicationError.invalidPayload }
    let request = try #require(message.content(as: AgentTaskSignal.self))
    #expect(request.scope.parentID == nil)
    let payload = try #require(JSONSerialization.jsonObject(with: request.data) as? [String: String])
    #expect(payload["goal"] == "绘制蓝色流程图")
    #expect(payload["request"] == "帮我画一个蓝色的流程图")
    let port = try await output.messaging(for: .writer)
    if outcome == "task.cancel" {
        let stable = try await database.writerExecutions.request(request.scope.id, agent: "writer").taskID
        try await skillEventually { await log.finishedDecisions.count == 1 }
        for (operation, arguments) in [
            ("task.delegate", ["target": "writer", "goal": "obsolete"]),
            ("task.send", ["taskID": stable, "type": "cancel"]),
            ("task.send", ["taskID": stable, "type": "input", "text": "obsolete"]),
            ("task.end", ["taskID": stable, "summary": "not owned"]),
            ("task.start", ["execution": "background", "target": "writer", "goal": "obsolete"]),
            ("task.start", ["execution": "foreground", "executor": "writer", "goal": "wrong scope"]),
            (
                "task.start",
                ["execution": "background", "executor": "writer", "goal": "work", "businessContract": "writer.author"]
            ),
        ] {
            await #expect(throws: (any Error).self) {
                try await assistant.controlTask(
                    operation, arguments: arguments,
                    source: "assistant", sessionID: session, inputID: UUID().uuidString, decisionID: nil)
            }
        }
        #expect(await child.inputs.count == 1)
        #expect(try await context.snapshot().state.skillState?.activeTaskID == priorTask)
        await model.cancel(stable)
        try await assistant.receive(
            .init(id: UUID().uuidString, sessionID: session, payload: .text("Cancel the Writer work")))
        try await skillEventually { await log.finishedDecisions.count == 2 }
        let cancelledInput = try #require(await child.inputs.last)
        guard case .observation(let message) = cancelledInput.payload,
            let cancel = message.content(as: AgentTaskSignal.self)
        else { throw CommunicationError.invalidPayload }
        #expect(cancel.kind == .cancel && cancel.scope == request.scope)
        #expect(try await context.snapshot().state.taskViews?[request.scope.id]?.terminal == false)
        #expect(try await context.snapshot().state.skillState?.activeTaskID == priorTask)
        #expect(try AgentTaskContent.decode(cancel).text == "User cancelled")
        #expect(try await database.agentMessages.agentMessage(cancelledInput.id)?.contract == "task.cancel")
        let ended = try await fixtureWriterCompletion(
            AgentTaskContent(
                text: "Cleanup complete", stage: .completed,
                writerEvent: .init(sequence: 1, kind: .cancelled)),
            scope: request.scope, status: .cancelled, tasks: database.writerExecutions)
        _ = try await port.sendResult(ended.signal.message(), parent: received, to: .assistant)
        _ = try await port.sendResult(ended.message, parent: received, to: .assistant)
        try await skillEventually { await log.finishedDecisions.count == 3 }
        #expect(try await context.snapshot().state.taskViews?[request.scope.id]?.terminal == true)
        #expect(try await context.snapshot().state.skillState?.activeTaskID == priorTask)
        if foreground {
            _ = try await assistant.controlTask(
                "task.cancel", arguments: ["reason": "test cleanup"],
                source: "assistant", sessionID: session, inputID: UUID().uuidString, decisionID: nil)
        }
        _ = try await history.startNew()
        await assistant.stop()
        try await collection.value
        await child.stop()
        await speech.stop()
        await output.shutdown()
        try await database.shutdown()
        return
    }
    if outcome == "deferredNew" {
        let content = try AgentTaskContent(
            text: "first complete", stage: .completed, writerEvent: .init(sequence: 1, kind: .completed))
        let old = try await fixtureWriterCompletion(
            content, scope: request.scope, status: .succeeded, tasks: database.writerExecutions)
        #expect(try await context.snapshot().state.taskViews?[request.scope.id]?.terminal == false)
        _ = try await port.sendResult(old.signal.message(), parent: received, to: .assistant)
        try await database.writerExecutions.finishTaskNotification(
            request.scope.id, agent: "writer", retirement: true, completed: true, failure: nil)
        await model.delegateAgain()
        try await assistant.receive(.init(id: UUID().uuidString, sessionID: session, payload: .text("继续或开始下一项任务")))
        try await skillEventually { await child.inputs.count == 2 }
        let nextInput = try #require(await child.inputs.last)
        guard case .observation(let message) = nextInput.payload,
            let next = message.content(as: AgentTaskSignal.self)
        else { throw CommunicationError.invalidPayload }
        #expect(next.scope.id != request.scope.id)
        #expect(try await context.snapshot().state.taskViews?[request.scope.id]?.terminal == true)
        #expect(try await context.snapshot().tasks.task(request.scope.id)?.state == .succeeded)
        // Even an old completion that arrives after the new delegation cannot overwrite it.
        #expect(try await port.sendResult(old.message, parent: received, to: .assistant).rejected.isEmpty)
        #expect(try await port.sendResult(old.message, parent: received, to: .assistant).rejected.isEmpty)
        #expect(try await context.snapshot().state.taskViews?[next.scope.id]?.terminal == false)
        let final = try await fixtureWriterCompletion(
            AgentTaskContent(
                text: "second complete", stage: .completed, writerEvent: .init(sequence: 1, kind: .completed)),
            scope: next.scope, status: .succeeded, tasks: database.writerExecutions)
        _ = try await port.sendResult(final.signal.message(), parent: nextInput, to: .assistant)
        _ = try await port.sendResult(final.message, parent: nextInput, to: .assistant)
        let expected = 4
        let deadline = ContinuousClock.now + .seconds(10)
        while await log.finishedDecisions.count < expected && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let state = try await context.snapshot()
        let decisionCount = await log.finishedDecisions.count
        let outputFailure = await log.failure ?? "none"
        let controls = await log.values.compactMap {
            if case .control(let text) = $0.output { return text }
            return nil
        }
        #expect(
            decisionCount == expected,
            Comment(
                rawValue:
                    "count=\(decisionCount) work=\(state.work.values.map { $0.state }) errors=\(state.state.history.current.turns.map { $0.error ?? "none" }) output=\(outputFailure) controls=\(controls)"
            ))
        #expect(
            try await database.writerExecutions.taskNotification(request.scope.id, agent: "writer")?.delivered == true)
        if foreground {
            _ = try await assistant.controlTask(
                "task.cancel", arguments: ["reason": "test cleanup"],
                source: "assistant", sessionID: session, inputID: UUID().uuidString, decisionID: nil)
        }
        _ = try await history.startNew()
        await assistant.stop()
        try await collection.value
        await child.stop()
        await speech.stop()
        await output.shutdown()
        try await database.shutdown()
        return
    }
    if outcome == "closed", !foreground {
        try await assistant.receive(AssistantSessionControl.cancelSession.input(sessionID: session))
        #expect(await child.inputs.count == 1)
    }
    if outcome == "switched", !foreground { _ = try await history.startNew() }
    let peerScope = AgentTaskScope(
        id: UUID().uuidString, requester: .assistant, executor: .memory, sessionID: session)
    if outcome == "peerReply", !foreground {
        try await context.update { try $0.tasks.register(peerScope) }
        let peerProgress = try AgentTaskContent(text: "Peer is still speaking").signal(.progress, scope: peerScope)
        try await assistant.receive(writerFixturePeerInput(peerProgress))
    }
    if foreground { try await assistant.pause() }
    if outcome == "completionFacts", !foreground { await playbackGate.arm() }
    if outcome == "coalesced" {
        if !foreground { try await assistant.pause() }
        for number in 1...100 {
            let content = try AgentTaskContent(
                text: "步骤\(number)", writerEvent: .init(sequence: UInt64(number), kind: .progress))
            let receipt = try await port.sendResult(
                content.signal(.progress, scope: request.scope).message(), parent: received, to: .assistant)
            #expect(receipt.rejected.isEmpty)
        }
        #expect(try await context.snapshot().state.taskViews?[request.scope.id]?.writerEvent?.sequence == 100)
        #expect(try await context.snapshot().work.values.filter { $0.state == .queued }.isEmpty)
        try await assistant.receive(.init(id: UUID().uuidString, sessionID: session, payload: .text("先聊一下天气")))
        let content = try AgentTaskContent(
            text: "图已保存", stage: .completed, artifactID: "project", writerEvent: .init(sequence: 101, kind: .completed))
        let done = try await fixtureWriterCompletion(
            content, scope: request.scope, status: .succeeded, tasks: database.writerExecutions)
        #expect(try await port.sendResult(done.message, parent: received, to: .assistant).rejected.isEmpty)
        #expect(try await port.sendResult(done.signal.message(), parent: received, to: .assistant).rejected.isEmpty)
        try await assistant.resume()
        try await skillEventually { await log.finishedDecisions.count == 3 }
        #expect(await model.requests.count == 4)
        let prompts = await model.requests.map { $0.messages.last?.content ?? "" }
        #expect(prompts[2].contains("先聊一下天气"))
        #expect(prompts[3].contains("图已保存"))
        #expect(!prompts.contains { $0.contains("步骤100") })
        if foreground {
            _ = try await assistant.controlTask(
                "task.cancel", arguments: ["reason": "cleanup"], source: "assistant", sessionID: session,
                inputID: UUID().uuidString, decisionID: nil)
        }
        await assistant.stop()
        try await collection.value
        await child.stop()
        await speech.stop()
        await output.shutdown()
        try await database.shutdown()
        return
    }
    if outcome == "liveProgress" {
        if foreground { try await assistant.resume() }
        func sendStep(_ number: Int) async throws {
            let content = try AgentTaskContent(
                text: "实时步骤\(number)", writerEvent: .init(sequence: UInt64(number), kind: .progress))
            let receipt = try await port.sendResult(
                content.signal(.progress, scope: request.scope).message(), parent: received, to: .assistant)
            #expect(receipt.rejected.isEmpty)
        }
        try await sendStep(1)
        try await skillEventually { await log.finishedDecisions.count == 2 }
        let first = ContinuousClock.now
        for number in 2...20 { try await sendStep(number) }
        try await assistant.receive(.init(id: UUID().uuidString, sessionID: session, payload: .text("插入用户问题")))
        try await skillEventually { await log.finishedDecisions.count == 3 }
        #expect(await model.requests.count == 4)
        try await Task.sleep(for: .seconds(1))
        #expect(await log.finishedDecisions.count == 3)
        let deadline = first + .seconds(25)
        while await log.finishedDecisions.count < 4 {
            guard ContinuousClock.now < deadline else { throw CommunicationError.invalidPayload }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(first.duration(to: .now) >= .seconds(8))
        let prompts = await model.requests.map { $0.messages.last?.content ?? "" }
        #expect(prompts.count == 5)
        #expect(prompts[2].contains("实时步骤1"))
        #expect(prompts[3].contains("插入用户问题"))
        #expect(prompts[4].contains("实时步骤20"))
        if foreground {
            _ = try await assistant.controlTask(
                "task.cancel", arguments: ["reason": "cleanup"], source: "assistant", sessionID: session,
                inputID: UUID().uuidString, decisionID: nil)
        }
        await assistant.stop()
        try await collection.value
        await child.stop()
        await speech.stop()
        await output.shutdown()
        try await database.shutdown()
        return
    }
    let question = try AgentTaskContent(
        text: "需要颜色", stage: ["started", "progress"].contains(outcome) ? .running : .waitingUser,
        interactionID: ["started", "progress"].contains(outcome) ? nil : UUID().uuidString,
        writerEvent: .init(
            sequence: 1, kind: outcome == "started" ? .started : outcome == "progress" ? .progress : .userInput))
    let progress = try question.signal(.progress, scope: request.scope)
    let receipt = try await port.sendResult(progress.message(), parent: received, to: .assistant)
    #expect(receipt.rejected.isEmpty)
    let duplicate = try await port.sendResult(progress.message(), parent: received, to: .assistant)
    #expect(duplicate.rejected.isEmpty)
    if outcome == "peerReply", !foreground {
        #expect(await model.requests.count == 2)
        let peerDone = try AgentTaskContent(text: "Peer playback drained", stage: .completed).signal(
            .result, scope: peerScope, status: .succeeded)
        try await assistant.receive(writerFixturePeerInput(peerDone))
    }
    if outcome == "completionFacts", !foreground {
        try await skillEventually { await playbackGate.entered }
        #expect(await log.reportCompletions.isEmpty)
        await playbackGate.open()
    }
    if outcome == "playback", !foreground {
        #expect(await model.requests.count == 2)
        #expect(try await context.snapshot().work[try #require(question.writerEvent?.eventID)]?.state == .queued)
        await playbackGate.open()
    }
    try await assistant.receive(.init(id: UUID().uuidString, sessionID: session, payload: .text("先聊一下天气")))
    let fillers = foreground ? 30 : 0
    for index in 0..<fillers {
        try await assistant.receive(.init(id: UUID().uuidString, sessionID: session, payload: .text("排队消息 \(index)")))
    }
    let completion = try AgentTaskContent(
        text: outcome.hasPrefix("failed") ? "创作失败，草稿已保留" : "图已保存", stage: .completed, artifactID: "project",
        writerEvent: .init(
            sequence: 2, kind: outcome.hasPrefix("failed") ? .failed : .completed,
            failure: outcome == "failedDiagnostic"
                ? .init(
                    category: "modelHTTP", code: "writer.http.400", stage: "控制请求",
                    message: String(repeating: "参数错误🌍", count: 200),
                    details: ["httpStatus": "400", "providerMessage": String(repeating: "参数错误🌍", count: 200)]) : nil))
    let completed = try await fixtureWriterCompletion(
        completion, scope: request.scope,
        status: outcome.hasPrefix("failed") ? .failed : .succeeded, tasks: database.writerExecutions)
    let evidence = completed.message
    if foreground {
        #expect(!(try await port.sendResult(evidence, parent: received, to: .assistant)).rejected.isEmpty)
        #expect(
            try await context.snapshot().state.taskViews?[request.scope.id]?.writerEvent?.kind
                == question.writerEvent?.kind)
        try await assistant.resume()
    }
    #expect(try await port.sendResult(evidence, parent: received, to: .assistant).rejected.isEmpty)
    let result = completed.signal
    #expect(try await port.sendResult(result.message(), parent: received, to: .assistant).rejected.isEmpty)
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while await log.finishedDecisions.count < 4 + fillers,
        ContinuousClock.now < deadline
    {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await log.failure == nil)
    let workerState = try await context.snapshot().work.values.map { $0.state.rawValue }
    let transportFailure = await log.failure ?? "none"
    try #require(
        await log.finishedDecisions.count == 4 + fillers,
        "States: \(workerState); transport: \(transportFailure)")
    #expect(try await context.snapshot().state.taskViews?[request.scope.id]?.terminal == true)
    #expect(try await context.snapshot().state.skillState?.activeTaskID == priorTask)
    if foreground {
        _ = try await assistant.controlTask(
            "task.cancel", arguments: ["reason": "test cleanup"], source: "assistant", sessionID: session,
            inputID: UUID().uuidString, decisionID: nil)
    }
    let archivedDialog = try #require(try await history.startNew()).id
    await assistant.stop()
    try await collection.value
    let outputs = await log.values
    let observed = String(describing: outputs.map(\.output))
    #expect(await log.finishedDecisions.count == 4 + fillers, "\(observed)")
    if outcome == "completionFacts" {
        let completed = await log.reportCompletions
        #expect(completed.contains { $0.completedReportID == question.writerEvent?.eventID })
        #expect(completed.contains { $0.completedReportID == completion.writerEvent?.eventID })
        #expect(completed.allSatisfy { $0.reportStartedAt != nil })
    }
    try #require(await model.requests.count == 5 + fillers + (outcome == "failedRetry" ? 1 : 0))
    let prompts = await model.requests.map { $0.messages.last?.content ?? "" }
    #expect(prompts[2].contains("需要颜色"))
    #expect(prompts[3].contains("先聊一下天气"))
    #expect(prompts.contains { $0.contains(outcome.hasPrefix("failed") ? "创作失败" : "图已保存") })
    if outcome == "failedRetry" {
        #expect(try await database.writerExecutions.delegationCount() == 1)
        #expect(try await database.writerExecutions.tasks(agent: "writer", before: nil, limit: 50).isEmpty)
        #expect(prompts.last?.contains("Await new user input") == true)
    }
    if outcome == "failedDiagnostic" {
        let projected = try #require(prompts.first { $0.contains("code=writer.http.400") })
        #expect(projected.utf8.count <= 4096 && projected.contains("Observation truncated"))
        #expect(projected.contains("httpStatus=400"))
    }
    #expect(try await context.snapshot().state.taskViews?[request.scope.id]?.artifactID == "project")
    #expect(
        !outputs.contains {
            if case .actionCall(let call) = $0.output {
                return call.actionPath.function == "startTask" && call.parameters["execution"] != "background"
            }
            return false
        })
    await child.stop()
    await speech.stop()
    await output.shutdown()
    try await database.shutdown()
    let reopened = try SQLiteRepositories(url: databaseURL)
    let restored = AssistantHistoryStore(
        records: try AssistantRecordStore(
            repository: reopened.assistantMessages, tasks: reopened.assistantTasks,
            conversations: reopened.assistantConversations, logs: reopened.logs))
    let dialogID = archivedDialog
    var position: UInt64 = 0
    var eventTurns: [AssistantRecord] = []
    repeat {
        let page = try await restored.page(dialogID, after: position)
        for turn in page.turns where turn.user.contains("Writer task facts") {
            let messageID = try #require(turn.modelRequests?.first?.messageID)
            eventTurns += try await restored.message(messageID).turns
        }
        guard let next = page.nextPosition else { break }
        position = next
    } while true
    #expect(eventTurns.count == (outcome == "failedRetry" ? 3 : 2))
    #expect(
        eventTurns.allSatisfy {
            $0.user.contains("agent=writer") && !$0.user.contains("eventID=") && !$0.user.contains("delegateID=")
        })
    #expect(
        eventTurns.flatMap { $0.modelRequests ?? [] }.allSatisfy {
            $0.historyTaskID == nil && $0.decisionMetadata?.mode == "writer.event"
        })
    try await reopened.shutdown()
}

private actor WriterNoticeModel: ChatCapability {
    var delegate: Bool
    var retryFailed: Bool
    var retryRejected: Bool
    var cancellationTask: String?
    func cancel(_ taskID: String) { cancellationTask = taskID }
    init(delegate: Bool = false, retryFailed: Bool = false, retryRejected: Bool = false) {
        self.delegate = delegate
        self.retryFailed = retryFailed
        self.retryRejected = retryRejected
    }
    func delegateAgain() { delegate = true }
    nonisolated let availability: CapabilityAvailability = .available
    nonisolated let supportsToolCalls = true
    var requests: [ChatRequest] = []
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        requests.append(request)
        let pair = InferenceSession<ChatEvent>.make(limits: try .init(), estimatedBytes: { $0.estimatedBytes })
        if retryRejected, requests.count == 2 {
            retryRejected = false
            delegate = true
        }
        if retryFailed, request.messages.last?.content.contains("type=failed") == true {
            retryFailed = false
            delegate = true
        }
        if cancellationTask != nil {
            cancellationTask = nil
            try pair.emitter.yield(
                .text("<task.cancel agent_id=\"writer\" reason=\"User cancelled\"/>"))
            try pair.emitter.yield(.finished(.stop))
        } else if delegate {
            delegate = false
            #expect(request.tools.isEmpty)
            try pair.emitter.yield(.text("<task.delegate agent_id=\"writer\" description=\"绘制蓝色流程图\"/>"))
            try pair.emitter.yield(.finished(.stop))
        } else {
            try pair.emitter.yield(.text("收到，我来向你说明。"))
            try pair.emitter.yield(.finished(.stop))
        }
        pair.emitter.finish()
        return pair.session
    }
}

private actor WriterOutputLog {
    var failure: String?
    func failed(_ error: String) { failure = error }
    var values: [OutputEnvelope] = []
    func append(_ envelope: OutputEnvelope) { values.append(envelope) }
    var finishedDecisions: [OutputEnvelope] {
        // Facts have their own agent.finished and travel on an independent reader.
        // Successful model decisions always pass a round boundary first.
        let decisionIDs = Set(
            values.compactMap { value -> String? in
                guard case .roundFinished = value.output else { return nil }
                return value.inputID
            })
        return values.filter { $0.output == .control("agent.finished") && decisionIDs.contains($0.inputID) }
    }
    var reportCompletions: [ReplyActivity] {
        values.compactMap {
            guard case .communication(let call) = $0.output,
                let fact = call.message.content(as: ReplyActivity.self), fact.completedReportID != nil
            else { return nil }
            return fact
        }
    }
}

/// The Action completes only when the fixture's physical-playback boundary opens.
private actor WriterReplyPlaybackGate {
    var blocked: Bool
    var entered = false
    private let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    init(blocked: Bool) { self.blocked = blocked }
    func wait() async {
        guard blocked else { return }
        entered = true
        for await _ in release.stream { break }
    }
    func arm() { blocked = true }
    func open() {
        blocked = false
        release.continuation.yield(())
        release.continuation.finish()
    }
}

private func writerFixturePeerInput(_ signal: AgentTaskSignal) throws -> AgentInput {
    let payload = InputPayload.observation(try signal.message())
    return AgentInput(
        id: UUID().uuidString, sessionID: signal.scope.sessionID, payload: payload,
        metadata: InputMetadata(
            payload: payload, source: "memory", incarnation: "fixture-memory", origin: .agent,
            rootID: signal.scope.id))
}

@Test(.actionCatalog) func assistantPhotographyForegroundTasksPersistThroughSQLite() async throws {
    try await photographyAcceptance(live: false, persistent: true)
}

@Test(.actionCatalog) func consecutiveForegroundStartsJoinCleanupAndNeverNest() async throws {
    let database = try SQLiteRepositories.temporary()
    let history = AssistantHistoryStore(
        records: try AssistantRecordStore(
            repository: database.assistantMessages, tasks: database.assistantTasks,
            conversations: database.assistantConversations, logs: database.logs))
    let context = try AgentContextRepository(
        agent: AgentID.assistant, scope: UUID().uuidString, state: AssistantContextState())
    let assistant = try AssistantAgent(
        stateContext: try publicStateFixture(), chat: SkillModel(mediaID: "unused"),
        conversations: history, context: context)
    try await assistant.start()
    let session = UUID().uuidString
    _ = try await assistant.controlTask(
        "task.start", arguments: ["description": "first"], source: "assistant", sessionID: session,
        inputID: UUID().uuidString, decisionID: nil)
    let first = try #require(try await context.snapshot().state.skillState?.activeTaskID)
    await #expect(throws: CommunicationError.unavailableTarget) {
        try await assistant.controlTask(
            "task.start", arguments: ["description": "must not begin"], source: "assistant", sessionID: session,
            inputID: UUID().uuidString, decisionID: nil,
            beforeSuperseding: { throw CommunicationError.unavailableTarget })
    }
    #expect(try await context.snapshot().state.skillState?.activeTaskID == first)
    _ = try await assistant.controlTask(
        "task.start", arguments: ["description": "second"], source: "assistant", sessionID: session,
        inputID: UUID().uuidString, decisionID: nil,
        beforeSuperseding: {
            let current = try await context.snapshot().state.skillState?.activeTaskID
            #expect(current == first)
        })
    let second = try #require(try await context.snapshot().state.skillState?.activeTaskID)
    #expect(second != first)
    _ = try await assistant.controlTask(
        "task.start", arguments: ["description": "third"], source: "assistant", sessionID: session,
        inputID: UUID().uuidString, decisionID: nil)
    let tasks = try #require(try await context.snapshot().state.skillState?.tasks)
    #expect(tasks.count == 3)
    #expect(tasks.prefix(2).allSatisfy { $0.status == "cancelled" })
    #expect(tasks.last?.goal == "third" && tasks.last?.status == "running")
    await assistant.stop()
    try await database.shutdown()
}

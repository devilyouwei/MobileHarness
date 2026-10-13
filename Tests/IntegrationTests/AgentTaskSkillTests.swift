import Actions
import AgentCore
import AppWorkflows
import BehaviorAssembly
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
@_spi(ModelManagement) import ModelKit
import ModelKitOpenAI
import StorageChat
import Testing

@testable import Agents

@Test(.actionCatalog) func skillTransitionsAreAtomicAndCatalogsStayImmutable() throws {
    let fixedCapabilities = try AssistantAgent.runtimeCapabilities(
        AgentConfigurations.load(named: "Assistant").capabilities)
    var state = AgentTaskSkillState()
    try state.initialize(fixed: fixedCapabilities, baseSkills: try AgentConfigurations.baseSkills(named: "Assistant"))
    let old = try state.registry(fixed: fixedCapabilities)
    let input = UUID()
    _ = try state.control(
        "startTask", arguments: ["skills": "[\"photography\"]", "goal": "拍照"], inputID: input, fixed: fixedCapabilities)
    #expect(!old.actions.contains { $0.alias == "takePhoto" })
    #expect(try state.registry(fixed: fixedCapabilities).actions.contains { $0.alias == "takePhoto" })
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let encoded = try encoder.encode(state)
    #expect(throws: (any Error).self) {
        try state.control(
            "startTask", arguments: ["skills": "[\"history-query\"]", "goal": "另一个任务"], inputID: UUID(),
            fixed: fixedCapabilities)
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
    try state.roundCompleted(failed: false, fixed: fixedCapabilities)
    #expect(state.tasks.last?.status == "waitingUser")
    let task = try #require(state.activeTaskID)
    _ = try state.control("finishTask", arguments: ["summary": "已保存"], inputID: input, fixed: fixedCapabilities)
    #expect(state.activeTaskID == task && state.mode == "task")
    try state.roundCompleted(failed: false, fixed: fixedCapabilities)
    #expect(state.activeTaskID == nil && state.mode == "default" && state.tasks.last?.status == "completed")
    #expect(state.events.contains { $0.operation == "release" && $0.skill == "photography" && $0.taskID == task })
    #expect(throws: CommunicationError.scopeClosed) { try state.bind(UUID(), task: task) }
}

@Test(.actionCatalog) func foregroundTasksCanRestartOnlyAfterClosure() throws {
    let fixed = try AssistantAgent.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities)
    var state = AgentTaskSkillState()
    try state.initialize(fixed: fixed, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    let input = UUID()
    _ = try state.control(
        "startTask", arguments: ["goal": "旧目标", "skills": "[\"photography\"]"], inputID: input, fixed: fixed)
    let first = try #require(state.activeTaskID)
    try state.roundCompleted(failed: false, fixed: fixed)
    #expect(state.tasks.last?.status == "waitingUser")
    _ = try state.control("finishTask", arguments: ["summary": "用户改为新目标，旧目标未完成"], inputID: input, fixed: fixed)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let closing = try encoder.encode(state)
    #expect(throws: CommunicationError.invalidPayload) {
        try state.control("startTask", arguments: ["goal": "新目标"], inputID: input, fixed: fixed)
    }
    #expect(try encoder.encode(state) == closing)
    try state.roundCompleted(failed: false, fixed: fixed)
    #expect(state.activeTaskID == nil)
    _ = try state.control(
        "startTask", arguments: ["goal": "后置镜头拍照", "skills": "[\"photography\"]"], inputID: input, fixed: fixed)
    let second = try #require(state.activeTaskID)
    #expect(first != second && state.taskID(for: input) == second)
    #expect(state.tasks.first?.summary == "用户改为新目标，旧目标未完成")
    _ = try state.control("finishTask", arguments: ["summary": "已保存"], inputID: input, fixed: fixed)
    try state.roundCompleted(failed: false, fixed: fixed)
    _ = try state.control(
        "startTask", arguments: ["goal": "再拍一张", "skills": "[\"photography\"]"], inputID: UUID(), fixed: fixed)
    #expect(state.tasks.count == 3 && state.activeTaskID != second)
}

@Test(.actionCatalog) func allBundledSkillsHaveValidBoundedEffectiveCatalogs() throws {
    let fixedCapabilities = try AssistantAgent.runtimeCapabilities(
        AgentConfigurations.load(named: "Assistant").capabilities)
    for skill in ["photography", "history-query", "application-control"] {
        var state = AgentTaskSkillState()
        try state.initialize(
            fixed: fixedCapabilities, baseSkills: try AgentConfigurations.baseSkills(named: "Assistant"))
        _ = try state.control(
            "startTask", arguments: ["skills": "[\"\(skill)\"]", "goal": "fixture"], inputID: UUID(),
            fixed: fixedCapabilities)
        let registry = try state.registry(fixed: fixedCapabilities)
        let paths = registry.actions.map { $0.path.description } + registry.tools.map(\.path)
        #expect(Set(paths).count == paths.count)
        #expect(registry.tools.allSatisfy { !$0.path.hasSuffix(".send") })
        state.recover()
        #expect(state.activeTaskID == nil && state.mode == "default" && state.tasks.last?.status == "interrupted")
    }
    // No static business grant: loading the Skill is sufficient for Actions and native Tools.
    let fixed = try CapabilityRegistry()
    var state = AgentTaskSkillState()
    try state.initialize(fixed: fixed, baseSkills: [])
    let before = try state.registry(fixed: fixed)
    #expect(throws: GenerationError.unknownCapability) { try before.resolveAction("takePhoto", parameters: [:]) }
    _ = try state.control(
        "startTask", arguments: ["skills": "[\"photography\",\"history-query\"]", "goal": "fixture"],
        inputID: UUID(), fixed: fixed)
    let loaded = try state.registry(fixed: fixed)
    #expect(try loaded.resolveAction("takePhoto", parameters: [:]).actionPath.description == "Camera.Capture.takePhoto")
    #expect(loaded.tools.contains { $0.path == "History.Conversation.read" })
    #expect(!before.actions.contains { $0.alias == "takePhoto" })

}

private actor SkillModel: ChatCapability {
    nonisolated let availability: CapabilityAvailability = .available
    nonisolated let supportsImages: Bool
    nonisolated let supportsToolCalls = true
    let photoID: UUID
    let rejectFirst: Bool
    let replaceForeground: Bool
    let captureOnly: Bool
    private(set) var requests: [ChatRequest] = []
    init(
        photoID: UUID, rejectFirst: Bool = false, replaceForeground: Bool = false, captureOnly: Bool = false,
        supportsImages: Bool = false
    ) {
        self.supportsImages = supportsImages
        self.photoID = photoID
        self.rejectFirst = rejectFirst
        self.replaceForeground = replaceForeground
        self.captureOnly = captureOnly
    }
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        requests.append(request)
        let output: String
        if captureOnly {
            switch requests.count {
            case 1: output = "<loadSkills skills='[\"photography\"]'/>"
            case 2: output = "<openCamera/>"
            case 3: output = "<takePhoto/>"
            default: output = "拍好了。"
            }
        } else if replaceForeground && requests.count >= 4 {
            switch requests.count {
            case 4: output = "<finishTask summary=\"用户切换目标，旧照片未保存\" continueDecision=\"true\"/>"
            case 5: output = "<startTask goal=\"新拍照目标\" skills='[\"photography\"]'/>"
            case 6: output = "<takePhoto/>"
            default: output = "新照片需要保存吗？"
            }
        } else {
            switch requests.count - (rejectFirst ? 1 : 0) {
            case 0: output = "<photography/>"
            case 1: output = "<startTask goal=\"拍照 fixture\" skills='[\"photography\"]'/>"
            case 2: output = "<takePhoto/>"
            case 3: output = "需要保存吗？"
            case 4: output = "<savePhoto photoID=\"\(photoID)\"/>"
            case 5: output = "<finishTask summary=\"照片已保存\"/>"
            case 6: output = "<startTask goal=\"再拍一张 fixture\" skills='[\"photography\"]'/>"
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
    private(set) var currentPhoto: UUID?
    private var cameraSequence: UInt64 = 1
    func nextCameraSequence() -> UInt64 {
        cameraSequence += 1
        return cameraSequence
    }
    func newPhoto() -> UUID {
        let id = UUID()
        currentPhoto = id
        return id
    }
    func resolvePhoto(_ id: UUID?, discard: Bool) throws {
        guard id != nil && id == currentPhoto else { throw CommunicationError.invalidPayload }
        if discard { currentPhoto = nil }
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
    captureOnly: Bool = false, supportsImages: Bool = false
)
    async throws
{
    let photo = UUID()
    let session = UUID()
    let stub = SkillModel(
        photoID: photo, rejectFirst: rejectFirst, replaceForeground: replaceForeground, captureOnly: captureOnly,
        supportsImages: supportsImages)
    let model: any ChatCapability
    if live {
        let key = try #require(ProcessInfo.processInfo.environment["OPENAI_API_KEY"])
        model = try LiveTextChat(key: key)
    } else {
        model = stub
    }
    let context = AgentContextRepository(agent: AgentID.assistant, scope: UUID(), state: AssistantContextState())
    let store = ConversationHistoryStore()
    let agent = try AssistantAgent(
        chat: model, conversations: store,
        observations: { values, input, chat in
            try await AssistantContextBuilder.photoObservations(
                values, input: input, chat: chat,
                read: { id, _ in try ChatImage(id: id, data: Data([1])) })
        }, context: context)
    _ = try await bindSpeechRequests(agent)
    let manager = AgentManager()
    try await manager.register(agent)
    let input = InputGateway(manager: manager, allowsExternalSend: true)
    let effects = SkillEffects()
    let definitions = [
        "Camera.Capture.takePhoto", "Camera.Capture.savePhoto", "Camera.Capture.ignorePhoto", "Camera.Capture.open",
        "Camera.Capture.close", "Camera.Capture.flip", "Camera.Capture.retry", "NexArm.Gesture.nodHead",
        "NexArm.Gesture.waveWrist", "UI.Caption.beginReplyTurn", "UI.Caption.print",
        "Speech.Playback.speak", "UI.Expression.express", "System.Device.readEnvironment",
    ].map { path in
        let parts = path.split(separator: ".").map(String.init)
        return ActionBinding(
            path: .init(domain: parts[0], module: parts[1], function: parts[2]), displayName: path,
            kind: .finite, completion: "Synthetic confirmed effect",
            completing: { invocation in
                if path == "System.Device.readEnvironment" {
                    return .value(
                        "Synthetic device fixture: App foreground; camera enabled and ready; facing front; robot arm connected with clear space. No physical device effect is being tested."
                    )
                }
                await effects.performed(path)
                if path.hasPrefix("Camera.") {
                    await effects.capture(invocation.context.source)
                    if path == "Camera.Capture.close" || path == "Camera.Capture.open" {
                        let enabled = path == "Camera.Capture.open"
                        if live {
                            try await agent.receive(
                                CameraStateObservation(
                                    sequence: await effects.nextCameraSequence(), enabled: enabled, visible: enabled,
                                    busy: false, needsSettings: false, facing: .front
                                ).input(sessionID: session))
                        }
                        return .value(
                            String(
                                decoding: try JSONEncoder().encode(
                                    CameraCommandReceipt(operation: enabled ? "open" : "close", enabled: enabled)),
                                as: UTF8.self))
                    }
                    let id: UUID
                    let captureCount = await effects.paths.filter { $0 == "Camera.Capture.takePhoto" }.count
                    if path == "Camera.Capture.takePhoto" && (live || captureCount > 1) {
                        id = await effects.newPhoto()
                    } else if live && ["Camera.Capture.savePhoto", "Camera.Capture.ignorePhoto"].contains(path) {
                        id = try #require(invocation.call.parameters["photoID"].flatMap(UUID.init(uuidString:)))
                        try await effects.resolvePhoto(id, discard: path == "Camera.Capture.ignorePhoto")
                    } else {
                        id = photo
                    }
                    if live && ["Camera.Capture.savePhoto", "Camera.Capture.ignorePhoto"].contains(path) {
                        return .value(
                            String(
                                decoding: try JSONEncoder().encode(
                                    CameraPhotoCommandReceipt(
                                        photoID: id, state: path == "Camera.Capture.savePhoto" ? .saved : .ignored)),
                                as: UTF8.self))
                    }
                    return .value(
                        String(
                            decoding: try JSONEncoder().encode(
                                CameraPhotoReceipt(photoID: id, width: 640, height: 480)), as: UTF8.self))
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
    let scheduler = ChannelScheduler(
        registry: try ActionRegistry(modules: [
            Module(definitions: definitions + controlBindings)
        ])
    ) {
        await input.deliverActionResult($0)
    }
    let history = HistoryModule(
        history: HistoryQueryService(store: store),
        mutations: HistoryMutationService(
            store: store, summarizeTitle: { try await ConversationTitleGenerator.summarize($0, using: model) }))
    let tools = try BehaviorAssembly(capabilityModules: [controls, history]).tools
    let gateway = OutputGateway(
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
    if live && cameraFacts {
        try await agent.receive(
            CameraStateObservation(
                sequence: 1, enabled: true, visible: true, busy: false, needsSettings: false, facing: .front
            ).input(sessionID: session))
    }
    let first = AgentInput(
        sessionID: session,
        payload: .text(captureOnly ? "可以帮我拍张照吗，但是不需要后续操作" : (live ? "你好，帮我拍张照。" : "拍照 fixture")))
    _ = try await input.send(first, to: .assistant)
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
        #expect(requests.last?.messages.contains { $0.content.contains(photo.uuidString) } == true)
        #expect(requests.last?.messages.contains { $0.images?.contains { $0.id == photo } == true } == supportsImages)
        #expect(history.modelRequests?.allSatisfy { $0.decisionMetadata?.taskID == nil } == true)
        #expect(
            await effects.paths.filter { $0.hasPrefix("Camera.") } == [
                "Camera.Capture.open", "Camera.Capture.takePhoto",
            ])
        #expect(
            !history.raw.contains("startTask") && !history.raw.contains("finishTask") && !history.raw.contains("保存"))
        await agent.stop()
        _ = try await pump.value
        await gateway.shutdown()
        await manager.stopAll()
        return
    }
    let active = try #require(try await context.snapshot().state.skillState?.activeTaskID)
    #expect(try await context.snapshot().state.skillState?.tasks.last?.status == "waitingUser")
    if live && run == 2 {
        _ = try await input.send(AgentInput(sessionID: session, payload: .text("重新拍一张。")), to: .assistant)
        try await skillEventually {
            let completed = await effects.completed
            let failures = await effects.failures
            return completed == 2 || failures.contains { $0.hasPrefix("agent.error:") }
        }
        let paths = await effects.paths
        let firstIgnore = try #require(paths.firstIndex(of: "Camera.Capture.ignorePhoto"))
        let secondCapture = try #require(paths.lastIndex(of: "Camera.Capture.takePhoto"))
        #expect(firstIgnore < secondCapture)
    }
    if replaceForeground {
        _ = try await input.send(AgentInput(sessionID: session, payload: .text("结束旧任务，再拍一张新照片")), to: .assistant)
        try await skillEventually { await effects.completed == 2 }
        let current = try await context.snapshot().state.skillState
        #expect(current?.activeTaskID != nil && current?.activeTaskID != active)
        #expect(current?.tasks.first?.status == "completed" && current?.tasks.first?.continueDecision == true)
        #expect(current?.tasks.last?.status == "waitingUser")
        #expect(await effects.failures.isEmpty)
        let requests = await stub.requests
        #expect(requests.count == 7)
        let transition = try #require(requests[4].messages.first { $0.content.hasPrefix("Task transition result") })
        #expect(
            transition.content.contains("\"mode\":\"default\"")
                && transition.content.contains("\"status\":\"completed\""))
        #expect(!transition.content.contains("\"photography\""))
        #expect(!requests[5].messages.contains { $0.content.contains(photo.uuidString) })
        await agent.stop()
        _ = try await pump.value
        await gateway.shutdown()
        await manager.stopAll()
        return
    }
    let ending = live && run == 1 ? "忽略这张照片，不要保存。" : "保存"
    let second = AgentInput(sessionID: session, payload: .text(ending))
    _ = try await input.send(second, to: .assistant)
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
    #expect(await effects.owners.count == (live && run == 2 ? 4 : 2))
    if live && run == 1 { #expect(await effects.paths.contains("Camera.Capture.ignorePhoto")) }
    let archive = try await store.snapshot()
    let requests = try #require(archive.current.turns.first?.modelRequests)
    let rounds = try #require(archive.current.turns.first?.generationRounds)
    #expect(rounds[rejectFirst ? 1 : 0].resultsJSON.contains("Agent.Task.startTask"))
    #expect(rounds.first?.resultsJSON.contains("\"protocol\":\"action\"") == true)
    #expect(rounds.contains { $0.resultsJSON.contains("Camera.Capture.takePhoto") })
    if live {
        let query = AgentInput(sessionID: session, payload: .text("只列出最近的对话标题，不要读取详情，不需要创建任务。"))
        _ = try await input.send(query, to: .assistant)
        try await skillEventually {
            let completed = await effects.completed
            return completed == (run == 2 ? 4 : 3)
        }
        let queried = try await store.snapshot()
        let queryRequests = try #require(queried.current.turns.last?.modelRequests)
        #expect(queryRequests.contains { $0.response.contains("<loadSkills") })
        #expect(
            queryRequests.contains { $0.toolCalls.contains { $0.name == "History.list" && $0.state == .completed } })
        #expect(try await context.snapshot().state.skillState?.loaded.contains("history-query") == false)
        #expect(await effects.failures == [])
        #expect(requests.contains { $0.response.contains("<startTask") })
        #expect(requests.contains { $0.decisionMetadata?.skills["photography"] != nil })
        if run == 0 {
            for (offset, command) in ["机械臂点一次头，不用说话。", "先说你好，再挥手一次。", "关闭摄像头。"].enumerated() {
                if offset == 2 {
                    try await agent.receive(
                        CameraStateObservation(
                            sequence: await effects.nextCameraSequence(), enabled: true, visible: true, busy: false,
                            needsSettings: false, facing: .front
                        ).input(sessionID: session))
                }
                _ = try await input.send(AgentInput(sessionID: session, payload: .text(command)), to: .assistant)
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
        #expect(requests[start].response.contains("<startTask"))
        #expect(requests[0].toolCalls.isEmpty)
        #expect(
            requests[start + 1].decisionMetadata?.taskID == active
                && requests[start + 1].decisionMetadata?.skills["photography"] == 16)
        #expect(archive.current.turns.last?.modelRequests?.count == 2)
        #expect(archive.current.turns.first?.generationRounds?.count == (rejectFirst ? 4 : 3))
        let calls = await stub.requests
        #expect(calls[0].messages.first?.content.contains("<takePhoto") == false)
        #expect(calls[start + 1].messages.first?.content.contains("<takePhoto") == true)
        #expect(calls[start + 1].messages.contains { $0.role == .assistant && $0.content.contains("<startTask") })
        #expect(calls[start + 1].messages.contains { $0.content.contains("Agent.Task.startTask") })
        // A later human input in the still-active Task keeps its entry round too.
        #expect(calls[start + 3].messages.contains { $0.role == .assistant && $0.content.contains("<startTask") })
        if !rejectFirst {
            _ = try await input.send(AgentInput(sessionID: session, payload: .text("再拍一张")), to: .assistant)
            try await skillEventually { await effects.completed == 3 }
            let restarted = try await context.snapshot().state.skillState
            #expect(restarted?.activeTaskID != nil && restarted?.activeTaskID != active)
            #expect(restarted?.tasks.count == 2 && restarted?.tasks.last?.status == "waitingUser")
            #expect(await effects.failures.isEmpty)
            let history = try await store.snapshot()
            #expect(history.current.turns.count == 3)
            let allRequests = await stub.requests
            #expect(allRequests[5].messages.contains { $0.content.contains("Task history") })
            #expect(!allRequests[5].messages.contains { $0.content.contains(photo.uuidString) })
            #expect(!allRequests[6].messages.contains { $0.content.contains(photo.uuidString) })
            #expect(allRequests[6].messages.contains { $0.content.contains("Task history") })
            #expect(history.current.turns.first?.modelRequests?.count == 3)
            #expect(history.current.turns.first?.modelRequests?.last?.requestJSON.contains(photo.uuidString) == true)

            #expect(history.current.turns.last?.modelRequests?.first?.decisionMetadata?.mode == "default")
            #expect(
                history.current.turns.last?.modelRequests?.last?.decisionMetadata?.taskID == restarted?.activeTaskID)
        }
    }
    await agent.stop()
    _ = try await pump.value
    await gateway.shutdown()
    await manager.stopAll()
}

@Test(.actionCatalog) func cancelledTaskRejectsLateASRInsteadOfCapturingNewTask() async throws {
    let fixedCapabilities = try AssistantAgent.runtimeCapabilities(
        AgentConfigurations.load(named: "Assistant").capabilities)
    var initial = AssistantContextState()
    var skills = AgentTaskSkillState()
    try skills.initialize(fixed: fixedCapabilities, baseSkills: try AgentConfigurations.baseSkills(named: "Assistant"))
    _ = try skills.control(
        "startTask", arguments: ["skills": "[\"photography\"]", "goal": "original"], inputID: UUID(),
        fixed: fixedCapabilities)
    initial.skillState = skills
    let context = AgentContextRepository(agent: AgentID.assistant, scope: UUID(), state: initial)
    let model = SkillModel(photoID: UUID())
    let agent = try AssistantAgent(chat: model, context: context)
    try await agent.start()
    let session = UUID()
    let turn = AgentTurn(ordinal: 1)
    try await agent.receive(.init(sessionID: session, payload: .observation(.speechPhase(.speaking)), turn: turn))
    try await context.update {
        var state = try #require($0.state.skillState)
        _ = try state.control(
            "cancelTask", arguments: ["reason": "cancelled"], inputID: UUID(), fixed: fixedCapabilities)
        try state.roundCompleted(failed: false, fixed: fixedCapabilities)
        _ = try state.control(
            "startTask", arguments: ["skills": "[\"history-query\"]", "goal": "new task"], inputID: UUID(),
            fixed: fixedCapabilities)
        $0.state.skillState = state
    }
    let current = try await context.snapshot().state.skillState?.activeTaskID
    await #expect(throws: CommunicationError.scopeClosed) {
        try await agent.receive(
            .init(sessionID: session, payload: .observation(.transcript("保存", final: true)), turn: turn))
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
    let repository = AgentContextRepository(
        agent: AgentID.assistant, scope: UUID(), state: initial,
        persistence: AgentContextPersistence(load: { nil }, commit: { _, _ in throw WriteFailure() }))
    await #expect(throws: WriteFailure.self) {
        try await repository.transaction {
            try $0.state.skillState?.control(
                "startTask", arguments: ["skills": "[\"photography\"]", "goal": "fixture"], inputID: UUID(),
                fixed: fixedCapabilities)
        }
    }
    let committed = try await repository.snapshot().state.skillState
    #expect(committed?.mode == "default" && committed?.activeTaskID == nil)
    #expect(try committed?.registry(fixed: fixedCapabilities).actions.contains { $0.path.domain == "Camera" } == false)
}

@Test(.actionCatalog) func trustedIdleControlsReuseTaskActionsWithoutStartingConversation() async throws {
    let context = AgentContextRepository(agent: AgentID.assistant, scope: UUID(), state: AssistantContextState())
    let model = SkillModel(photoID: UUID())
    let agent = try AssistantAgent(chat: model, context: context)
    try await agent.start()
    let session = UUID()
    _ = try await agent.controlTask(
        "startTask", arguments: ["skills": "[\"photography\"]", "goal": "fixed fixture"], source: "assistant",
        sessionID: session, inputID: UUID(), decisionID: nil)
    #expect(try await context.snapshot().state.skillState?.mode == "task")
    await #expect(throws: CommunicationError.unauthorized) {
        try await agent.controlTask(
            "cancelTask", arguments: ["reason": "spoofed"], source: "photographer", sessionID: session, inputID: UUID(),
            decisionID: nil)
    }
    _ = try await agent.controlTask(
        "cancelTask", arguments: ["reason": "fixed cancelled"], source: "assistant", sessionID: session,
        inputID: UUID(), decisionID: nil)
    #expect(try await context.snapshot().state.skillState?.tasks.last?.status == "cancelled")
    #expect(try await context.snapshot().state.skillState?.mode == "default")
    #expect(await model.requests.isEmpty)
    await agent.stop()
}

@Test(.actionCatalog) func temporarySkillsExpireAndTaskAdoptsOnlyItsDecisionChain() throws {
    let fixedCapabilities = try AssistantAgent.runtimeCapabilities(
        AgentConfigurations.load(named: "Assistant").capabilities)
    var state = AgentTaskSkillState()
    try state.initialize(fixed: fixedCapabilities, baseSkills: try AgentConfigurations.baseSkills(named: "Assistant"))
    let input = UUID()
    _ = try state.control(
        "loadSkills", arguments: ["skills": "[\"history-query\",\"photography\"]"], inputID: input,
        fixed: fixedCapabilities)
    #expect(try state.ownership("photography") == "decision")
    let snapshot = try state.registry(fixed: fixedCapabilities)
    try state.roundCompleted(failed: false, fixed: fixedCapabilities, inputID: UUID())
    #expect(state.loaded.contains("photography"))
    _ = try state.control("startTask", arguments: ["goal": "拍照并查询历史"], inputID: input, fixed: fixedCapabilities)
    #expect(try state.ownership("photography") == "task")
    #expect(state.temporaryInputID == nil)
    _ = try state.control(
        "releaseSkills", arguments: ["skills": "[\"photography\"]"], inputID: input, fixed: fixedCapabilities)
    #expect(!state.loaded.contains("photography"))
    #expect(snapshot.actions.contains { $0.alias == "takePhoto" })
    _ = try state.control("finishTask", arguments: ["summary": "完成"], inputID: input, fixed: fixedCapabilities)
    try state.roundCompleted(failed: false, fixed: fixedCapabilities, inputID: input)
    _ = try state.control(
        "loadSkills", arguments: ["skills": "[\"history-query\"]"], inputID: input, fixed: fixedCapabilities)
    try state.roundCompleted(failed: true, fixed: fixedCapabilities, inputID: input)
    #expect(state.loaded == ["basic-skill", "expression-interaction", "robot-interaction"])
    #expect(state.temporaryInputID == nil)
    #expect(throws: (any Error).self) {
        try state.control(
            "loadSkills", arguments: ["skills": "[\"history-query\",\"missing\"]"], inputID: input,
            fixed: fixedCapabilities)
    }
    #expect(state.loaded == ["basic-skill", "expression-interaction", "robot-interaction"])
}

@Test(.actionCatalog) func genericBackgroundCapacityAndLegacyRecoveryAreExplicit() throws {
    var registry = AgentTaskRegistry()
    let session = UUID()
    for _ in 0..<16 {
        try registry.register(
            AgentTaskScope(requester: .assistant, executor: .memory, sessionID: session, execution: .background))
    }
    #expect(throws: CommunicationError.capacityExceeded) {
        try registry.register(
            AgentTaskScope(requester: .assistant, executor: .memory, sessionID: session, execution: .background))
    }
    let cancelling = try #require(registry.records.first?.scope.id)
    try registry.delivered(cancelling, kind: .cancel, accepted: false)
    #expect(registry.task(cancelling)?.state == .requested)
    try registry.delivered(cancelling, kind: .cancel, accepted: true)
    #expect(registry.task(cancelling)?.state == .cancelling)
    registry.recover()
    #expect(registry.records.allSatisfy { $0.state == .interrupted })
    try registry.register(
        AgentTaskScope(requester: .assistant, executor: .memory, sessionID: session, execution: .background))
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
        "id": UUID().uuidString, "requester": "assistant", "executor": "memory", "sessionID": session.uuidString,
    ]
    let decodedScope = try JSONDecoder().decode(
        AgentTaskScope.self, from: JSONSerialization.data(withJSONObject: legacyScope))
    #expect(decodedScope.execution == .foreground)
    #expect(throws: CommunicationError.invalidPayload) {
        try AgentBackgroundTaskRequest(arguments: ["goal": "后台", "execution": "background"])
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) func backgroundTaskSendReportsNeverGrabForegroundOrInvokeChat()
    async throws
{
    let session = UUID()
    let context = AgentContextRepository(agent: AgentID.assistant, scope: UUID(), state: AssistantContextState())
    let model = SkillModel(photoID: UUID())
    let assistant = try AssistantAgent(
        chat: model, context: context,
        backgroundSupport: { target, contract, skills in
            guard target == .memory, contract == "demo.background", skills.isEmpty else {
                throw CommunicationError.unsupportedContract
            }
        })
    let child = ObservationRecorder(id: "memory")
    let configurations = try AgentConfigurations.all()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication,
        externalSources: [
            "user", "runtime", "phone.microphone", "phone.camera", "model.resources", "app.resources",
            "app.environment",
        ], configurations: configurations)
    let manager = AgentManager()
    try await manager.register(assistant, sessionID: session)
    try await manager.register(child, sessionID: session)
    let input = InputGateway(manager: manager, policy: policy)
    let output = OutputGateway(manager: manager, requests: input, tools: ToolRegistry(), policy: policy, sink: { _ in })
    try bindFixtureCommunications(assistant, port: await output.messaging(for: .assistant))
    try await assistant.start()
    await child.start()
    _ = try await assistant.controlTask(
        "startTask", arguments: ["goal": "继续拍摄", "skills": "[\"photography\"]"], source: "assistant",
        sessionID: session, inputID: UUID(), decisionID: nil)
    let before = try await context.snapshot().state.skillState
    let receipt = try await assistant.controlTask(
        "startTask",
        arguments: [
            "goal": "后台独立事务", "execution": "background", "target": "memory", "businessContract": "demo.background",
            "payload": "{}",
        ], source: "assistant", sessionID: session, inputID: UUID(), decisionID: nil)
    #expect(receipt.contains("not yet complete"))
    let received = try #require(await child.inputs.last)
    guard case .observation(let message) = received.payload else { throw CommunicationError.invalidPayload }
    let request = try #require(message.content(as: AgentTaskSignal.self))
    #expect(request.scope.execution == .background && request.scope.parentID == before?.activeTaskID)
    let (_, supplemental) = try AgentCommunicationAdapter.action(
        path: "Agent.Communication.send",
        arguments: [
            "target": "memory", "kind": "input", "content": "补充数据", "taskID": request.scope.id.uuidString,
            "businessContract": "demo.background", "payload": "{}",
        ],
        sender: .assistant, input: AgentInput(sessionID: session, payload: .text("补充")),
        policy: try #require(configurations.first { $0.agentID == .assistant }).communication, existing: request.scope)
    #expect(supplemental.scope == request.scope && supplemental.businessContract == "demo.background")

    #expect(try await context.snapshot().tasks.task(request.scope.id)?.state == .accepted)
    let port = try await output.messaging(for: .memory)
    let progress = try AgentTaskContent(text: "后台需要更多信息", stage: .waitingUser, interactionID: UUID()).signal(
        .progress, scope: request.scope)
    _ = try await port.sendResult(progress.message(), parent: received, to: .assistant)
    #expect(try await context.snapshot().state.skillState?.activeTaskID == before?.activeTaskID)
    #expect(try await context.snapshot().state.skillState?.loaded == before?.loaded)
    let result = try AgentTaskContent(text: "后台完成", stage: .completed).signal(
        .result, scope: request.scope, status: .succeeded)
    _ = try await port.sendResult(result.message(), parent: received, to: .assistant)
    #expect(try await context.snapshot().tasks.task(request.scope.id)?.state == .succeeded)
    #expect(try await context.snapshot().state.taskViews?[request.scope.id]?.goal == "后台独立事务")
    #expect(await model.requests.isEmpty)
    await assistant.stop()
    await child.stop()
    await output.shutdown()
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
            call: .init(actionPath: function.path, channel: "Control", parameters: [:]),
            context: .init(source: "assistant", sessionID: UUID(), inputID: UUID(), sequence: 0))
        #expect(
            try await FunctionExecutor.perform(invocation, definition: function)
                == .value(
                    "Committed \(function.path.function)"))
    }
}

@Test(.actionCatalog) func taskReportsExcludeRetainedLegacyHistoryAndUnrelatedSessions() throws {
    let session = UUID()
    var registry = AgentTaskRegistry()
    var views: [UUID: AgentTaskView] = [:]
    func add(_ scope: AgentTaskScope, terminal: Bool) throws {
        try registry.register(scope)
        views[scope.id] = AgentTaskView(scope: scope, content: try .init(text: scope.id.uuidString), terminal: terminal)
    }
    let legacy = AgentTaskScope(requester: .assistant, executor: .photographer, sessionID: session)
    let done = AgentTaskScope(requester: .assistant, executor: .memory, sessionID: session, execution: .background)
    let live = AgentTaskScope(requester: .assistant, executor: .memory, sessionID: session, execution: .background)
    let other = AgentTaskScope(requester: .assistant, executor: .memory, sessionID: UUID(), execution: .background)
    try add(legacy, terminal: true)
    try add(done, terminal: true)
    try add(live, terminal: false)
    try add(other, terminal: false)
    let input = AgentInput(sessionID: session, payload: .text("你好"))
    let templates = try AgentPrompts.load(named: "Assistant")
    let reports = try AgentChatContextBuilder.taskReports(
        views: views, tasks: registry, input: input, templates: templates)
    #expect(reports.contains(live.id.uuidString))
    #expect(!reports.contains(legacy.id.uuidString))
    #expect(!reports.contains(done.id.uuidString))
    #expect(!reports.contains(other.id.uuidString))
    #expect(
        try AgentChatContextBuilder.taskReports(views: [:], tasks: registry, input: input, templates: templates).isEmpty
    )
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
    #expect(basic.actions.contains { $0.alias == "startTask" })
    #expect(!basic.actions.contains { $0.alias == "send" })
    #expect(basic.actions.contains { $0.alias == "readEnvironment" })
    let identity = try AgentConfigurations.identityInstructions(named: "Assistant")
    #expect(!identity.contains("startTask") && !identity.contains("loadSkills"))
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
            "startTask",
            arguments: [
                "goal": "拍照", "skills": "[\"photography\"]", "execution": "foreground",
                "target": "photographer", "businessContract": "photography", "payload": "{}",
            ], inputID: UUID(), fixed: fixed)
    }
    #expect(try encoder.encode(state) == before)
    _ = try state.control(
        "startTask", arguments: ["goal": "拍照", "skills": "[\"photography\"]", "execution": "foreground"],
        inputID: UUID(), fixed: fixed)
    #expect(state.activeTaskID != nil && state.loaded.contains("photography"))
}

@Test(.actionCatalog) func unstartedAssistantRejectsInputWithoutEmittingRuntimeError() async throws {
    let agent = try AssistantAgent(chat: SkillModel(photoID: UUID()))
    await #expect(throws: HarnessError.notRunning) {
        try await agent.receive(AgentInput(sessionID: UUID(), payload: .text("startup input")))
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
    let input = UUID()
    _ = try state.control(
        "startTask", arguments: ["goal": "拍照", "skills": "[\"photography\"]"], inputID: input, fixed: fixed)
    let before = Date()
    try state.roundCompleted(failed: true, fixed: fixed, inputID: input, failure: "Capture denied by device")
    let saved = try JSONDecoder().decode(AgentTaskSkillState.self, from: JSONEncoder().encode(state))
    let task = try #require(saved.tasks.last)
    #expect(task.status == "failed" && task.failure == "Capture denied by device")
    #expect(try #require(task.updatedAt) >= before)
    #expect(saved.activeTaskID == nil && !saved.loaded.contains("photography"))
}

@Test(.actionCatalog) func applicationOperationsUseActionsAndQueriesRemainTools() throws {
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
        guard case .action(let parsedAlias, let parameters, let channel) = tokens[0] else {
            Issue.record("Expected a parsed Action")
            continue
        }
        #expect(
            try registry.resolveAction(parsedAlias, parameters: parameters, channel: channel).actionPath.description
                == path)
    }
    for alias in ["ModelResources.snapshot", "Provider.readSettings", "Bluetooth.readStatus"] {
        #expect(try registry.resolveTool(alias, arguments: [:]).toolPath.hasPrefix("System."))
        #expect(throws: GenerationError.unknownCapability) { try registry.resolveAction(alias, parameters: [:]) }
    }
    #expect(registry.actions.filter { $0.path.domain == "NexArm" }.count == 11)
    #expect(Set(registry.actions.map(\.path)).count == registry.actions.count)
}

@Test(.actionCatalog) func registeredCameraCallsDoNotRequireTaskOrPhotoOwner() throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    var skills = AgentTaskSkillState()
    try skills.initialize(fixed: config.capabilities, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    let input = AgentInput(sessionID: UUID(), payload: .text("拍张照，不要后续操作"))
    #expect(throws: GenerationError.unknownCapability) {
        try skills.registry(fixed: config.capabilities).resolveAction("takePhoto", parameters: [:])
    }
    _ = try skills.control(
        "loadSkills", arguments: ["skills": "[\"photography\"]"], inputID: input.id, fixed: config.capabilities)
    let registry = try skills.registry(fixed: config.capabilities)
    let photo = UUID()
    var state = AssistantContextState()
    state.skillState = skills
    state.cameraState = CameraStateObservation(
        sequence: 1, enabled: true, visible: true, busy: false, needsSettings: false, facing: .back,
        displayedPhotoID: photo, savedPhotoID: photo)
    let context = AgentContext(agentID: .assistant, scopeID: UUID(), state: state)
    for (alias, parameters) in [
        ("takePhoto", [:]), ("savePhoto", ["photoID": photo.uuidString]),
        ("ignorePhoto", ["photoID": photo.uuidString]),
    ] {
        let call = try registry.resolveAction(alias, parameters: parameters)
        #expect(call.channel == "Camera")
    }
    #expect(skills.activeTaskID == nil)
    let facts = try AssistantContextBuilder.contextFacts(context, input: input)
    #expect(facts.contains { $0.content.contains("displayedPhotoID") && $0.content.contains(photo.uuidString) })
    #expect(facts.contains { $0.content.contains("savedPhotoID") && $0.content.contains(photo.uuidString) })
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
    let input = UUID()
    _ = try state.control("startTask", arguments: ["goal": "fixture"], inputID: input, fixed: fixed)
    #expect(throws: CommunicationError.invalidPayload) {
        try state.control(
            "finishTask", arguments: ["summary": "done", "continueDecision": "yes"], inputID: input, fixed: fixed)
    }
    #expect(state.tasks.last?.status == "running")
    _ = try state.control("finishTask", arguments: ["summary": "done"], inputID: input, fixed: fixed)
    #expect(state.tasks.last?.continueDecision == false)
}

@Test(.actionCatalog) func bundledSkillsKeepPresentationAndDeviceProceduresSeparate() throws {
    let expression = try AgentConfigurations.skill("expression-interaction")
    #expect(Set(expression.functions.map(\.path)) == ["UI.Expression.express", "UI.Expression.setExpression"])
    let application = try AgentConfigurations.skill("application-control")
    #expect(application.functions.count == 7 && !application.functions.contains { $0.path.hasPrefix("NexArm.") })
    let robot = try AgentConfigurations.skill("robot-interaction")
    #expect(robot.functions.count == 11 && robot.functions.allSatisfy { $0.path.hasPrefix("NexArm.") })
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
    #expect(base.actions.contains { $0.alias == "nodHead" })
}

@Test(.actionCatalog, arguments: [false, true])
func taskEntryRetainsConversationAndNativePairsUntilClosure(replacingWithinInput: Bool) async throws {
    let config = try AgentConfigurations.load(named: "Assistant")
    var skills = AgentTaskSkillState()
    try skills.initialize(fixed: config.capabilities, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    let ordinaryID = UUID()
    let oldInputID = UUID()
    let newInputID = replacingWithinInput ? oldInputID : UUID()
    _ = try skills.control("startTask", arguments: ["goal": "旧拍照目标"], inputID: oldInputID, fixed: config.capabilities)
    let oldTaskID = try #require(skills.activeTaskID)
    _ = try skills.control(
        "finishTask", arguments: ["summary": "旧照片已保存"], inputID: oldInputID, fixed: config.capabilities)
    try skills.roundCompleted(failed: false, fixed: config.capabilities)
    _ = try skills.control("startTask", arguments: ["goal": "后置拍照"], inputID: newInputID, fixed: config.capabilities)
    let newTaskID = try #require(skills.activeTaskID)
    let store = ConversationHistoryStore()
    func record(_ inputID: UUID, requests: [(UUID?, String)], nativePair: Bool = false) async throws {
        let current = try await store.readCurrent()
        _ = try await store.begin(
            id: inputID, user: "fixture input",
            request: [.init(role: .system, content: "fixture"), .init(role: .user, content: "fixture input")],
            expecting: current.token, model: "stub")
        for (taskID, output) in requests {
            let request = ConversationModelRequest(
                id: UUID(), input: "fixture input", requestJSON: "[]",
                decisionMetadata: .init(
                    taskID: taskID, mode: taskID == nil ? "default" : "task", skills: [:], catalogJSON: "{}"),
                historyTaskID: taskID
                    ?? (output == "OLD_ENTRY" ? oldTaskID : (output.hasPrefix("<startTask") ? newTaskID : nil)))
            try await store.beginModelRequest(request, for: inputID)
            try await store.append(output, to: inputID)
            if nativePair {
                let call = ConversationToolCall(
                    id: UUID(), providerID: "background-query", name: "History.list", argumentsJSON: "{}")
                try await store.recordToolCall(call, for: inputID)
                try await store.recordToolOutcome(call.id, for: inputID, state: .completed, output: "用户偏好红帽子")
            }
            try await store.finishModelRequest(inputID, reason: "stop")
        }
        try await store.finish(inputID, state: .completed)
    }
    try await record(ordinaryID, requests: [(nil, "普通对话背景")], nativePair: true)
    let oldRequests: [(UUID?, String)] = [(nil, "OLD_ENTRY"), (oldTaskID, "OLD_PHOTO_RAW")]
    let newRequests: [(UUID?, String)] = [(nil, "<startTask goal=\"后置拍照\"/>"), (newTaskID, "CURRENT_TASK_RAW")]
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
    let input = AgentInput(sessionID: UUID(), payload: .text("保存当前照片"))
    func projected(_ value: AssistantContextState) throws -> [ChatMessage] {
        let snapshot = AgentContext(agentID: .assistant, scopeID: UUID(), state: value)
        let decision = AgentDecisionContext(snapshot: snapshot, input: input)
        return try AgentChatRequestBuilder<AssistantContextState>().build(state: decision, batch: decision.batch())
            .messages(system: "fixture", user: "保存当前照片")
    }
    let active = try projected(state)
    #expect(active.contains { $0.role == .assistant && $0.content == "普通对话背景" })
    #expect(active.contains { $0.role == .assistant && $0.content.hasPrefix("<startTask") })
    #expect(active.contains { $0.content == "CURRENT_TASK_RAW" })
    #expect(!active.contains { $0.content.contains("OLD_ENTRY") || $0.content.contains("OLD_PHOTO_RAW") })
    #expect(active.contains { $0.content.contains("Task history") && $0.content.contains("旧照片已保存") })
    let paired = try #require(active.firstIndex { !$0.toolCalls.isEmpty })
    #expect(active[paired].toolCalls.first?.id == "background-query")
    #expect(active[paired + 1].role == .tool && active[paired + 1].toolCallID == "background-query")
    #expect(active[paired + 1].content == "用户偏好红帽子")
    _ = try skills.control(
        "finishTask", arguments: ["summary": "新照片已保存"], inputID: newInputID, fixed: config.capabilities)
    try skills.roundCompleted(failed: false, fixed: config.capabilities)
    state.skillState = skills
    state.reconcileTaskCompressions()
    let closed = try projected(state)
    #expect(closed.contains { $0.content == "普通对话背景" })
    #expect(!closed.contains { $0.content.contains("CURRENT_TASK_RAW") || $0.content.contains("<startTask") })
    #expect(closed.contains { $0.content.contains("Task history") && $0.content.contains("新照片已保存") })
    #expect(try encoder.encode(state.history.current.turns) == originalHistory)
}

@Test(.actionCatalog) func historyTaskAssignmentRefreshesStoreAndRejectsStaleAdmission() async throws {
    let context = AgentContextRepository(agent: .assistant, scope: UUID(), state: AssistantContextState())
    let store = AgentChatHistoryContext.store(repository: context)
    let input = UUID()
    let request = UUID()
    let task = UUID()
    let token = try await store.readCurrent().token
    _ = try await store.begin(id: input, user: "start goal", request: [], expecting: token, model: "stub")
    try await store.beginModelRequest(
        .init(
            id: request, input: "start goal", requestJSON: "[]",
            decisionMetadata: .init(taskID: nil, mode: "default", skills: [:], catalogJSON: "{}")), for: input)
    let stale = try await store.readCurrent().token
    try await context.update { try $0.state.history.assignHistoryTask(task, inputID: input, requestID: request) }
    await #expect(throws: ConversationHistoryError.conflict) {
        _ = try await store.begin(id: UUID(), user: "stale", request: [], expecting: stale, model: "stub")
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
    _ = try skills.control("startTask", arguments: ["goal": "目标"], inputID: UUID(), fixed: config.capabilities)
    let task = try #require(skills.activeTaskID)
    skills.tasks[0].status = status
    skills.tasks[0].summary = "用户选择了第一张"
    skills.tasks[0].failure = status == "failed" ? "真实执行失败" : nil
    skills.activeTaskID = nil
    let store = ConversationHistoryStore()
    func add(_ text: String, taskID: UUID? = nil) async throws -> UUID {
        let input = UUID()
        let token = try await store.readCurrent().token
        _ = try await store.begin(id: input, user: text, request: [], expecting: token, model: "stub")
        try await store.beginModelRequest(
            .init(id: UUID(), input: text, requestJSON: "[]", historyTaskID: taskID), for: input)
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
    let input = UUID()
    _ = try skills.control("startTask", arguments: ["goal": "goal"], inputID: input, fixed: fixed)
    let task = try #require(skills.activeTaskID)
    _ = try skills.control("finishTask", arguments: ["summary": "done"], inputID: input, fixed: fixed)
    let store = ConversationHistoryStore()
    _ = try await store.begin(id: input, user: "goal", request: [], expecting: store.readCurrent().token, model: "stub")
    try await store.beginModelRequest(
        .init(id: UUID(), input: "goal", requestJSON: "[]", historyTaskID: task), for: input)
    try await store.append("done", to: input)
    try await store.finish(input, state: .completed)
    var state = AssistantContextState()
    state.skillState = skills
    state.history = try await store.snapshot()
    let repository = AgentContextRepository(
        agent: .assistant, scope: UUID(), state: state,
        persistence: AgentContextPersistence(load: { nil }, commit: { _, _ in throw WriteFailure() }))
    await #expect(throws: WriteFailure.self) {
        try await repository.update {
            try $0.state.skillState?.roundCompleted(failed: false, fixed: fixed)
            $0.state.reconcileTaskCompressions()
        }
    }
    let retained = try await repository.snapshot().state
    #expect(retained.skillState?.activeTaskID == task && retained.skillState?.tasks.first?.status == "finishing")
    #expect(retained.history.current.taskCompressions.isEmpty)
    #expect(retained.history.current.turns.first?.raw == "done")
}

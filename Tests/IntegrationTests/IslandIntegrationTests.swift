import Actions
import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import Testing

@testable import Agents
@testable import UI

private func islandInput(_ function: String, parameters: [String: String], source: String = "fixture")
    -> FunctionInvocation
{
    .init(
        call: .init(actionPath: .init(domain: "UI", module: "Island", function: function), parameters: parameters),
        context: .init(source: source, sessionID: "island-test", inputID: "input"), executionID: UUID().uuidString,
        results: ActionReportStore())
}
@Test @MainActor func islandActionsRejectCustomGeometryAndNeverReportRenderedPixels() async throws {
    let state = IslandState()
    state.setAvailable(true)
    let service = IslandPresentationService(state: state)
    let id = UUID()
    try state.publish(
        id: id, owner: "fixture:island-test", revision: 1,
        content: .init(title: "测试", primary: .symbol(name: "circle")), generation: state.generation, creating: true)
    for params in [
        ["activityID": id.uuidString, "size": "custom", "width": "900", "height": "300"],
        ["activityID": id.uuidString, "size": "large"],
        ["activityID": id.uuidString, "size": "expanded", "animation": "spring"],
    ] {
        await #expect(throws: IslandError.systemControlled) {
            _ = try await IslandActions.setPresentation(
                invocation: islandInput("setPresentation", parameters: params), using: service)
        }
    }
    await #expect(throws: IslandError.owner) {
        _ = try await IslandActions.end(
            invocation: islandInput(
                "end", parameters: ["activityID": id.uuidString, "revision": "2"], source: "other"), using: service)
    }
    // Ordinary status has no details: no generic tap or Action may invent an expanded panel.
    await #expect(throws: IslandError.invalid) {
        _ = try await IslandActions.setPresentation(
            invocation: islandInput("setPresentation", parameters: ["activityID": id.uuidString, "size": "expanded"]),
            using: service)
    }
    #expect(state.activities.count == 1)
}
@Test(.actionCatalog) func islandSkillsExposeOnlyDisplayControlAndKeepBasicUnchanged() throws {
    let fixed = try AgentConfigurations.load(named: "Assistant").capabilities
    let registry = try AgentSkillLoader.registry(["photography", "application-control"], fixed: fixed)
    #expect(
        registry.actions.filter { $0.path.description.hasPrefix("UI.Island.") }.map(\.alias) == [
            "Island.setPresentation"
        ])
    #expect(
        try !AgentSkillLoader.registry(["basic-skill"], fixed: fixed).actions.contains {
            $0.path.description.hasPrefix("UI.Island.")
        })
}
@Test @MainActor func islandDomainBridgeProjectsFactsWithoutObservingItsOwnActionLogs() async throws {
    let ui = UIContainer()
    try ui.start()
    let service = IslandPresentationService(state: ui.island)
    let bridge = IslandDomainPresentation(service: service, home: ui.home, camera: ui.camera.state)
    let runner = Task { await bridge.run() }
    _ = ui.home.conversation.presentBluetoothConnection(.connected, revision: 1)
    let deadline = ContinuousClock.now + .seconds(3)
    while ui.island.activities.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
    #expect(ui.island.activities.first?.owner == "domain.bluetooth")
    #expect(ui.island.activities.first?.content.liveActivity != true)
    ui.camera.present(.countdown(3))
    let countdownDeadline = ContinuousClock.now + .seconds(3)
    while ui.island.selected?.content.title != "拍照倒计时" && ContinuousClock.now < countdownDeadline {
        await Task.yield()
    }
    #expect(ui.island.selected?.content.primary == .symbol(name: "timer"))
    #expect(ui.island.selected?.content.liveActivity == true)
    ui.invalidate()
    #expect(ui.island.activities.isEmpty)
    await bridge.stop()
    runner.cancel()
    await runner.value
    service.stop()
    await ui.stop()
}

@Test @MainActor func islandVoiceAndCameraExposeTypedSlotsFromActualPhases() {
    let start = Date(timeIntervalSinceReferenceDate: 12345)
    let listening = IslandDomainPresentation.voiceContent(.listening, startedAt: start)
    #expect(listening?.primary == .symbol(name: "mic.fill", effect: .pulse))
    #expect(listening?.secondary == .elapsed(startedAt: start))
    #expect(listening?.liveActivity != true)
    #expect(IslandDomainPresentation.voiceContent(.speaking)?.secondary == .spectrum)
    #expect(IslandDomainPresentation.voiceContent(.processing)?.secondary == .loading)
    #expect(IslandDomainPresentation.voiceContent(.idle) == nil)
}

@MainActor private final class IslandPortProbe: IslandDomainPresenting {
    let islandAvailable = true
    let islandGeneration = UUID()
    var contents: [String: IslandContent] = [:]
    var errors: [String] = []
    private(set) var commands: [(IslandDomain, IslandCommand)] = []
    var failures = 0
    var delay: Duration?
    private(set) var cancelled = 0
    func islandActions(for domain: IslandDomain) -> any IslandActionCalling {
        IslandProbeActions(port: self, domain: domain)
    }
    func accept(_ command: IslandCommand, domain: IslandDomain) async throws -> IslandReceipt {
        commands.append((domain, command))
        if command.operation != .end, let delay {
            do { try await Task.sleep(for: delay) } catch {
                cancelled += 1
                throw error
            }
        }
        if failures > 0 {
            failures -= 1
            throw IslandError.unavailable
        }
        contents[domain.rawValue] = command.content
        return .init(
            activityID: command.id.uuidString, state: "submitted", presentation: "localAndSystem",
            localStatus: "fixture", systemStatus: "unsupported")
    }
    func publishSpectrum(_ values: [Float], active: Bool) throws {}
    func reportIslandFailure(_ error: any Error) { errors.append(String(describing: error)) }
}
@MainActor private final class IslandProbeActions: IslandActionCalling {
    let port: IslandPortProbe
    let domain: IslandDomain
    init(port: IslandPortProbe, domain: IslandDomain) {
        self.port = port
        self.domain = domain
    }
    func perform(_ command: IslandCommand) async throws -> IslandReceipt {
        try await port.accept(command, domain: domain)
    }
}
@Test @MainActor func islandDomainProducerRunsAgainstNarrowPortWithoutRendererOrIslandState() async throws {
    let ui = UIContainer()
    try ui.start()
    let port = IslandPortProbe()
    ui.camera.present(.countdown(3))
    let producer = IslandDomainPresentation(service: port, home: ui.home, camera: ui.camera.state)
    let task = Task { await producer.run() }
    let deadline = ContinuousClock.now + .seconds(3)
    while port.contents["camera"] == nil && ContinuousClock.now < deadline { await Task.yield() }
    #expect(port.contents["camera"]?.title == "拍照倒计时" && port.errors.isEmpty)
    #expect(ui.island.activities.isEmpty)
    await producer.stop()
    await task.value
    await ui.stop()
}

@Test @MainActor func islandDomainDoesNotDeriveAgentActivitiesFromPassiveTaskLogs() async throws {
    let ui = UIContainer()
    try ui.start()
    let service = IslandPresentationService(state: ui.island)
    let bridge = IslandDomainPresentation(service: service, home: ui.home, camera: ui.camera.state)
    let runner = Task { await bridge.run() }
    ui.home.activity.present(.currentTaskTitle("旧任务日志"))
    ui.home.activity.present(.currentTaskStatus("running"))
    ui.home.activity.present(.currentTaskID("task-1"))
    ui.home.activity.updateTask(
        .init(id: "task-1", parentID: nil, requester: "", executor: "assistant", title: "旧任务", phase: .running),
        event: .init(id: "late", time: Date(), title: "迟到步骤", detail: "仅历史事实"))
    // A capability-owned camera event proves the observer processed this turn.
    ui.camera.present(.countdown(3))
    let deadline = ContinuousClock.now + .seconds(3)
    while ui.island.headerActivity?.owner != "domain.camera", ContinuousClock.now < deadline { await Task.yield() }
    #expect(ui.island.headerActivity?.owner == "domain.camera")
    #expect(ui.island.detailActivity == nil)
    #expect(!ui.island.activities.contains { ["domain.task", "domain.writer"].contains($0.owner) })
    await bridge.stop()
    await runner.value
    service.stop()
    await ui.stop()
}

@MainActor private final class IslandNativeIntegrationProbe: IslandSystemDriving {
    var onStatus: (@MainActor (UUID, IslandSystemStatus) -> Void)?
    var snapshots: [IslandSystemSnapshot?] = []
    var enabled = true
    func apply(_ value: IslandSystemSnapshot?) async throws -> IslandSystemStatus {
        snapshots.append(value)
        return value == nil ? .ended : enabled ? .active : .disabled
    }
}
@Test @MainActor func islandActionReceiptsDescribeNativeRequestsAndPermissionFailures() async throws {
    let state = IslandState()
    let driver = IslandNativeIntegrationProbe()
    state.installSystemDriver(driver)
    state.setAvailable(true)
    let service = IslandPresentationService(state: state)
    let id = UUID()
    let content = String(
        decoding: try JSONEncoder().encode(
            IslandContent(title: "任务", primary: .symbol(name: "scope"), detail: .init(text: "任务目标"))), as: UTF8.self)
    let result = try await IslandActions.present(
        invocation: islandInput(
            "present",
            parameters: [
                "activityID": id.uuidString, "revision": "1", "content": content,
            ]), using: service)
    let receipt = try #require(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
    #expect(receipt["state"] as? String == "submitted")
    #expect(receipt["presentation"] as? String == "localAndSystem" && receipt["systemStatus"] as? String == "active")
    #expect(receipt["width"] == nil && receipt["height"] == nil)
    _ = try await IslandActions.setPresentation(
        invocation: islandInput(
            "setPresentation",
            parameters: [
                "activityID": id.uuidString, "size": "expanded",
            ]), using: service)
    #expect(driver.snapshots.last.flatMap { $0 }?.attentionID != nil)
    try state.publish(
        id: id, owner: "fixture:island-test", revision: 2,
        content: .init(title: "下一个阶段", primary: .symbol(name: "scope"), expansionID: "next-stage"),
        generation: state.generation, creating: false)
    try await state.flushSystem(expectedGeneration: state.generation)
    #expect(driver.snapshots.last.flatMap { $0 }?.attentionID?.hasSuffix(":next-stage") == true)
    _ = try await IslandActions.end(
        invocation: islandInput(
            "end",
            parameters: [
                "activityID": id.uuidString, "revision": "3",
            ]), using: service)
    #expect(driver.snapshots.last.flatMap { $0 } == nil && state.activities.isEmpty)
    driver.enabled = false
    _ = try await IslandActions.present(
        invocation: islandInput(
            "present",
            parameters: [
                "activityID": UUID().uuidString, "revision": "1", "content": content,
            ]), using: service)
    #expect(state.compact != nil && state.localStatus == "pending")
    #expect(state.systemStatus == .disabled)
    await state.stop()
}

@Test @MainActor func islandPresentationActionTargetsOnlyItsActivity() async throws {
    let state = IslandState()
    state.setAvailable(true)
    let service = IslandPresentationService(state: state)
    let low = UUID()
    let high = UUID()
    for (id, priority) in [(low, IslandPriority.low), (high, IslandPriority.attention)] {
        try state.publish(
            id: id, owner: "fixture:island-test", revision: 1,
            content: .init(title: "详情", primary: .symbol(name: "scope"), priority: priority, detail: .init(text: "目标")),
            generation: state.generation, creating: true)
    }
    _ = try await IslandActions.setPresentation(
        invocation: islandInput(
            "setPresentation",
            parameters: ["activityID": low.uuidString, "size": "compact"]), using: service)
    #expect(state.compact?.id == high && state.expanded)
    try state.remove(id: high, owner: "fixture:island-test", revision: 2, generation: state.generation)
    #expect(state.compact?.id == low && !state.expanded && state.detailActivity?.content.detail?.text == "目标")
    await state.stop()
}

@Test @MainActor func islandListeningTimerKeepsAnchorAcrossUpdatesAndBackground() async throws {
    let ui = UIContainer()
    try ui.start()
    let service = IslandPresentationService(state: ui.island)
    let bridge = IslandDomainPresentation(service: service, home: ui.home, camera: ui.camera.state)
    let runner = Task { await bridge.run() }
    func voice() -> IslandActivity? { ui.island.activities.first { $0.owner == "domain.voice" } }
    func wait(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        #expect(condition())
    }
    ui.home.conversation.voicePhase = .listening
    await wait { voice() != nil }
    let first = try #require(voice())
    guard case .elapsed(let start) = first.content.secondary else {
        Issue.record("Listening must provide a timer")
        await bridge.stop()
        await runner.value
        await ui.stop()
        return
    }
    try ui.setSceneActive(false)
    ui.camera.present(.countdown(3))
    await wait { ui.island.selected?.owner == "domain.camera" }
    #expect(voice()?.content.secondary == .elapsed(startedAt: start))
    #expect(voice()?.revision == first.revision)
    try ui.setSceneActive(true)
    ui.home.conversation.voicePhase = .processing
    await wait { voice()?.content.secondary == .loading }
    ui.home.conversation.voicePhase = .listening
    await wait { voice()?.content.primary.symbolName == "mic.fill" }
    guard case .elapsed(let next) = voice()?.content.secondary else {
        Issue.record("Next listening phase must provide a timer")
        await bridge.stop()
        await runner.value
        await ui.stop()
        return
    }
    #expect(next > start)
    await bridge.stop()
    await runner.value
    service.stop()
    await ui.stop()
}

@Test func islandActionCatalogOmitsRetiredGeometryAndAnimationParameters() throws {
    let declaration = IslandActions.setPresentationDeclaration
    #expect(declaration.parameters.map(\.name) == ["activityID", "size"])
    for value in ["large", "custom"] {
        #expect(throws: IslandError.systemControlled) {
            try IslandCommand(
                operation: .setPresentation, parameters: ["activityID": UUID().uuidString, "size": value])
        }
    }
}

@Test @MainActor func writerIslandEndsTerminalWithoutRemovingVoice() async throws {
    let ui = UIContainer()
    try ui.start()
    let service = IslandPresentationService(state: ui.island)
    let bridge = IslandDomainPresentation(service: service, home: ui.home, camera: ui.camera.state)
    let runner = Task { await bridge.run() }
    func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }
    let writer = WriterIslandPresentation()
    await writer.bind { operation, parameters, session in
        let input = FunctionInvocation(
            call: .init(actionPath: .init(domain: "UI", module: "Island", function: operation), parameters: parameters),
            context: .init(source: "writer", sessionID: session, inputID: "display"),
            executionID: UUID().uuidString, results: ActionReportStore())
        if operation == "end" {
            _ = try await IslandActions.end(invocation: input, using: service)
        } else {
            _ = try await IslandActions.present(invocation: input, using: service)
        }
    }
    await writer.start()
    await writer.begin(runID: "writer-run", goal: "画流程图")
    try await wait { ui.island.detailActivity?.owner.hasPrefix("writer:") == true }
    #expect(ui.island.detailActivity?.content.tone == .purple)
    #expect(ui.island.expanded)
    let id = try #require(ui.island.detailActivity?.id)
    try ui.island.publishSlot(owner: "test.voice", content: IslandDomainPresentation.voiceContent(.speaking))
    #expect(ui.island.headerActivity?.content.primary == .symbol(name: "speaker.wave.2.fill"))
    try ui.island.setExpanded(false, id: id)
    await writer.update(runID: "writer-run", phase: .running, step: "正在绘制节点")
    try await wait { ui.island.detailActivity?.content.detail?.text?.contains("正在绘制节点") == true }
    #expect(ui.island.detailActivity?.id == id)
    #expect(!ui.island.expanded)
    await writer.update(runID: "writer-run", phase: .completed, step: "作品已保存")
    try await wait { ui.island.detailActivity == nil }
    #expect(ui.island.headerActivity?.owner == "test.voice")
    await writer.update(runID: "writer-run", phase: .running, step: "迟到进度")
    // Assistant Task logs are no longer a producer of Writer Island content.
    ui.home.activity.updateTask(
        .init(id: "stale", parentID: nil, requester: "assistant", executor: "writer", title: "旧日志", phase: .running),
        event: .init(id: "late", time: Date(), title: "旧步骤", detail: "不能覆盖"))
    try await Task.sleep(for: .milliseconds(30))
    #expect(ui.island.detailActivity == nil)
    #expect(!ui.island.activities.contains { $0.owner == "domain.writer" })
    await writer.stop()
    await bridge.stop()
    runner.cancel()
    await runner.value
    service.stop()
    await ui.stop()
}

private actor WriterIslandPublicationProbe {
    var calls = 0
    var blocked = true
    var first: CheckedContinuation<Void, Never>?
    var failures = 0
    func accept() async throws {
        calls += 1
        if blocked {
            await withCheckedContinuation { first = $0 }
            failures += 1
            throw IslandError.unavailable
        }
    }
    func allow() {
        blocked = false
        first?.resume()
        first = nil
    }
}

@Test @MainActor func writerIslandRetriesOnlyLatestRunAndStopsItsOwnedWorker() async throws {
    let state = IslandState()
    state.setAvailable(true)
    let service = IslandPresentationService(state: state)
    let probe = WriterIslandPublicationProbe()
    let writer = WriterIslandPresentation()
    await writer.bind { operation, parameters, session in
        try await probe.accept()
        let input = FunctionInvocation(
            call: .init(actionPath: .init(domain: "UI", module: "Island", function: operation), parameters: parameters),
            context: .init(source: "writer", sessionID: session, inputID: "display"),
            executionID: UUID().uuidString, results: ActionReportStore())
        if operation == "end" {
            _ = try await IslandActions.end(invocation: input, using: service)
        } else {
            _ = try await IslandActions.present(invocation: input, using: service)
        }
    }
    await writer.start()
    await writer.begin(runID: "old", goal: "旧任务")
    let deadline = ContinuousClock.now + .seconds(3)
    while await probe.calls == 0, ContinuousClock.now < deadline { await Task.yield() }
    #expect(await probe.calls == 1)
    for i in 0..<100 { await writer.update(runID: "old", phase: .running, step: "旧步骤 \(i)") }
    await writer.begin(runID: "new", goal: String(repeating: "长目标", count: 400))
    await writer.update(runID: "new", phase: .running, step: "新任务步骤")
    await writer.update(runID: "old", phase: .completed, step: "迟到旧终态")
    await probe.allow()
    let publicationDeadline = ContinuousClock.now + .seconds(3)
    while state.detailActivity == nil, ContinuousClock.now < publicationDeadline { await Task.yield() }
    let item = try #require(state.detailActivity)
    #expect(item.revision <= 103)
    #expect(item.content.expansionID == "new:active")
    #expect(item.content.priority == .high)
    #expect(item.content.title.count <= 80 && (item.content.detail?.text?.count ?? 0) <= 320)
    #expect(item.content.detail?.text?.contains("新任务步骤") == true)
    #expect(item.content.detail?.text?.contains("迟到") == false)
    #expect(await probe.calls == 2)
    #expect(await probe.failures == 1)
    await writer.stop()
    #expect(state.activities.isEmpty)
    let stopped = await probe.calls
    await writer.update(runID: "new", phase: .running, step: "迟到回调")
    try await Task.sleep(for: .milliseconds(550))
    #expect(await probe.calls == stopped)
    await state.stop()
}

@Test @MainActor func islandSemanticPriorityArbitratesIndependentlyOfProducerNames() async throws {
    let state = IslandState()
    state.setAvailable(true)
    let lower = try #require(
        try state.publishSlot(
            owner: "arbitrary-critical-sounding-name",
            content: .init(
                title: "低优先级", primary: .symbol(name: "circle"), priority: .low)))
    let higher = try #require(
        try state.publishSlot(
            owner: "ordinary", content: .init(title: "高优先级", primary: .symbol(name: "circle"), priority: .critical)))
    #expect(state.statusActivity?.id == higher)
    _ = try state.publishSlot(
        owner: "arbitrary-critical-sounding-name",
        content: .init(
            title: "同等级新状态", primary: .symbol(name: "circle"), priority: .critical))
    #expect(state.statusActivity?.id == lower)
    // Current content uses semantic priority; numeric-rank payloads are not imported.
    let encoded = try JSONEncoder().encode(try #require(state.statusActivity).content)
    #expect(try JSONDecoder().decode(IslandContent.self, from: encoded).priority == .critical)
    let old = String(decoding: encoded, as: UTF8.self).replacingOccurrences(
        of: "\"priority\":\"critical\"", with: "\"rank\":100")
    #expect(throws: (any Error).self) { try JSONDecoder().decode(IslandContent.self, from: Data(old.utf8)) }
    await state.stop()
}

@Test @MainActor func writerAllTerminalStatesEndAndCannotResurrect() async throws {
    let state = IslandState()
    state.setAvailable(true)
    let service = IslandPresentationService(state: state)
    let writer = WriterIslandPresentation()
    await writer.bind { operation, parameters, session in
        let input = FunctionInvocation(
            call: .init(actionPath: .init(domain: "UI", module: "Island", function: operation), parameters: parameters),
            context: .init(source: "writer", sessionID: session, inputID: "display"),
            executionID: UUID().uuidString, results: ActionReportStore())
        if operation == "end" {
            _ = try await IslandActions.end(invocation: input, using: service)
        } else {
            _ = try await IslandActions.present(invocation: input, using: service)
        }
    }
    await writer.start()
    for phase in [WriterIslandPresentation.Phase.completed, .failed, .cancelled, .interrupted] {
        let run = UUID().uuidString
        await writer.begin(runID: run, goal: "测试终态")
        let start = ContinuousClock.now + .seconds(3)
        while state.detailActivity == nil, ContinuousClock.now < start { await Task.yield() }
        try #require(state.detailActivity != nil)
        await writer.update(runID: run, phase: .waitingUser)
        await writer.update(runID: run, phase: .cancelling)
        await writer.update(runID: run, phase: phase)
        let end = ContinuousClock.now + .seconds(3)
        while state.detailActivity != nil, ContinuousClock.now < end { await Task.yield() }
        #expect(state.activities.isEmpty)
        await writer.update(runID: run, phase: .running, step: "迟到")
        await Task.yield()
        #expect(state.activities.isEmpty)
    }
    await writer.stop()
    await state.stop()
}

@Test(.actionCatalog) func assistantTaskIslandUsesOwnSkillLifecycle() throws {
    var skills = AgentTaskSkillState()
    let fixed = try AssistantContextState.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities)
    try skills.initialize(fixed: fixed, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    #expect(AssistantExecutionSession.taskContent(skills) == nil)
    let input = UUID().uuidString
    _ = try skills.control("startTask", arguments: ["goal": "测试前台目标"], inputID: input, fixed: fixed, taskID: "task_1")
    let content = try #require(AssistantExecutionSession.taskContent(skills))
    #expect(content.detail?.text == "测试前台目标")
    #expect(content.expansionID == skills.activeTaskID)
    _ = try skills.control("finishTask", arguments: ["summary": "完成"], inputID: input, fixed: fixed)
    try skills.decisionCompleted(failed: false, fixed: fixed)
    #expect(AssistantExecutionSession.taskContent(skills) == nil)
}

@Test(.actionCatalog) @MainActor func assistantTaskIslandPublishesThroughItsOwnGatewayAndEndsOnShutdown() async throws {
    let state = IslandState()
    state.setAvailable(true)
    let service = IslandPresentationService(state: state)
    let manager = AgentManager()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, configurations: AgentConfigurations.all())
    let input = InputGateway(manager: manager, policy: policy)
    let assembly = try BehaviorAssembly(capabilityModules: [IslandModule(island: service)])
    let gateway = await OutputGateway(
        manager: manager, requests: input, tools: assembly.tools, policy: policy, sink: { _ in })
    let repository = try AgentContextRepository(
        agent: AgentID.assistant, scope: UUID().uuidString, state: AssistantContextState())
    let agent = try AssistantAgent(stateContext: try publicStateFixture(), context: repository)
    let session = AssistantExecutionSession(agent: agent, manager: manager, output: gateway)
    try await session.start()
    var skills = AgentTaskSkillState()
    let fixed = agent.descriptor.capabilities
    try skills.initialize(fixed: fixed, baseSkills: AgentConfigurations.baseSkills(named: "Assistant"))
    _ = try skills.control(
        "startTask", arguments: ["goal": "Assistant 独立前台目标"], inputID: UUID().uuidString, fixed: fixed, taskID: "task_1"
    )
    await session.presentTaskState(skills)
    let deadline = ContinuousClock.now + .seconds(5)
    while state.detailActivity == nil, ContinuousClock.now < deadline { await Task.yield() }
    #expect(state.detailActivity?.owner.hasPrefix("assistant:") == true)
    #expect(state.detailActivity?.content.detail?.text == "Assistant 独立前台目标")
    #expect(await session.presentationFailure == nil)
    #expect(try await repository.snapshot().state.history.current.turns.isEmpty)
    await session.shutdown()
    #expect(state.activities.isEmpty)
    #expect(await session.presentationFailure == nil)
    await gateway.shutdown()
    await state.stop()
}

@Test @MainActor func islandInternalAndRegisteredActionsShareExecutionAndOwnership() async throws {
    let state = IslandState()
    state.setAvailable(true)
    let service = IslandPresentationService(state: state)
    let camera = service.islandActions(for: .camera)
    let localID = UUID()
    let remoteID = UUID()
    let content = IslandContent(title: "共享执行", primary: .symbol(name: "scope"), detail: .init(text: "目标"))
    let local = try await camera.perform(.init(operation: .present, id: localID, revision: 1, content: content))
    let raw = try await IslandActions.present(
        invocation: islandInput(
            "present",
            parameters: [
                "activityID": remoteID.uuidString, "revision": "1",
                "content": String(decoding: try JSONEncoder().encode(content), as: UTF8.self),
            ]), using: service)
    let remote = try JSONDecoder().decode(IslandReceipt.self, from: Data(raw.utf8))
    #expect(local.state == remote.state && local.presentation == remote.presentation)
    #expect(local.localStatus == remote.localStatus && local.systemStatus == remote.systemStatus)
    #expect(state.activities.first { $0.id == localID }?.owner == "domain.camera")
    #expect(
        state.activities.first { $0.id == localID }?.content == state.activities.first { $0.id == remoteID }?.content)
    await #expect(throws: IslandError.owner) {
        _ = try await camera.perform(.init(operation: .end, id: remoteID, revision: 2))
    }
    await #expect(throws: IslandError.owner) {
        _ = try await camera.perform(.init(operation: .setPresentation, id: remoteID, size: .compact))
    }
    await #expect(throws: IslandError.owner) {
        _ = try await service.islandActions(for: .voice).perform(
            .init(operation: .update, id: localID, revision: 2, content: content))
    }
    await #expect(throws: IslandError.stale) {
        _ = try await camera.perform(
            .init(operation: .update, id: localID, revision: 1, content: .init(title: "旧修改", primary: .loading)))
    }
    // Registered shared display control keeps its granted ability to expand another producer's activity.
    _ = try await IslandActions.setPresentation(
        invocation: islandInput(
            "setPresentation",
            parameters: [
                "activityID": localID.uuidString, "size": "compact",
            ]), using: service)
    #expect(state.detailActivity?.id == remoteID && state.expanded)
    _ = try await camera.perform(.init(operation: .setPresentation, id: localID, size: .expanded))
    #expect(state.expanded)
    _ = try await camera.perform(.init(operation: .end, id: localID, revision: 2))
    _ = try await camera.perform(.init(operation: .end, id: localID, revision: 2))
    #expect(state.activities.map(\.id) == [remoteID])
    await state.stop()
}

@Test @MainActor func islandBoundActionsRejectOldGenerationAndStoppedService() async throws {
    let state = IslandState()
    state.setAvailable(true)
    let service = IslandPresentationService(state: state)
    let old = service.islandActions(for: .voice)
    state.setAvailable(false)
    state.setAvailable(true)
    let command = try IslandCommand(
        operation: .present, id: UUID(), revision: 1,
        content: .init(title: "当前状态", primary: .loading))
    await #expect(throws: IslandError.stale) { _ = try await old.perform(command) }
    #expect(state.activities.isEmpty)
    let current = service.islandActions(for: .voice)
    _ = try await current.perform(command)
    #expect(state.activities.count == 1)
    service.stop()
    await #expect(throws: IslandError.unavailable) {
        _ = try await current.perform(.init(operation: .end, id: command.id, revision: 2))
    }
    #expect(throws: IslandError.invalid) {
        try IslandCommand(operation: .present, id: UUID(), revision: 0, content: command.content)
    }
    #expect(throws: IslandError.invalid) {
        try IslandCommand(operation: .end, id: UUID(), revision: 1, content: command.content)
    }
    #expect(throws: IslandError.invalid) {
        try IslandCommand(operation: .setPresentation, id: UUID(), revision: 1, size: .compact)
    }
    await state.stop()
}

@Test(arguments: [false, true]) @MainActor func islandDomainCallsActionsAndRetriesOnlyCurrentFact(replace: Bool)
    async throws
{
    let ui = UIContainer()
    try ui.start()
    let port = IslandPortProbe()
    port.failures = 1
    ui.camera.present(.countdown(3))
    let producer = IslandDomainPresentation(service: port, home: ui.home, camera: ui.camera.state)
    let runner = Task { await producer.run() }
    let first = ContinuousClock.now + .seconds(5)
    while port.commands.isEmpty, ContinuousClock.now < first { await Task.yield() }
    try #require(port.commands.count == 1 && port.errors.count == 1)
    if replace { ui.camera.present(.countdown(2)) }
    let recovered = ContinuousClock.now + .seconds(5)
    while port.contents["camera"] == nil, ContinuousClock.now < recovered { await Task.yield() }
    try #require(port.commands.count == 2)
    #expect(port.commands[0].1.id == port.commands[1].1.id)
    #expect(port.commands[1].1.revision == (replace ? 2 : 1))
    #expect(port.contents["camera"]?.subtitle == (replace ? "2 秒" : "3 秒"))
    // Wake the observer with unchanged business content; no additional presentation Action.
    for _ in 0..<10 {
        ui.home.conversation.playbackSpectrum = [Float](repeating: 0.25, count: 32)
        await Task.yield()
    }
    try await Task.sleep(for: .milliseconds(600))
    #expect(port.commands.count == 2)
    await producer.stop()
    await runner.value
    #expect(port.commands.last?.1.operation == .end)
    #expect(port.contents["camera"] == nil)
    let stopped = port.commands.count
    ui.camera.present(.countdown(1))
    await Task.yield()
    #expect(port.commands.count == stopped)
    await ui.stop()
}

@Test @MainActor func islandDomainActionLifecycleLeavesPeerActivityAndSpectrumVersionIntact() async throws {
    let ui = UIContainer()
    try ui.start()
    let service = IslandPresentationService(state: ui.island)
    let peer = UUID()
    _ = try await IslandActions.present(
        invocation: islandInput(
            "present",
            parameters: [
                "activityID": peer.uuidString, "revision": "1",
                "content": String(
                    decoding: try JSONEncoder().encode(
                        IslandContent(
                            title: "Agent 任务", primary: .loading,
                            detail: .init(text: "保留任务"))), as: UTF8.self),
            ]), using: service)
    ui.home.conversation.voicePhase = .speaking
    ui.camera.present(.countdown(3))
    _ = ui.home.conversation.presentBluetoothConnection(.connected, revision: 1)
    let producer = IslandDomainPresentation(service: service, home: ui.home, camera: ui.camera.state)
    let runner = Task { await producer.run() }
    let deadline = ContinuousClock.now + .seconds(5)
    while ui.island.activities.count != 4, ContinuousClock.now < deadline { await Task.yield() }
    try #require(ui.island.activities.count == 4)
    let revisions = Dictionary(uniqueKeysWithValues: ui.island.activities.map { ($0.owner, $0.revision) })
    ui.home.conversation.playbackSpectrum = [Float](repeating: 0.5, count: 32)
    let spectrum = ContinuousClock.now + .seconds(5)
    while ui.island.bands.first != 0.5, ContinuousClock.now < spectrum { await Task.yield() }
    #expect(ui.island.bands.first == 0.5)
    #expect(Dictionary(uniqueKeysWithValues: ui.island.activities.map { ($0.owner, $0.revision) }) == revisions)
    await producer.stop()
    await runner.value
    #expect(ui.island.activities.map(\.id) == [peer])
    await ui.stop()
}

@Test @MainActor func islandDomainRebindsOnlyCurrentGenerationWithoutSourceChanges() async throws {
    let ui = UIContainer()
    try ui.start()
    let service = IslandPresentationService(state: ui.island)
    ui.home.conversation.voicePhase = .listening
    let producer = IslandDomainPresentation(service: service, home: ui.home, camera: ui.camera.state)
    let runner = Task { await producer.run() }
    let first = ContinuousClock.now + .seconds(5)
    while ui.island.activities.isEmpty, ContinuousClock.now < first { await Task.yield() }
    let old = try #require(ui.island.activities.first { $0.owner == "domain.voice" })
    ui.island.setAvailable(false)
    try await Task.sleep(for: .milliseconds(30))
    #expect(ui.island.activities.isEmpty)
    ui.island.setAvailable(true)
    let restored = ContinuousClock.now + .seconds(5)
    while ui.island.activities.isEmpty, ContinuousClock.now < restored { await Task.yield() }
    let current = try #require(ui.island.activities.first { $0.owner == "domain.voice" })
    #expect(current.id != old.id && current.revision == 1)
    #expect(current.content.title == "正在聆听")
    await producer.stop()
    await runner.value
    #expect(ui.island.activities.isEmpty)
    await ui.stop()
}

@Test @MainActor func islandDomainStopCancelsAndJoinsInFlightInternalAction() async throws {
    let ui = UIContainer()
    try ui.start()
    let port = IslandPortProbe()
    port.delay = .seconds(30)
    ui.camera.present(.countdown(3))
    let producer = IslandDomainPresentation(service: port, home: ui.home, camera: ui.camera.state)
    let runner = Task { await producer.run() }
    let started = ContinuousClock.now + .seconds(5)
    while port.commands.isEmpty, ContinuousClock.now < started { await Task.yield() }
    try #require(port.commands.count == 1)
    await producer.stop()
    await runner.value
    #expect(port.cancelled == 1 && port.errors.isEmpty)
    #expect(port.commands.map { $0.1.operation } == [.present, .end])
    #expect(port.commands.first?.1.id == port.commands.last?.1.id)
    #expect(port.commands.last?.1.revision == 2)
    #expect(port.contents.isEmpty)
    await ui.stop()
}

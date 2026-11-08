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
    await writer.begin(delegateID: "writer-run", goal: "画流程图")
    try await wait { ui.island.detailActivity?.owner.hasPrefix("writer:") == true }
    #expect(ui.island.detailActivity?.content.tone == .purple)
    #expect(ui.island.expanded)
    let id = try #require(ui.island.detailActivity?.id)
    try ui.island.publishSlot(
        owner: "test.voice",
        content: .init(
            title: "正在说话", primary: .symbol(name: "speaker.wave.2.fill"), priority: .high, secondary: .spectrum))
    #expect(ui.island.headerActivity?.content.primary == .symbol(name: "speaker.wave.2.fill"))
    try ui.island.setExpanded(false, id: id)
    await writer.update(delegateID: "writer-run", phase: .running, step: "正在绘制节点")
    try await wait { ui.island.detailActivity?.content.detail?.text?.contains("正在绘制节点") == true }
    #expect(ui.island.detailActivity?.id == id)
    #expect(!ui.island.expanded)
    await writer.update(delegateID: "writer-run", phase: .completed, step: "作品已保存")
    try await wait { ui.island.detailActivity == nil }
    #expect(ui.island.headerActivity?.owner == "test.voice")
    await writer.update(delegateID: "writer-run", phase: .running, step: "迟到进度")
    // Assistant Task logs are no longer a producer of Writer Island content.
    ui.home.activity.updateTask(
        .init(id: "stale", parentID: nil, requester: "assistant", executor: "writer", title: "旧日志", phase: .running),
        event: .init(id: "late", time: Date(), title: "旧步骤", detail: "不能覆盖"))
    try await Task.sleep(for: .milliseconds(30))
    #expect(ui.island.detailActivity == nil)
    #expect(!ui.island.activities.contains { $0.owner == "domain.writer" })
    await writer.stop()
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
    await writer.begin(delegateID: "old", goal: "旧任务")
    let deadline = ContinuousClock.now + .seconds(3)
    while await probe.calls == 0, ContinuousClock.now < deadline { await Task.yield() }
    #expect(await probe.calls == 1)
    for i in 0..<100 { await writer.update(delegateID: "old", phase: .running, step: "旧步骤 \(i)") }
    await writer.begin(delegateID: "new", goal: String(repeating: "长目标", count: 400))
    await writer.update(delegateID: "new", phase: .running, step: "新任务步骤")
    await writer.update(delegateID: "old", phase: .completed, step: "迟到旧终态")
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
    await writer.update(delegateID: "new", phase: .running, step: "迟到回调")
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
        await writer.begin(delegateID: run, goal: "测试终态")
        let start = ContinuousClock.now + .seconds(3)
        while state.detailActivity == nil, ContinuousClock.now < start { await Task.yield() }
        try #require(state.detailActivity != nil)
        await writer.update(delegateID: run, phase: .waitingUser)
        await writer.update(delegateID: run, phase: .cancelling)
        await writer.update(delegateID: run, phase: phase)
        let end = ContinuousClock.now + .seconds(3)
        while state.detailActivity != nil, ContinuousClock.now < end { await Task.yield() }
        #expect(state.activities.isEmpty)
        await writer.update(delegateID: run, phase: .running, step: "迟到")
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
    _ = try skills.control(
        "task.start", arguments: ["description": "测试前台目标"], inputID: input, fixed: fixed, taskID: "task_1")
    let content = try #require(AssistantExecutionSession.taskContent(skills))
    #expect(content.detail?.text == "测试前台目标")
    #expect(content.expansionID == skills.activeTaskID)
    _ = try skills.control("task.end", arguments: ["summary": "完成"], inputID: input, fixed: fixed)
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
        "task.start", arguments: ["description": "Assistant 独立前台目标"], inputID: UUID().uuidString, fixed: fixed,
        taskID: "task_1"
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

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func photographerAndApplicationControlPublishOwnActivitiesWithoutAssistant() async throws {
    let ui = UIContainer()
    try ui.start()
    let manager = AgentManager()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, configurations: AgentConfigurations.all())
    let input = InputGateway(manager: manager, policy: policy)
    let service = IslandPresentationService(state: ui.island)
    let assembly = try BehaviorAssembly(capabilityModules: [IslandModule(island: service)])
    let output = await OutputGateway(
        manager: manager, requests: input, tools: assembly.tools, policy: policy, sink: { _ in })
    let photographer = try PhotographerAgent(
        sessionID: UUID().uuidString, uiCamera: ui.camera,
        context: AgentContextRepository(
            agent: .photographer, scope: UUID().uuidString, state: PhotographerContextState()))
    let application = try ApplicationControlAgent(
        sessionID: UUID().uuidString,
        context: AgentContextRepository(
            agent: .applicationControl, scope: UUID().uuidString, state: ApplicationControlContextState()))
    let cameraSession = PhotographerExecutionSession(manager: manager, output: output, agent: photographer)
    let applicationSession = ApplicationControlExecutionSession(manager: manager, output: output, agent: application)
    try await cameraSession.prepareForInteraction()
    try await applicationSession.prepareForInteraction()
    func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }
    ui.camera.present(.countdown(3))
    try await wait { ui.island.headerActivity?.owner.hasPrefix("photographer:") == true }
    #expect(ui.island.headerActivity?.content.title == "拍照倒计时")
    try await application.observeConnection(.init(availability: .available, phase: .connected, recovery: .idle))
    try await wait { ui.island.activities.contains { $0.owner.hasPrefix("applicationControl:") } }
    ui.camera.present(.countdown(nil))
    try await wait { !ui.island.activities.contains { $0.owner.hasPrefix("photographer:") } }
    try await application.observeConnection(.init(availability: .poweredOff, phase: .idle, recovery: .idle))
    try await wait {
        ui.island.activities.contains { $0.owner.hasPrefix("applicationControl:") && $0.content.tone == .warning }
    }
    try await wait { ui.island.activities.isEmpty }
    ui.camera.present(.photoBusy(true))
    try await wait { ui.island.activities.contains { $0.owner.hasPrefix("photographer:") } }
    await cameraSession.shutdown()
    await applicationSession.shutdown()
    #expect(ui.island.activities.isEmpty)
    #expect(await photographer.presentationFailure == nil)
    #expect(await application.presentationFailure == nil)
    await output.shutdown()
    await ui.stop()
}

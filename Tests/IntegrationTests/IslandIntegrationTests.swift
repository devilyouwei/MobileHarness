import Actions
import AgentCore
import ExecutionRuntime
import Foundation
import FunctionContracts
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
    func publishDomain(_ owner: String, content: IslandContent?) throws { contents[owner] = content }
    func publishSpectrum(_ values: [Float], active: Bool) throws {}
    func reportIslandFailure(_ error: any Error) { errors.append(String(describing: error)) }
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

@Test @MainActor func islandTaskStartRequestsNativeAttentionAndEndRemovesIt() async throws {
    let ui = UIContainer()
    try ui.start()
    let service = IslandPresentationService(state: ui.island)
    let bridge = IslandDomainPresentation(service: service, home: ui.home, camera: ui.camera.state)
    let runner = Task { await bridge.run() }
    func waitFor(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate() && ContinuousClock.now < deadline { await Task.yield() }
        try #require(predicate())
    }
    ui.home.activity.present(.currentTaskTitle("拍摄照片"))
    ui.home.activity.present(.currentTaskStatus("准备相机"))
    ui.home.activity.present(.currentTaskID("task-1"))
    try await waitFor { ui.island.selected?.content.expansionID == "task-1" }
    #expect(ui.island.selected?.content.primary == .symbol(name: "scope"))
    #expect(ui.island.expanded && ui.island.detail?.text == "拍摄照片")
    for phase in [VoicePhase.listening, .speaking, .processing] {
        ui.home.conversation.voicePhase = phase
        try await waitFor {
            ui.island.headerActivity?.content.primary == IslandDomainPresentation.voiceContent(phase)?.primary
        }
        #expect(ui.island.expanded && ui.island.detail?.text == "拍摄照片")
        #expect(ui.island.detailActivity?.content.primary == .symbol(name: "scope"))
    }
    ui.camera.present(.countdown(3))
    try await waitFor { ui.island.headerActivity?.owner == "domain.camera" }
    #expect(ui.island.expanded && ui.island.detailActivity?.content.expansionID == "task-1")
    try ui.island.setExpanded(false)
    ui.home.activity.present(.currentTaskStatus("waitingUser"))
    try await waitFor { ui.island.detailActivity?.content.subtitle == "等待你的操作" }
    #expect(!ui.island.expanded)
    ui.home.activity.present(.currentTaskID("task-2"))
    try await waitFor { ui.island.selected?.content.expansionID == "task-2" }
    #expect(ui.island.expanded)
    ui.home.activity.present(.currentTaskID(nil))
    try await waitFor { ui.island.detailActivity == nil }
    #expect(!ui.island.expanded && ui.island.detail == nil)
    #expect(ui.island.headerActivity?.owner == "domain.camera")
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
    for (id, rank) in [(low, 30), (high, 90)] {
        try state.publish(
            id: id, owner: "fixture:island-test", revision: 1,
            content: .init(title: "详情", primary: .symbol(name: "scope"), rank: rank, detail: .init(text: "目标")),
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

import Actions
import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import Testing
import UI

@testable import Agents

private struct WindowToolsFixture: ToolModule { let definitions: [ActionBinding] }
@MainActor private func waitForWindowGateway(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw WindowError.unavailable }
        await Task.yield()
    }
}
@Test(.actionCatalog) @MainActor func windowButtonsCrossApplicationControlGatewayAndCanonicalActions() async throws {
    let ui = UIContainer()
    try ui.start()
    ui.windows.layout(width: 390, height: 750)
    let opening = Task { try await ui.windows.present(content: .init(rawValue: "test"), title: "Test") }
    try await waitForWindowGateway { !ui.windows.windows.isEmpty }
    let item = try #require(ui.windows.windows.first)
    ui.windows.complete(item.id, revision: item.revision, generation: ui.windows.generation, success: true)
    let id = try await opening.value
    let service = WindowExecutionService(state: ui.windows, lifecycles: [:])
    let bindings = try WindowModule(windows: service).definitions.map(BehaviorProtocolBindings.bind)
    let manager = AgentManager()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, configurations: AgentConfigurations.all())
    let input = InputGateway(manager: manager, policy: policy)
    let output = await OutputGateway(
        manager: manager, requests: input,
        tools: try ToolRegistry(modules: [WindowToolsFixture(definitions: bindings)]),
        actions: ChannelScheduler(registry: try ActionRegistry(definitions: bindings)), policy: policy, sink: { _ in })
    let host = ApplicationControlExecutionSession(
        manager: manager, output: output,
        agent: try ApplicationControlAgent(
            sessionID: UUID().uuidString, uiWindows: ui.windows,
            context: AgentContextRepository(
                agent: .applicationControl, scope: UUID().uuidString, state: ApplicationControlContextState())))
    try await host.prepareForInteraction()
    let minimized = Task { try await ui.windows.requests.submit(.init(id: id, command: .minimize)) }
    try await waitForWindowGateway { (try? ui.windows.find(id).mode) == .minimized }
    let receipt = try ui.windows.find(id)
    ui.windows.complete(id, revision: receipt.revision, generation: ui.windows.generation, success: true)
    try await minimized.value
    let closing = Task { try await ui.windows.requests.submitControl(.init(id: id, command: .close)) }
    try await waitForWindowGateway { (try? ui.windows.find(id).phase) == .closing }
    let exit = try ui.windows.find(id)
    ui.windows.complete(id, revision: exit.revision, generation: ui.windows.generation, success: true)
    try await closing.value
    #expect(ui.windows.windows.isEmpty)
    await host.shutdown()
    await service.stop()
    await ui.stop()
}
@Test(.actionCatalog) func windowSkillsShareAliasesWithoutExpandingBasicSkill() throws {
    let configuration = try AgentConfigurations.load(named: "Assistant")
    let shared = try AgentSkillLoader.registry(
        ["photography", "application-control"], fixed: configuration.capabilities)
    #expect(shared.actions.filter { $0.path.description.hasPrefix("UI.Window.") }.count == 6)
    let base = try AgentSkillLoader.registry(["basic-skill"], fixed: configuration.capabilities)
    #expect(!base.actions.contains { $0.path.description.hasPrefix("UI.Window.") })
}

@Test(.actionCatalog) func cameraIntentSkillsExposeSeparateVisionAndPhotoEntrypoints() throws {
    let fixed = try AgentConfigurations.load(named: "Assistant").capabilities
    let vision = try AgentSkillLoader.registry(["application-control"], fixed: fixed)
    let photo = try AgentSkillLoader.registry(["photography"], fixed: fixed)
    let base = try AgentSkillLoader.registry(["basic-skill"], fixed: fixed)
    for (alias, function) in [
        ("Vision.open", "openVision"), ("Vision.close", "closeVision"),
        ("Vision.flip", "flipVision"), ("Vision.retry", "retryVision"),
    ] {
        let action = try #require(vision.actions.first { $0.alias == alias })
        #expect(action.path.description == "Camera.Perception.\(function)")
    }
    #expect(!vision.actions.contains { $0.path.description.hasPrefix("Camera.Capture.") })
    #expect(!photo.actions.contains { $0.path.description.hasPrefix("Camera.Perception.") })
    #expect(photo.actions.first { $0.alias == "openCamera" }?.path.description == "Camera.Capture.open")
    #expect(photo.actions.first { $0.alias == "takePhoto" }?.path.description == "Camera.Capture.takePhoto")
    #expect(!base.actions.contains { $0.path.description.hasPrefix("Camera.") })
}

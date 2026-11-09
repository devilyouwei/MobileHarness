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

@Test(.actionCatalog) @MainActor
func conversationalAlbumNavigationUsesRegisteredAliasAndRealPresentation() async throws {
    let ui = UIContainer()
    try ui.start()
    let sessionID = UUID().uuidString
    let provider = ProviderPresentationAdapter(
        state: ui.settings.presentation, sessionID: sessionID,
        settings: ProviderSettingsRequests(service: ResourceProviderPersistence().service()))
    let presentation = ResourcePresentationAdapter(
        state: ui.modelResources.presentation, sessionID: sessionID, provider: provider,
        navigation: ui.navigation.presentation, acknowledge: {})
    let assembly = try BehaviorAssembly(capabilityModules: [NavigationModule(presentation: presentation)])
    let executor = ActionExecutor(registry: assembly.actions)
    let catalog = try AgentSkillLoader.registry(
        ["application-control"], fixed: AgentConfigurations.load(named: "Assistant").capabilities)
    var trace = GenerationTrace(capabilities: catalog, textMapping: AssistantAgent.mapText)
    try trace.append("<openPage destination=\"album\"/>")
    trace.finish()
    #expect(trace.parserError == nil && trace.calls.count == 1)
    let call = try #require(trace.calls.first)
    #expect(call.actionPath.description == "UI.Navigation.open")
    let input = AgentInput(id: UUID().uuidString, sessionID: sessionID, payload: .text("打开相册"))
    let result = try await executor.execute(ActionInvocation(source: .assistant, input: input, call: call))
    #expect(result == .completed)
    #expect(ui.navigation.state.path == [.settings, .album])
    #expect(ui.album.items.isEmpty)
    let declaration = try #require(NavigationModule.declarations.first { $0.path.description == "UI.Navigation.open" })
    #expect(declaration.parameters.first { $0.name == "destination" }?.constraints.contains("album") == true)

    for parameters in [
        ["destination": "memory"], ["destination": "nonexistent"], ["destination": "album", "extra": "true"],
    ] {
        let invalid = ActionCall(actionPath: call.actionPath, channel: call.channel, parameters: parameters)
        await #expect(throws: (any Error).self) {
            _ = try await executor.execute(ActionInvocation(source: .assistant, input: input, call: invalid))
        }
        #expect(ui.navigation.state.path == [.settings, .album])
    }
    ui.navigation.presentation.show(.settings)
    let stale = AgentInput(id: UUID().uuidString, sessionID: "stale-session", payload: .text("打开相册"))
    await #expect(throws: (any Error).self) {
        _ = try await executor.execute(ActionInvocation(source: .assistant, input: stale, call: call))
    }
    #expect(ui.navigation.state.path == [.settings])
    // Role availability is authorized by Agents before Gateway; this endpoint checks the live UI session.
    _ = try await executor.execute(ActionInvocation(source: .photographer, input: input, call: call))
    #expect(ui.navigation.state.path == [.settings, .album])
    await ui.stop()
}

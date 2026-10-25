import Actions
import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import StorageCache
import StorageCore
import Testing

@testable import Agents

private actor SpeechEntryProbe {
    private(set) var ids: [String] = []
    func accept(_ id: String) { ids.append(id) }
}
private func authoringInvocation(_ parameters: [String: String]) -> ActionInvocation {
    ActionInvocation(
        source: .assistant,
        input: AgentInput(
            id: UUID().uuidString, sessionID: UUID().uuidString, payload: .event("test")),
        call: ActionCall(
            actionPath: ActionPath(domain: "Speech", module: "Playback", function: "speak"), channel: "Voice",
            parameters: parameters))
}

@Test(.actionCatalog) func speechEntryRejectsInvalidTransportBeforeInvokingPlayback() async throws {
    let probe = SpeechEntryProbe()
    let id = UUID().uuidString
    for parameters in [
        [:], ["audioID": "invalid"], ["audioID": id, "text": "hidden synthesis"],
        ["audioID": String(repeating: "a", count: 37)],
    ] {
        await #expect(throws: SpeechActionError.missingAudio) {
            try await SpeechActions.speak(invocation: authoringInvocation(parameters)) { id, _ in await probe.accept(id)
            }
        }
    }
    #expect(await probe.ids.isEmpty)
    try await SpeechActions.speak(invocation: authoringInvocation(["audioID": id])) { id, _ in
        await probe.accept(id)
    }
    #expect(await probe.ids == [id])
}

private enum AuthoringFailure: Error { case device }
@Test(.actionCatalog) func speechEntryPreservesDependencyFailureAndPostEffectCancellation() async throws {
    let invocation = authoringInvocation(["audioID": UUID().uuidString])
    await #expect(throws: AuthoringFailure.self) {
        try await SpeechActions.speak(invocation: invocation) { _, _ in throw AuthoringFailure.device }
    }
    let probe = SpeechEntryProbe()
    let task = Task {
        try await SpeechActions.speak(invocation: invocation) { id, _ in
            await probe.accept(id)
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await probe.ids.count == 1)
}

private struct UnifiedAuthoringToolModule: ToolModule {
    let definitions: [ActionBinding]
}

private enum UnifiedAuthoringFixture {
    @Action(
        domain: "Fixture", module: "Control", title: "Shared native value",
        resources: [.init(rawValue: "fixtureResource")], timeout: .seconds(2))
    public static func shared() {}
}

@Test(.actionCatalog) func unifiedActionAttributeExecutesOneNativeHandlerThroughBothProtocols() async throws {
    let definition = ActionBinding(
        function: UnifiedAuthoringFixture.sharedDefinition(completing: { invocation in
            .value(try ActionArguments(invocation.call.parameters).requiredString("value", maximumUTF8Bytes: 32))
        }), protocols: [.action, .tool], executionPolicy: .direct, directResultPolicy: .returning
    )
    let actionRegistry = try ActionRegistry(definitions: [definition])
    let nativeRegistry = try ToolRegistry(modules: [UnifiedAuthoringToolModule(definitions: [definition])])
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .event("authoring"))
    let invocation = ActionInvocation(
        source: .assistant, input: input,
        call: ActionCall(
            actionPath: .init(domain: "Fixture", module: "Control", function: "shared"), channel: "Fixture",
            parameters: ["value": "same outcome"]))
    let scheduled = try await ActionExecutor(registry: actionRegistry).execute(invocation)
    let native = try #require(
        try await ToolExecutor(registry: nativeRegistry).execute(
            ToolRequest(
                id: UUID().uuidString, toolPath: "Fixture.Control.shared",
                arguments: ["value": "same outcome"]),
            context: invocation.context))
    #expect(scheduled == .value("same outcome"))
    #expect(native.completion == scheduled && native.value == "same outcome")
    #expect(definition.protocols == [.action, .tool])
    #expect(definition.resources == [.init(rawValue: "fixtureResource")])
    #expect(definition.timeout == .seconds(2))
}

import ActionRuntime
import Actions
import AgentCore
import Agents
import Foundation
import StorageAudio
import Testing

private actor SpeechEntryProbe {
    private(set) var ids: [UUID] = []
    func accept(_ id: UUID) { ids.append(id) }
}
private func authoringInvocation(_ parameters: [String: String]) -> ActionInvocation {
    ActionInvocation(
        source: .assistant, input: AgentInput(sessionID: UUID(), payload: .event("test")),
        call: ActionCall(
            actionPath: ActionPath(domain: "Speech", module: "Playback", function: "speak"), channel: "Voice",
            parameters: parameters))
}

@Test func speechEntryRejectsInvalidTransportBeforeInvokingPlayback() async throws {
    let probe = SpeechEntryProbe()
    let id = UUID()
    for parameters in [
        [:], ["audioID": "invalid"], ["audioID": id.uuidString, "text": "hidden synthesis"],
        ["audioID": String(repeating: "a", count: 37)],
    ] {
        await #expect(throws: SpeechActionError.missingAudio) {
            try await SpeechActions.speak(invocation: authoringInvocation(parameters)) { id, _ in await probe.accept(id)
            }
        }
    }
    #expect(await probe.ids.isEmpty)
    try await SpeechActions.speak(invocation: authoringInvocation(["audioID": id.uuidString])) { id, _ in
        await probe.accept(id)
    }
    #expect(await probe.ids == [id])
}

private enum AuthoringFailure: Error { case device }
@Test func speechEntryPreservesDependencyFailureAndPostEffectCancellation() async throws {
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

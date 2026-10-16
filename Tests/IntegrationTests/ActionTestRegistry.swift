import ActionBindings
import Actions
import AgentBindings
import AgentCore
import CallRuntime
import ExecutionRuntime
import FunctionContracts
import Gateway
import PlatformKit
import StorageCache

/// Explicit implementation metadata for generic scheduler fixtures, not production registration.
func testActionRegistry(handlers: [ActionPath: ActionHandler]) throws -> ActionRegistry {
    try ActionRegistry(
        definitions: handlers.map { path, handler in
            ActionBinding(
                path: path, displayName: "测试动作", kind: .finite, completion: "Fixture acknowledgment completed.",
                handler: handler)
        })
}

// Tests enter speech through the same argument decoder as the registered production Action.
extension SpeechPlayback {
    func play(
        _ invocation: any FunctionInput,
        using playback: @escaping @Sendable (AudioStream, any FunctionInput) async throws -> Void
    ) async throws {
        try await SpeechActions.speak(invocation: invocation) { id, invocation in
            try await self.play(audioID: id, invocation: invocation, using: playback)
        }
    }
}

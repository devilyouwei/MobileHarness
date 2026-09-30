/// Explicit built-in catalog: add modules here, never in the application host.
public enum ActionModules {
    public static func builtIn(
        presentation: any UIPresentationCapability, playback: any SpeechPlaybackCapability,
        gesture: @escaping @Sendable (NexArmActions.GestureRequest, ActionInvocation) async throws -> Void,
        shakeBase: @escaping @Sendable (Int, ActionInvocation) async throws -> Void
    ) -> [any ActionModule] {
        [
            SpeechActionModule(playback: playback), UIActionModule(presentation: presentation),
            NexArmBaseActionModule(move: shakeBase), NexArmGestureActionModule(perform: gesture),
        ]
    }
}

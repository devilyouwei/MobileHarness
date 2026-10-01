/// Explicit built-in catalog: add modules here, never in the application host.
public enum ActionModules {
    public static func builtIn(
        presentation: any UIPresentationCapability, playback: any SpeechPlaybackCapability,
        aim: @escaping @Sendable (Double, Double, ActionInvocation) async throws -> Void
    ) -> [any ActionModule] {
        [
            SpeechActionModule(playback: playback), UIActionModule(presentation: presentation),
            RobotActionModule(aim: aim),
        ]
    }
}

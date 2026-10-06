import FunctionContracts

/// One production catalog organized by business domain, independent of invocation protocol.
public enum CapabilityModules {
    public static func builtIn(
        presentation: any UIPresentationCapability & UIUpdateCapability, playback: any SpeechPlaybackCapability,
        pose: any PosePresentationCapability, historyPresentation: any HistoryPresentationCapability,
        camera: any CameraControlCapability, history: any HistoryQueryCapability,
        historyMutations: any HistoryMutationCapability,
        gesture: @escaping @Sendable (NexArmActions.GestureRequest, any FunctionInput) async throws -> Void,
        shakeBase: @escaping @Sendable (Int, any FunctionInput) async throws -> Void,
        aim: @escaping @Sendable (Double, Double, any FunctionInput) async throws -> Void
    ) -> [any CapabilityModule] {
        [
            UIModule(expression: presentation, pose: pose, updates: presentation, history: historyPresentation),
            SpeechModule(playback: playback), CameraModule(camera: camera),
            HistoryModule(history: history, mutations: historyMutations), SystemModule(),
            NexArmModule(perform: gesture, move: shakeBase, aim: aim),
        ]
    }
}

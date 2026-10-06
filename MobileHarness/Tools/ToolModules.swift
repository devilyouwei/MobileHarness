import ToolRuntime

public enum ToolModules {
    public static func builtIn(
        presentation: any PosePresentationCapability, updates: any UIUpdateCapability,
        historyPresentation: any HistoryPresentationCapability, camera: any CameraControlCapability,
        history: any HistoryQueryCapability,
        aim: @escaping @Sendable (Double, Double, ToolInvocation) async throws -> Void
    )
        -> [any ToolModule]
    {
        [
            SystemToolModule(),
            UIToolModule(presentation: presentation, updates: updates, history: historyPresentation),
            CameraToolModule(camera: camera), RobotToolModule(aim: aim), HistoryToolModule(history: history),
        ]
    }
}

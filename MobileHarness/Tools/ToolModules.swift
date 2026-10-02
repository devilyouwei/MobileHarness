import ToolRuntime

public enum ToolModules {
    public static func builtIn(
        presentation: any PosePresentationCapability, updates: any UIUpdateCapability,
        camera: any CameraControlCapability,
        aim: @escaping @Sendable (Double, Double, ToolInvocation) async throws -> Void
    )
        -> [any ToolModule]
    {
        [
            SystemToolModule(), UIToolModule(presentation: presentation, updates: updates),
            CameraToolModule(camera: camera), RobotToolModule(aim: aim),
        ]
    }
}

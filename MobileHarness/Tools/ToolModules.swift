import ToolRuntime

public enum ToolModules {
    public static func builtIn(
        presentation: any PosePresentationCapability, updates: any UIUpdateCapability,
        camera: any CameraControlCapability
    )
        -> [any ToolModule]
    {
        [
            SystemToolModule(), UIToolModule(presentation: presentation, updates: updates),
            CameraToolModule(camera: camera),
        ]
    }
}

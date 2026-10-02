import ToolRuntime

public enum ToolModules {
    public static func builtIn(presentation: any PosePresentationCapability, updates: any UIUpdateCapability)
        -> [any ToolModule]
    {
        [SystemToolModule(), UIToolModule(presentation: presentation, updates: updates)]
    }
}

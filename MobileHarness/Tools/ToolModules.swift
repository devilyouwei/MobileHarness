public enum ToolModules {
    public static func builtIn(presentation: any PosePresentationCapability) -> [any ToolModule] {
        [SystemToolModule(), UIToolModule(presentation: presentation)]
    }
}

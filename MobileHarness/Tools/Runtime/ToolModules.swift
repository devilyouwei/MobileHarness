public enum ToolModules {
    public static func builtIn(
        presentation: any PosePresentationCapability, updates: any UIUpdateCapability,
        aim: @escaping @Sendable (Double, Double, ToolInvocation) async throws -> Void
    ) -> [any ToolModule] {
        [
            SystemToolModule(), UIToolModule(presentation: presentation, updates: updates),
            RobotToolModule(aim: aim),
        ]
    }
}

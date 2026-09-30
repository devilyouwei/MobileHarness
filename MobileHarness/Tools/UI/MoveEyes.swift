import AgentCore

extension UITools {
    /// Screen-space target: -1 left/up, +1 right/down; zero looks straight ahead.
    public struct Gaze: Sendable, Equatable {
        public let x: Double
        public let y: Double
    }
    public enum GazeError: Error, Equatable, Sendable { case invalidTarget }

    public static func moveEyes(
        invocation: ToolInvocation,
        using present: @escaping @Sendable (Gaze, ToolInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let target: Gaze
        do {
            let arguments = CallArguments(invocation.call.arguments)
            try arguments.validateAllowedKeys(["x", "y"])
            target = try Gaze(
                x: arguments.requiredFiniteDouble("x", range: -1...1),
                y: arguments.requiredFiniteDouble("y", range: -1...1))
        } catch { throw GazeError.invalidTarget }
        try await present(target, invocation)
        try Task.checkCancellation()
    }
}

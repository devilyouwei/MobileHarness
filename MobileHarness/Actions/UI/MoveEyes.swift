import ActionRuntime

extension UIActions {
    /// Screen-space target: -1 left/up, +1 right/down; zero looks straight ahead.
    public struct Gaze: Sendable, Equatable {
        public let x: Double
        public let y: Double
    }
    public enum GazeError: Error, Equatable, Sendable { case invalidTarget }

    public static func moveEyes(
        invocation: ActionInvocation,
        present: @escaping @Sendable (Gaze, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard let rawX = invocation.call.parameters["x"], let x = Double(rawX),
            let rawY = invocation.call.parameters["y"], let y = Double(rawY),
            x.isFinite, y.isFinite, (-1...1).contains(x), (-1...1).contains(y)
        else { throw GazeError.invalidTarget }
        try await present(Gaze(x: x, y: y), invocation)
        try Task.checkCancellation()
    }
}

import ActionRuntime
import Foundation

/// UI.Gaze function ownership; current invocation paths remain compatible.
extension UIActions {
    @Tool(path: "UI.Gaze.moveEyes", title: "moveEyes")
    public static func moveEyes(
        invocation: ToolInvocation,
        using present: @escaping @Sendable (Gaze, ToolInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let target: Gaze
        do {
            let arguments = ToolArguments(invocation.call.arguments)
            try arguments.validateAllowedKeys(["x", "y"])
            target = try Gaze(
                x: arguments.requiredFiniteDouble("x", range: -1...1),
                y: arguments.requiredFiniteDouble("y", range: -1...1))
        } catch { throw GazeError.invalidTarget }
        try await present(target, invocation)
        try Task.checkCancellation()
    }
}

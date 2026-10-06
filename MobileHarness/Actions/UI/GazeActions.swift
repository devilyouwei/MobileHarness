import Foundation
import FunctionContracts

/// UI.Gaze function ownership; current invocation paths remain compatible.
extension UIActions {
    @Action(
        domain: "UI", module: "Gaze", title: "moveEyes", serializationKey: "UI")
    public static func moveEyes(
        invocation: any FunctionInput,
        using present: @escaping @Sendable (Gaze, any FunctionInput) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let target: Gaze
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["x", "y"])
            target = try Gaze(
                x: arguments.requiredFiniteDouble("x", range: -1...1),
                y: arguments.requiredFiniteDouble("y", range: -1...1))
        } catch { throw GazeError.invalidTarget }
        try await present(target, invocation)
        try Task.checkCancellation()
    }
}

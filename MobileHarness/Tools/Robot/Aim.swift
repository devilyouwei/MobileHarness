import Foundation
import ToolRuntime

extension RobotTools {
    public enum AimError: Error, Equatable, Sendable {
        case invalidAngle
        case notConnected
    }

    /// Returns once `send` accepts the logical angles. Does not wait for the arm to settle.
    @Tool(path: "Robot.aim", title: "aim")
    public static func aim(
        invocation: ToolInvocation,
        using send: @escaping @Sendable (Double, Double, ToolInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let base: Double
        let pitch: Double
        do {
            let arguments = ToolArguments(invocation.call.arguments)
            try arguments.validateAllowedKeys(["base", "pitch"])
            let limit = 4 * Double.pi
            base = try arguments.requiredFiniteDouble("base", range: -limit...limit)
            pitch = try arguments.requiredFiniteDouble("pitch", range: -limit...limit)
        } catch {
            throw AimError.invalidAngle
        }
        try await send(base, pitch, invocation)
        try Task.checkCancellation()
    }
}

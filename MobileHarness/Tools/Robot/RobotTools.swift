import Foundation
import ToolRuntime

public enum RobotTools {
    /// Returns once `send` accepts the logical angles. Does not wait for the arm to settle.
    @Tool(
        path: "Robot.aim", title: "aim",
        resources: [
            ToolResource(rawValue: "nexarm.motor.1"), ToolResource(rawValue: "nexarm.motor.2"),
            ToolResource(rawValue: "nexarm.motor.3"), ToolResource(rawValue: "nexarm.motor.4"),
            ToolResource(rawValue: "nexarm.motor.5"),
        ])
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

import AgentCore
import Foundation

extension RobotActions {
    public enum AimError: Error, Equatable, Sendable {
        case invalidAngle
        case notConnected
    }

    /// Completes once `send` accepts the logical angles. Does not wait for the arm to settle.
    public static func aim(
        invocation: ActionInvocation,
        using send: @escaping @Sendable (Double, Double, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let base: Double
        let pitch: Double
        do {
            let arguments = ActionArguments(invocation.call.parameters)
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

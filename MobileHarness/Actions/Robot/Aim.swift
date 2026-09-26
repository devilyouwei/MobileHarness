import ActionRuntime
import AgentCore
import Foundation

public enum RobotActions {
    public enum AimError: Error, Equatable, Sendable {
        case invalidAngle
    }

    /// Completes once `send` accepts the logical angles. Does not wait for the arm to settle.
    public static func aim(
        invocation: ActionInvocation,
        send: @escaping @Sendable (_ base: Double, _ pitch: Double, _ invocation: ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard let base = angle(invocation.call.parameters["base"]),
            let pitch = angle(invocation.call.parameters["pitch"])
        else { throw AimError.invalidAngle }
        try await send(base, pitch, invocation)
        try Task.checkCancellation()
    }

    private static func angle(_ raw: String?) -> Double? {
        guard let raw, let value = Double(raw), value.isFinite, abs(value) <= 4 * .pi else { return nil }
        return value
    }
}

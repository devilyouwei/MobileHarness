import Foundation
import FunctionContracts

extension NexArmActions {
    /// Publishes a latest target to the host-owned, resource-guarded worker.
    /// The publication itself holds no motor fence; it must remain available during tracking.
    @Action(
        domain: "NexArm", module: "Tracking", title: "aim")
    public static func aim(
        invocation: any FunctionInput,
        using send: @escaping @Sendable (Double, Double, any FunctionInput) async throws -> Void
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

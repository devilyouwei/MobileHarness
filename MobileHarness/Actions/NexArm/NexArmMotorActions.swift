import AgentCore

extension NexArmActions {
    @Action(
        module: "NexArm", title: "单舵机运动", kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        resources: NexArmRegistration.resources, timeout: NexArmRegistration.budget)
    public static func moveMotor(
        invocation: ActionInvocation,
        using perform: @escaping @Sendable (GestureRequest, ActionInvocation) async throws -> Void
    ) async throws { try await motor(invocation: invocation, reset: false, using: perform) }

    @Action(
        module: "NexArm", title: "单舵机归位", kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        resources: NexArmRegistration.resources, timeout: NexArmRegistration.budget)
    public static func resetMotor(
        invocation: ActionInvocation,
        using perform: @escaping @Sendable (GestureRequest, ActionInvocation) async throws -> Void
    ) async throws { try await motor(invocation: invocation, reset: true, using: perform) }

    private static func motor(
        invocation: ActionInvocation, reset: Bool,
        using perform: @escaping @Sendable (GestureRequest, ActionInvocation) async throws -> Void
    ) async throws {
        let args = ActionArguments(invocation.call.parameters)
        try args.validateAllowedKeys(
            reset ? ["motor", "speed", "acceleration"] : ["motor", "target", "speed", "acceleration"])
        let motor = try args.requiredInt("motor", range: 1...6)
        let target = reset ? nil : try args.requiredInt("target", range: 0...4095)
        let speed = try motionValue("speed", invocation, default: 1400, range: 1...1400)
        let acceleration = try motionValue("acceleration", invocation, default: 30, range: 1...254)
        try await perform(
            .init(
                gesture: reset ? .resetMotor : .moveMotor, repetitions: 1, motor: motor,
                target: target, speed: speed, acceleration: acceleration), invocation)
    }
}

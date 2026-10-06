import FunctionContracts

/// NexArm.Motion function ownership; current invocation paths remain compatible.
extension NexArmActions {
    @Action(
        domain: "NexArm", module: "Motion", title: "整臂归位", kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        serializationKey: "NexArm", resolvingResources: NexArmRegistration.resources,
        estimatingDuration: NexArmRegistration.budget)
    public static func reset(
        invocation: any FunctionInput,
        using perform: @escaping @Sendable (GestureRequest, any FunctionInput) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        try ActionArguments(invocation.call.parameters).validateAllowedKeys(["speed", "acceleration"])
        try await perform(
            GestureRequest(
                gesture: .reset, repetitions: 1,
                speed: try motionValue("speed", invocation, default: 1400, range: 1...1400),
                acceleration: try motionValue("acceleration", invocation, default: 30, range: 1...254)), invocation)
        try Task.checkCancellation()
    }

    @Action(
        domain: "NexArm", module: "Motion", title: "底座晃动", kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        serializationKey: "NexArm", resolvingResources: NexArmRegistration.resources,
        estimatingDuration: NexArmRegistration.budget)
    public static func shakeBase(
        invocation: any FunctionInput,
        using move: @escaping @Sendable (Int, any FunctionInput) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let cycles: Int
        do {
            let args = ActionArguments(invocation.call.parameters)
            try args.validateAllowedKeys(["cycles", "speed", "acceleration"])
            cycles = try args.requiredInt("cycles", range: 1...3)
        } catch { throw ShakeError.invalidCycles }
        try await move(cycles, invocation)
        try Task.checkCancellation()
    }

    @Action(
        domain: "NexArm", module: "Motion", title: "单舵机运动", kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        serializationKey: "NexArm", resolvingResources: NexArmRegistration.resources,
        estimatingDuration: NexArmRegistration.budget)
    public static func moveMotor(
        invocation: any FunctionInput,
        using perform: @escaping @Sendable (GestureRequest, any FunctionInput) async throws -> Void
    ) async throws { try await motor(invocation: invocation, reset: false, using: perform) }

    @Action(
        domain: "NexArm", module: "Motion", title: "单舵机归位", kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        serializationKey: "NexArm", resolvingResources: NexArmRegistration.resources,
        estimatingDuration: NexArmRegistration.budget)
    public static func resetMotor(
        invocation: any FunctionInput,
        using perform: @escaping @Sendable (GestureRequest, any FunctionInput) async throws -> Void
    ) async throws { try await motor(invocation: invocation, reset: true, using: perform) }

    private static func motor(
        invocation: any FunctionInput, reset: Bool,
        using perform: @escaping @Sendable (GestureRequest, any FunctionInput) async throws -> Void
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

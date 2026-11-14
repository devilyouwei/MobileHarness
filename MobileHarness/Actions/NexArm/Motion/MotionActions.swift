import FunctionContracts
import PlatformKit

/// NexArm.Motion function ownership; current invocation paths remain compatible.
extension NexArmActions {
    @Action(
        domain: "NexArm", module: "Motion", title: "Home arm",
        doc:
            "Reset configured homes for motors1–5; never move the gripper.",
        parameters: [
            .init(
                "speed", type: .integer, required: false, description: "Native motor speed, 1–1400; default1400.",
                constraints: "Native motor speed, 1–1400; default1400."),
            .init(
                "acceleration", type: .integer, required: false,
                description: "Native acceleration register value, 1–254; default30.",
                constraints: "Native acceleration register value, 1–254; default30."),
        ], kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        resolvingResources: NexArmRegistration.resources,
        dynamicTimeout: NexArmRegistration.budget)
    public static func reset(
        invocation: any FunctionInput,
        using perform: @escaping @Sendable (GestureRequest, any FunctionInput) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        try ActionArguments(invocation.call.parameters).validateAllowedKeys(["speed", "acceleration"])
        try await perform(
            GestureRequest(
                gesture: .reset, repetitions: 1,
                speed: try motionValue(
                    "speed", invocation, default: NexArmDeviceLimits.defaultSpeed, range: NexArmDeviceLimits.speed),
                acceleration: try motionValue(
                    "acceleration", invocation, default: NexArmDeviceLimits.defaultAcceleration,
                    range: NexArmDeviceLimits.acceleration)), invocation)
        try Task.checkCancellation()
    }

    @Action(
        domain: "NexArm", module: "Motion", title: "Wiggle base",
        doc:
            "Perform the configured base-shaking gesture and return home.",
        parameters: [
            .init(
                "cycles", type: .integer, required: true, description: "Number of complete left/right/return cycles.",
                constraints: "Integer 1 through 3 only."),
            .init(
                "speed", type: .integer, required: false, description: "Native motor speed, 1–1400; default1400.",
                constraints: "Native motor speed, 1–1400; default1400."),
            .init(
                "acceleration", type: .integer, required: false,
                description: "Native acceleration register value, 1–254; default30.",
                constraints: "Native acceleration register value, 1–254; default30."),
        ], kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        resolvingResources: NexArmRegistration.resources,
        dynamicTimeout: NexArmRegistration.budget)
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
        domain: "NexArm", module: "Motion", title: "Move motor",
        doc:
            "Move one motor: absolute counts OR relative degrees from fresh feedback. No return home.",
        parameters: [
            .init(
                "motor", type: .integer, required: true,
                description:
                    "1 base yaw; 2 shoulder lift; 3 elbow flex; 4 wrist pitch; 5 wrist roll; 6 gripper.",
                constraints: "Integer 1–6. Default reset homes cover 1–5."
            ),
            .init(
                "target", type: .integer, required: false,
                description: "Absolute encoder count, NOT degrees or displacement.",
                constraints:
                    "motor1=210–3826; motor2=200–3800; motor3=968–3200; motor4=728–3218; motor5=908–3128; motor6=1118–2828. Exclusive with deltaDegrees."
            ),
            .init(
                "deltaDegrees", type: .number, required: false,
                description:
                    "Relative degrees from fresh feedback; + increases counts. Motor1: + arm-right, - arm-left viewed from behind. 90°=1024 counts; not absolute degrees.",
                constraints:
                    "Finite -360…360; exclusive with target. Result must fit axis limits; missing feedback or excess travel rejects motion."
            ),
            .init(
                "speed", type: .integer, required: false,
                description:
                    "Native position speed; not degrees/s or duration.",
                constraints: "Integer 1–1400; default 1400."
            ),
            .init(
                "acceleration", type: .integer, required: false,
                description: "Native register value; not degrees/s².",
                constraints: "Integer 1–254; default 30."),
        ], kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        resolvingResources: NexArmRegistration.resources,
        dynamicTimeout: NexArmRegistration.budget)
    public static func moveMotor(
        invocation: any FunctionInput,
        using perform: @escaping @Sendable (GestureRequest, any FunctionInput) async throws -> Void
    ) async throws { try await motor(invocation: invocation, reset: false, using: perform) }

    @Action(
        domain: "NexArm", module: "Motion", title: "Home motor",
        doc:
            "Reset only the selected motor to its configured home; motor6 needs an explicitly configured home.",
        parameters: [
            .init(
                "motor", type: .integer, required: true,
                description:
                    "1 base yaw; 2 shoulder lift; 3 elbow flex; 4 wrist pitch; 5 wrist roll; 6 gripper.",
                constraints: "Integer 1–6. Default reset homes cover 1–5."
            ),
            .init(
                "speed", type: .integer, required: false,
                description:
                    "Native position speed; not degrees/s or duration.",
                constraints: "Integer 1–1400; default 1400."
            ),
            .init(
                "acceleration", type: .integer, required: false,
                description: "Native register value; not degrees/s².",
                constraints: "Integer 1–254; default 30."),
        ], kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        resolvingResources: NexArmRegistration.resources,
        dynamicTimeout: NexArmRegistration.budget)
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
            reset ? ["motor", "speed", "acceleration"] : ["motor", "target", "deltaDegrees", "speed", "acceleration"])
        let motor = try args.requiredInt("motor", range: NexArmDeviceLimits.motorIDs)
        let hasTarget = invocation.call.parameters["target"] != nil
        let hasDelta = invocation.call.parameters["deltaDegrees"] != nil
        guard reset || hasTarget != hasDelta else { throw NexArmExecutionError.invalidArguments }
        let target =
            hasTarget ? try args.requiredInt("target", range: NexArmMotorCommands.positionLimits[motor - 1]) : nil
        let delta =
            hasDelta ? try args.requiredFiniteDouble("deltaDegrees", range: NexArmDeviceLimits.relativeDegrees) : nil
        let speed = try motionValue(
            "speed", invocation, default: NexArmDeviceLimits.defaultSpeed, range: NexArmDeviceLimits.speed)
        let acceleration = try motionValue(
            "acceleration", invocation, default: NexArmDeviceLimits.defaultAcceleration,
            range: NexArmDeviceLimits.acceleration)
        try await perform(
            .init(
                gesture: reset ? .resetMotor : .moveMotor, repetitions: 1, motor: motor,
                target: target, deltaDegrees: delta, speed: speed, acceleration: acceleration), invocation)
    }
}

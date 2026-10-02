import ActionRuntime

/// Stateless, scheduled robot actions. Device completion belongs to the injected owner.
public enum NexArmActions {
    static func motionValue(
        _ key: String, _ invocation: ActionInvocation, default fallback: Int, range: ClosedRange<Int>
    ) throws -> Int {
        guard invocation.call.parameters[key] != nil else { return fallback }
        return try ActionArguments(invocation.call.parameters).requiredInt(key, range: range)
    }
    @Action(
        module: "NexArm", title: "整臂归位", kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        resources: NexArmRegistration.resources, timeout: NexArmRegistration.budget)
    public static func reset(
        invocation: ActionInvocation,
        using perform: @escaping @Sendable (GestureRequest, ActionInvocation) async throws -> Void
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
        module: "NexArm", title: "点头", kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        resources: NexArmRegistration.resources, timeout: NexArmRegistration.budget)
    public static func nodHead(
        invocation: ActionInvocation,
        using perform: @escaping @Sendable (GestureRequest, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let cycles: Int
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["cycles", "speed", "acceleration"])
            cycles = try arguments.requiredInt("cycles", range: 1...3)
        } catch { throw NodHeadError.invalidRepetitions }
        try await perform(
            GestureRequest(
                gesture: .nod, repetitions: cycles,
                speed: try motionValue("speed", invocation, default: 1400, range: 1...1400),
                acceleration: try motionValue("acceleration", invocation, default: 30, range: 1...254)), invocation)
        try Task.checkCancellation()
    }

    @Action(
        module: "NexArm", title: "摇头", kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        resources: NexArmRegistration.resources, timeout: NexArmRegistration.budget)
    public static func shakeHead(
        invocation: ActionInvocation,
        using perform: @escaping @Sendable (GestureRequest, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let cycles: Int
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["cycles", "speed", "acceleration"])
            cycles = try arguments.requiredInt("cycles", range: 1...3)
        } catch { throw ShakeHeadError.invalidRepetitions }
        try await perform(
            GestureRequest(
                gesture: .shakeHead, repetitions: cycles,
                speed: try motionValue("speed", invocation, default: 1400, range: 1...1400),
                acceleration: try motionValue("acceleration", invocation, default: 30, range: 1...254)), invocation)
        try Task.checkCancellation()
    }

    @Action(
        module: "NexArm", title: "挥手", kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        resources: NexArmRegistration.resources, timeout: NexArmRegistration.budget)
    public static func waveWrist(
        invocation: ActionInvocation,
        using perform: @escaping @Sendable (GestureRequest, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let count: Int
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["count", "speed", "acceleration"])
            count = try arguments.requiredInt("count", range: 1...3)
        } catch { throw WaveWristError.invalidRepetitions }
        try await perform(
            GestureRequest(
                gesture: .wave, repetitions: count,
                speed: try motionValue("speed", invocation, default: 1400, range: 1...1400),
                acceleration: try motionValue("acceleration", invocation, default: 30, range: 1...254)), invocation)
        try Task.checkCancellation()
    }

    @Action(
        module: "NexArm", title: "歪头", kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        resources: NexArmRegistration.resources, timeout: NexArmRegistration.budget)
    public static func tiltWrist(
        invocation: ActionInvocation,
        using perform: @escaping @Sendable (GestureRequest, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let direction: TiltDirection
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["direction", "speed", "acceleration"])
            direction = try arguments.requiredEnum("direction", as: TiltDirection.self)
        } catch { throw TiltWristError.invalidDirection }
        try await perform(
            GestureRequest(
                gesture: direction == .left ? .tiltLeft : .tiltRight, repetitions: 1,
                speed: try motionValue("speed", invocation, default: 1400, range: 1...1400),
                acceleration: try motionValue("acceleration", invocation, default: 30, range: 1...254)), invocation)
        try Task.checkCancellation()
    }

    @Action(
        module: "NexArm", title: "左右张望", kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        resources: NexArmRegistration.resources, timeout: NexArmRegistration.budget)
    public static func lookAround(
        invocation: ActionInvocation,
        using perform: @escaping @Sendable (GestureRequest, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let count: Int
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["cycles", "speed", "acceleration"])
            count = try arguments.requiredInt("cycles", range: 1...3)
        } catch { throw LookAroundError.invalidRepetitions }
        try await perform(
            GestureRequest(
                gesture: .lookAround, repetitions: count,
                speed: try motionValue("speed", invocation, default: 1400, range: 1...1400),
                acceleration: try motionValue("acceleration", invocation, default: 30, range: 1...254)), invocation)
        try Task.checkCancellation()
    }

    @Action(
        module: "NexArm", title: "庆祝", kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        resources: NexArmRegistration.resources, timeout: NexArmRegistration.budget)
    public static func celebrate(
        invocation: ActionInvocation,
        using perform: @escaping @Sendable (GestureRequest, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let count: Int
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["cycles", "speed", "acceleration"])
            count = try arguments.requiredInt("cycles", range: 1...3)
        } catch { throw CelebrateError.invalidRepetitions }
        try await perform(
            GestureRequest(
                gesture: .celebrate, repetitions: count,
                speed: try motionValue("speed", invocation, default: 1400, range: 1...1400),
                acceleration: try motionValue("acceleration", invocation, default: 30, range: 1...254)), invocation)
        try Task.checkCancellation()
    }

    @Action(
        module: "NexArm", title: "跳舞", kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        resources: NexArmRegistration.resources, timeout: NexArmRegistration.budget)
    public static func dance(
        invocation: ActionInvocation,
        using perform: @escaping @Sendable (GestureRequest, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let count: Int
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["cycles", "speed", "acceleration"])
            count = try arguments.requiredInt("cycles", range: 1...3)
        } catch { throw DanceError.invalidRepetitions }
        try await perform(
            GestureRequest(
                gesture: .dance, repetitions: count,
                speed: try motionValue("speed", invocation, default: 1400, range: 1...1400),
                acceleration: try motionValue("acceleration", invocation, default: 30, range: 1...254)), invocation)
        try Task.checkCancellation()
    }

    @Action(
        module: "NexArm", title: "底座晃动", kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        resources: NexArmRegistration.resources, timeout: NexArmRegistration.budget)
    public static func shakeBase(
        invocation: ActionInvocation,
        using move: @escaping @Sendable (Int, ActionInvocation) async throws -> Void
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
}

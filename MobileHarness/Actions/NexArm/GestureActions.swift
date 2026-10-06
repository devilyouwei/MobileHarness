import FunctionContracts

/// NexArm.Gesture function ownership; current invocation paths remain compatible.
extension NexArmActions {
    @Action(
        domain: "NexArm", module: "Gesture", title: "点头", kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        serializationKey: "NexArm", resolvingResources: NexArmRegistration.resources,
        estimatingDuration: NexArmRegistration.budget)
    public static func nodHead(
        invocation: any FunctionInput,
        using perform: @escaping @Sendable (GestureRequest, any FunctionInput) async throws -> Void
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
        domain: "NexArm", module: "Gesture", title: "摇头", kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        serializationKey: "NexArm", resolvingResources: NexArmRegistration.resources,
        estimatingDuration: NexArmRegistration.budget)
    public static func shakeHead(
        invocation: any FunctionInput,
        using perform: @escaping @Sendable (GestureRequest, any FunctionInput) async throws -> Void
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
        domain: "NexArm", module: "Gesture", title: "挥手", kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        serializationKey: "NexArm", resolvingResources: NexArmRegistration.resources,
        estimatingDuration: NexArmRegistration.budget)
    public static func waveWrist(
        invocation: any FunctionInput,
        using perform: @escaping @Sendable (GestureRequest, any FunctionInput) async throws -> Void
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
        domain: "NexArm", module: "Gesture", title: "歪头", kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        serializationKey: "NexArm", resolvingResources: NexArmRegistration.resources,
        estimatingDuration: NexArmRegistration.budget)
    public static func tiltWrist(
        invocation: any FunctionInput,
        using perform: @escaping @Sendable (GestureRequest, any FunctionInput) async throws -> Void
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
        domain: "NexArm", module: "Gesture", title: "左右张望", kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        serializationKey: "NexArm", resolvingResources: NexArmRegistration.resources,
        estimatingDuration: NexArmRegistration.budget)
    public static func lookAround(
        invocation: any FunctionInput,
        using perform: @escaping @Sendable (GestureRequest, any FunctionInput) async throws -> Void
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
        domain: "NexArm", module: "Gesture", title: "庆祝", kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        serializationKey: "NexArm", resolvingResources: NexArmRegistration.resources,
        estimatingDuration: NexArmRegistration.budget)
    public static func celebrate(
        invocation: any FunctionInput,
        using perform: @escaping @Sendable (GestureRequest, any FunctionInput) async throws -> Void
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
        domain: "NexArm", module: "Gesture", title: "跳舞", kind: .finite,
        completion: "Fresh arrival completes each motor; failures are aggregated and later steps continue.",
        serializationKey: "NexArm", resolvingResources: NexArmRegistration.resources,
        estimatingDuration: NexArmRegistration.budget)
    public static func dance(
        invocation: any FunctionInput,
        using perform: @escaping @Sendable (GestureRequest, any FunctionInput) async throws -> Void
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
}

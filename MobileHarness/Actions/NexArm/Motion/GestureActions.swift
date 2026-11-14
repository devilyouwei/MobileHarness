import FunctionContracts
import PlatformKit

/// NexArm.Gesture function ownership; current invocation paths remain compatible.
extension NexArmActions {
    @Action(
        domain: "NexArm", module: "Gesture", title: "Nod",
        doc:
            "Nod using motor4, returning home; leave other motors untouched.",
        parameters: [
            .init(
                "cycles", type: .integer, required: true,
                description: "Number of complete gestures, each containing two back-and-forth sweeps.",
                constraints: "Integer 1 through 3 only; no default."),
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
                speed: try motionValue(
                    "speed", invocation, default: NexArmDeviceLimits.defaultSpeed, range: NexArmDeviceLimits.speed),
                acceleration: try motionValue(
                    "acceleration", invocation, default: NexArmDeviceLimits.defaultAcceleration,
                    range: NexArmDeviceLimits.acceleration)), invocation)
        try Task.checkCancellation()
    }

    @Action(
        domain: "NexArm", module: "Gesture", title: "Shake head",
        doc:
            "Shake the head using motor5, returning home; leave other motors untouched.",
        parameters: [
            .init(
                "cycles", type: .integer, required: true,
                description: "Number of complete gestures, each containing two back-and-forth sweeps.",
                constraints: "Integer 1 through 3 only; no default."),
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
                speed: try motionValue(
                    "speed", invocation, default: NexArmDeviceLimits.defaultSpeed, range: NexArmDeviceLimits.speed),
                acceleration: try motionValue(
                    "acceleration", invocation, default: NexArmDeviceLimits.defaultAcceleration,
                    range: NexArmDeviceLimits.acceleration)), invocation)
        try Task.checkCancellation()
    }

    @Action(
        domain: "NexArm", module: "Gesture", title: "Wave",
        doc:
            "Wave the wrist with the configured arm gesture, then return home.",
        parameters: [
            .init(
                "count", type: .integer, required: true, description: "Number of complete gesture repetitions.",
                constraints: "Integer 1 through 3. No default."),
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
                speed: try motionValue(
                    "speed", invocation, default: NexArmDeviceLimits.defaultSpeed, range: NexArmDeviceLimits.speed),
                acceleration: try motionValue(
                    "acceleration", invocation, default: NexArmDeviceLimits.defaultAcceleration,
                    range: NexArmDeviceLimits.acceleration)), invocation)
        try Task.checkCancellation()
    }

    @Action(
        domain: "NexArm", module: "Gesture", title: "Tilt head",
        doc:
            "Tilt the wrist in the requested direction and return home.",
        parameters: [
            .init(
                "direction", type: .string, required: true, description: "Tilt direction relative to the arm.",
                constraints: "Exactly left or right."),
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
                speed: try motionValue(
                    "speed", invocation, default: NexArmDeviceLimits.defaultSpeed, range: NexArmDeviceLimits.speed),
                acceleration: try motionValue(
                    "acceleration", invocation, default: NexArmDeviceLimits.defaultAcceleration,
                    range: NexArmDeviceLimits.acceleration)), invocation)
        try Task.checkCancellation()
    }

    @Action(
        domain: "NexArm", module: "Gesture", title: "Look around",
        doc:
            "Perform the configured arm look-around gesture and return home.",
        parameters: [
            .init(
                "cycles", type: .integer, required: true, description: "Number of complete gesture repetitions.",
                constraints: "Integer 1 through 3. No default."),
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
                speed: try motionValue(
                    "speed", invocation, default: NexArmDeviceLimits.defaultSpeed, range: NexArmDeviceLimits.speed),
                acceleration: try motionValue(
                    "acceleration", invocation, default: NexArmDeviceLimits.defaultAcceleration,
                    range: NexArmDeviceLimits.acceleration)), invocation)
        try Task.checkCancellation()
    }

    @Action(
        domain: "NexArm", module: "Gesture", title: "Celebrate",
        doc:
            "Perform the configured celebration gesture and return home.",
        parameters: [
            .init(
                "cycles", type: .integer, required: true, description: "Number of complete gesture repetitions.",
                constraints: "Integer 1 through 3. No default."),
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
                speed: try motionValue(
                    "speed", invocation, default: NexArmDeviceLimits.defaultSpeed, range: NexArmDeviceLimits.speed),
                acceleration: try motionValue(
                    "acceleration", invocation, default: NexArmDeviceLimits.defaultAcceleration,
                    range: NexArmDeviceLimits.acceleration)), invocation)
        try Task.checkCancellation()
    }

    @Action(
        domain: "NexArm", module: "Gesture", title: "Dance",
        doc:
            "Perform the configured arm dance and return home.",
        parameters: [
            .init(
                "cycles", type: .integer, required: true, description: "Number of complete gesture repetitions.",
                constraints: "Integer 1 through 3. No default."),
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
                speed: try motionValue(
                    "speed", invocation, default: NexArmDeviceLimits.defaultSpeed, range: NexArmDeviceLimits.speed),
                acceleration: try motionValue(
                    "acceleration", invocation, default: NexArmDeviceLimits.defaultAcceleration,
                    range: NexArmDeviceLimits.acceleration)), invocation)
        try Task.checkCancellation()
    }
}

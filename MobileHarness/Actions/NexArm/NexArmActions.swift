/// Stateless, scheduled robot actions. Device completion belongs to the injected owner.
public enum NexArmActions {
    public static func nodHead(
        invocation: ActionInvocation,
        using perform: @escaping @Sendable (GestureRequest, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let cycles: Int
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["cycles"])
            cycles = try arguments.requiredInt("cycles", range: 1...3)
        } catch { throw NodHeadError.invalidRepetitions }
        try await perform(GestureRequest(gesture: .nod, repetitions: cycles), invocation)
        try Task.checkCancellation()
    }

    public static func shakeHead(
        invocation: ActionInvocation,
        using perform: @escaping @Sendable (GestureRequest, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let cycles: Int
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["cycles"])
            cycles = try arguments.requiredInt("cycles", range: 1...3)
        } catch { throw ShakeHeadError.invalidRepetitions }
        try await perform(GestureRequest(gesture: .shakeHead, repetitions: cycles), invocation)
        try Task.checkCancellation()
    }

    public static func waveWrist(
        invocation: ActionInvocation,
        using perform: @escaping @Sendable (GestureRequest, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let count: Int
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["count"])
            count = try arguments.requiredInt("count", range: 1...3)
        } catch { throw WaveWristError.invalidRepetitions }
        try await perform(GestureRequest(gesture: .wave, repetitions: count), invocation)
        try Task.checkCancellation()
    }

    public static func tiltWrist(
        invocation: ActionInvocation,
        using perform: @escaping @Sendable (GestureRequest, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let direction: TiltDirection
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["direction"])
            direction = try arguments.requiredEnum("direction", as: TiltDirection.self)
        } catch { throw TiltWristError.invalidDirection }
        try await perform(
            GestureRequest(gesture: direction == .left ? .tiltLeft : .tiltRight, repetitions: 1), invocation)
        try Task.checkCancellation()
    }

    public static func lookAround(
        invocation: ActionInvocation,
        using perform: @escaping @Sendable (GestureRequest, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let count: Int
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["cycles"])
            count = try arguments.requiredInt("cycles", range: 1...3)
        } catch { throw LookAroundError.invalidRepetitions }
        try await perform(GestureRequest(gesture: .lookAround, repetitions: count), invocation)
        try Task.checkCancellation()
    }

    public static func celebrate(
        invocation: ActionInvocation,
        using perform: @escaping @Sendable (GestureRequest, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let count: Int
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["cycles"])
            count = try arguments.requiredInt("cycles", range: 1...3)
        } catch { throw CelebrateError.invalidRepetitions }
        try await perform(GestureRequest(gesture: .celebrate, repetitions: count), invocation)
        try Task.checkCancellation()
    }

    public static func dance(
        invocation: ActionInvocation,
        using perform: @escaping @Sendable (GestureRequest, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let count: Int
        do {
            let arguments = ActionArguments(invocation.call.parameters)
            try arguments.validateAllowedKeys(["cycles"])
            count = try arguments.requiredInt("cycles", range: 1...3)
        } catch { throw DanceError.invalidRepetitions }
        try await perform(GestureRequest(gesture: .dance, repetitions: count), invocation)
        try Task.checkCancellation()
    }

    public static func shakeBase(
        invocation: ActionInvocation,
        using move: @escaping @Sendable (Int, ActionInvocation) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let cycles: Int
        do {
            let args = ActionArguments(invocation.call.parameters)
            try args.validateAllowedKeys(["cycles"])
            cycles = try args.requiredInt("cycles", range: 1...3)
        } catch { throw ShakeError.invalidCycles }
        try await move(cycles, invocation)
        try Task.checkCancellation()
    }
}

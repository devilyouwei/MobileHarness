import ActionRuntime

/// Motor, gesture, base and tracking behavior share one domain catalog.
public struct NexArmModule: CapabilityModule {
    private let perform: @Sendable (NexArmActions.GestureRequest, ActionInvocation) async throws -> Void
    private let move: @Sendable (Int, ActionInvocation) async throws -> Void
    private let aim: @Sendable (Double, Double, ToolInvocation) async throws -> Void
    public init(
        perform: @escaping @Sendable (NexArmActions.GestureRequest, ActionInvocation) async throws -> Void,
        move: @escaping @Sendable (Int, ActionInvocation) async throws -> Void,
        aim: @escaping @Sendable (Double, Double, ToolInvocation) async throws -> Void
    ) {
        self.perform = perform
        self.move = move
        self.aim = aim
    }
    public var definitions: [ActionDefinition] { scheduledDefinitions + directDefinitions }
    private var scheduledDefinitions: [ActionDefinition] {
        Self.gestureDefinitions(perform: perform) + Self.baseDefinitions(move: move)
    }
    private var directDefinitions: [ToolDefinition] { Self.trackingDefinitions(aim: aim) }
    static func trackingDefinitions(
        aim: @escaping @Sendable (Double, Double, ToolInvocation) async throws -> Void
    ) -> [ToolDefinition] {
        [
            NexArmActions.aimDefinition(completing: { [aim] call, context in
                try await NexArmActions.aim(invocation: ToolInvocation(call: call, context: context), using: aim)
            })
        ]
    }

    static func gestureDefinitions(
        perform: @escaping @Sendable (NexArmActions.GestureRequest, ActionInvocation) async throws -> Void
    ) -> [ActionDefinition] {
        [
            NexArmActions.moveMotorDefinition { [perform] in
                try await NexArmActions.moveMotor(invocation: $0, using: perform)
            },
            NexArmActions.resetMotorDefinition { [perform] in
                try await NexArmActions.resetMotor(invocation: $0, using: perform)
            },
            NexArmActions.resetDefinition { [perform] invocation in
                try await NexArmActions.reset(invocation: invocation, using: perform)
            },
            NexArmActions.nodHeadDefinition { [perform] invocation in
                try await NexArmActions.nodHead(invocation: invocation, using: perform)
            },
            NexArmActions.shakeHeadDefinition { [perform] invocation in
                try await NexArmActions.shakeHead(invocation: invocation, using: perform)
            },
            NexArmActions.waveWristDefinition { [perform] invocation in
                try await NexArmActions.waveWrist(invocation: invocation, using: perform)
            },
            NexArmActions.tiltWristDefinition { [perform] invocation in
                try await NexArmActions.tiltWrist(invocation: invocation, using: perform)
            },
            NexArmActions.lookAroundDefinition { [perform] invocation in
                try await NexArmActions.lookAround(invocation: invocation, using: perform)
            },
            NexArmActions.celebrateDefinition { [perform] invocation in
                try await NexArmActions.celebrate(invocation: invocation, using: perform)
            },
            NexArmActions.danceDefinition { [perform] invocation in
                try await NexArmActions.dance(invocation: invocation, using: perform)
            },
        ]
    }
    static func baseDefinitions(
        move: @escaping @Sendable (Int, ActionInvocation) async throws -> Void
    ) -> [ActionDefinition] {
        [
            NexArmActions.shakeBaseDefinition { [move] invocation in
                try await NexArmActions.shakeBase(invocation: invocation, using: move)
            }
        ]
    }
}

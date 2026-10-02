import ActionRuntime

/// One control domain: all gestures share NexArm module exclusion.
public struct NexArmGestureActionModule: ActionModule {
    private let perform: @Sendable (NexArmActions.GestureRequest, ActionInvocation) async throws -> Void
    public init(perform: @escaping @Sendable (NexArmActions.GestureRequest, ActionInvocation) async throws -> Void) {
        self.perform = perform
    }
    public var definitions: [ActionDefinition] {
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
}

/// Model-callable bounded base sweep; the host must supply an explicit device binding.
public struct NexArmBaseActionModule: ActionModule {
    private let move: @Sendable (Int, ActionInvocation) async throws -> Void
    public init(move: @escaping @Sendable (Int, ActionInvocation) async throws -> Void) { self.move = move }
    public var definitions: [ActionDefinition] {
        [
            NexArmActions.shakeBaseDefinition { [move] invocation in
                try await NexArmActions.shakeBase(invocation: invocation, using: move)
            }
        ]
    }
}

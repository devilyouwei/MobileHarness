import AgentCore

/// One control domain: all gestures share NexArm module exclusion.
public struct NexArmGestureActionModule: ActionModule {
    private let perform: @Sendable (NexArmActions.GestureRequest, ActionInvocation) async throws -> Void
    public init(perform: @escaping @Sendable (NexArmActions.GestureRequest, ActionInvocation) async throws -> Void) {
        self.perform = perform
    }
    public var definitions: [ActionDefinition] {
        [
            ActionDefinition(
                path: ActionPath(module: "NexArm", function: "nodHead"), displayName: "点头", kind: .finite,
                completion:
                    "Observed home preparation, repeated single-motor sweep with encoder arrival, and observed stable home ending."
            ) { [perform] invocation in
                try await NexArmActions.nodHead(invocation: invocation, using: perform)
            },
            ActionDefinition(
                path: ActionPath(module: "NexArm", function: "shakeHead"), displayName: "摇头", kind: .finite,
                completion:
                    "Observed home preparation, repeated single-motor sweep with encoder arrival, and observed stable home ending."
            ) { [perform] invocation in
                try await NexArmActions.shakeHead(invocation: invocation, using: perform)
            },
            ActionDefinition(
                path: ActionPath(module: "NexArm", function: "waveWrist"), displayName: "挥手", kind: .finite,
                completion:
                    "Settings-matched timed Cartesian playback, followed by fresh stable final-home telemetry; intermediate waypoints are not individually verified."
            ) { [perform] invocation in
                try await NexArmActions.waveWrist(invocation: invocation, using: perform)
            },
            ActionDefinition(
                path: ActionPath(module: "NexArm", function: "tiltWrist"), displayName: "歪头", kind: .finite,
                completion:
                    "Settings-matched timed Cartesian playback, followed by fresh stable final-home telemetry; intermediate waypoints are not individually verified."
            ) { [perform] invocation in
                try await NexArmActions.tiltWrist(invocation: invocation, using: perform)
            },
            ActionDefinition(
                path: ActionPath(module: "NexArm", function: "lookAround"), displayName: "左右张望", kind: .finite,
                completion:
                    "Settings-matched timed Cartesian playback, followed by fresh stable final-home telemetry; intermediate waypoints are not individually verified."
            ) { [perform] invocation in
                try await NexArmActions.lookAround(invocation: invocation, using: perform)
            },
            ActionDefinition(
                path: ActionPath(module: "NexArm", function: "celebrate"), displayName: "庆祝", kind: .finite,
                completion:
                    "Settings-matched timed Cartesian playback, followed by fresh stable final-home telemetry; intermediate waypoints are not individually verified."
            ) { [perform] invocation in
                try await NexArmActions.celebrate(invocation: invocation, using: perform)
            },
            ActionDefinition(
                path: ActionPath(module: "NexArm", function: "dance"), displayName: "跳舞", kind: .finite,
                completion:
                    "Settings-matched timed Cartesian playback, followed by fresh stable final-home telemetry; intermediate waypoints are not individually verified."
            ) { [perform] invocation in
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
            ActionDefinition(
                path: ActionPath(module: "NexArm", function: "shakeBase"), displayName: "底座晃动", kind: .finite,
                completion:
                    "Bounded base sequence with observed final position; production Cartesian playback shares Settings frames and verifies stable final home."
            ) { [move] invocation in
                try await NexArmActions.shakeBase(invocation: invocation, using: move)
            }
        ]
    }
}

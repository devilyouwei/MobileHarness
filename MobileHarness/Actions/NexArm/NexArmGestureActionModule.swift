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
                path: ActionPath(module: "NexArm", function: "waveWrist"), kind: .finite,
                completion:
                    "Fixed Cartesian preparation, coordinated choreography and home ending; each pose is observed and final home settles in three telemetry samples."
            ) { [perform] invocation in
                try await NexArmActions.waveWrist(invocation: invocation, using: perform)
            },
            ActionDefinition(
                path: ActionPath(module: "NexArm", function: "tiltWrist"), kind: .finite,
                completion:
                    "Fixed Cartesian preparation, coordinated choreography and home ending; each pose is observed and final home settles in three telemetry samples."
            ) { [perform] invocation in
                try await NexArmActions.tiltWrist(invocation: invocation, using: perform)
            },
            ActionDefinition(
                path: ActionPath(module: "NexArm", function: "lookAround"), kind: .finite,
                completion:
                    "Fixed Cartesian preparation, coordinated choreography and home ending; each pose is observed and final home settles in three telemetry samples."
            ) { [perform] invocation in
                try await NexArmActions.lookAround(invocation: invocation, using: perform)
            },
            ActionDefinition(
                path: ActionPath(module: "NexArm", function: "celebrate"), kind: .finite,
                completion:
                    "Fixed Cartesian preparation, coordinated choreography and home ending; each pose is observed and final home settles in three telemetry samples."
            ) { [perform] invocation in
                try await NexArmActions.celebrate(invocation: invocation, using: perform)
            },
            ActionDefinition(
                path: ActionPath(module: "NexArm", function: "dance"), kind: .finite,
                completion:
                    "Fixed Cartesian preparation, coordinated choreography and home ending; each pose is observed and final home settles in three telemetry samples."
            ) { [perform] invocation in
                try await NexArmActions.dance(invocation: invocation, using: perform)
            },
        ]
    }
}

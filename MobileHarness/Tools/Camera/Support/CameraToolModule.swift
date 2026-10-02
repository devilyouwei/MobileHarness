import ToolRuntime

/// Host owns permission, capture leases and foreground lifecycle.
public protocol CameraControlCapability: Sendable {
    func setEnabled(_ enabled: Bool, invocation: ToolInvocation) async throws
    func flip(invocation: ToolInvocation) async throws
}

public enum CameraControlError: Error, Equatable, Sendable {
    case notForeground
    case busy
    case disabled
    case permissionDenied
    case unavailable
}

public struct CameraToolModule: ToolModule {
    private let camera: any CameraControlCapability
    public init(camera: any CameraControlCapability) { self.camera = camera }
    public var definitions: [ToolDefinition] {
        [
            CameraTools.openDefinition(completing: { [camera] call, context in
                try await CameraTools.open(invocation: ToolInvocation(call: call, context: context), using: camera)
            }),
            CameraTools.closeDefinition(completing: { [camera] call, context in
                try await CameraTools.close(invocation: ToolInvocation(call: call, context: context), using: camera)
            }),
            CameraTools.flipDefinition(completing: { [camera] call, context in
                try await CameraTools.flip(invocation: ToolInvocation(call: call, context: context), using: camera)
            }),
        ]
    }
}

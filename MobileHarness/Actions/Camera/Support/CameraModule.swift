import ActionRuntime

/// Host owns permission, capture leases and foreground lifecycle.
public protocol CameraControlCapability: Sendable {
    func setEnabled(_ enabled: Bool, invocation: ToolInvocation) async throws
    func flip(invocation: ToolInvocation) async throws
}

public enum CameraControlError: Error, Equatable, Sendable, ToolExecutionFailureProviding {
    case notForeground
    case busy
    case disabled
    case permissionDenied
    case unavailable
    public var toolFailureCode: ToolResponse.FailureCode {
        switch self {
        case .permissionDenied: .permissionDenied
        case .notForeground: .init(rawValue: "background")
        case .busy: .init(rawValue: "busy")
        case .disabled: .init(rawValue: "disabled")
        case .unavailable: .init(rawValue: "unavailable")
        }
    }
}

public struct CameraModule: CapabilityModule {
    private let camera: any CameraControlCapability
    public init(camera: any CameraControlCapability) { self.camera = camera }
    public var definitions: [ToolDefinition] {
        [
            CameraActions.openDefinition(completing: { [camera] call, context in
                try await CameraActions.open(invocation: ToolInvocation(call: call, context: context), using: camera)
            }),
            CameraActions.closeDefinition(completing: { [camera] call, context in
                try await CameraActions.close(invocation: ToolInvocation(call: call, context: context), using: camera)
            }),
            CameraActions.flipDefinition(completing: { [camera] call, context in
                try await CameraActions.flip(invocation: ToolInvocation(call: call, context: context), using: camera)
            }),
        ]
    }
}

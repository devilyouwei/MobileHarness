import FunctionContracts

/// Host owns permission, capture leases and foreground lifecycle.
extension CameraActions {
    public enum Facing: String, Sendable { case front, back }
}

public protocol CameraControlCapability: Sendable {
    func setEnabled(_ enabled: Bool, invocation: any FunctionInput) async throws
    func retry(invocation: any FunctionInput) async throws
    func flip(_ facing: CameraActions.Facing, invocation: any FunctionInput) async throws
}

public enum CameraControlError: Error, Equatable, Sendable, ActionExecutionFailureProviding {
    case notForeground
    case busy
    case disabled
    case permissionDenied
    case unavailable
    public var executionFailureCode: ActionExecutionFailureCode {
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
    public var definitions: [ActionFunction] {
        [
            CameraActions.retryDefinition(handler: { [camera] invocation in
                try await CameraActions.retry(invocation: invocation, using: camera)
            }),
            CameraActions.openDefinition(handler: { [camera] invocation in
                try await CameraActions.open(invocation: invocation, using: camera)
            }),
            CameraActions.closeDefinition(handler: { [camera] invocation in
                try await CameraActions.close(invocation: invocation, using: camera)
            }),
            CameraActions.flipDefinition(handler: { [camera] invocation in
                try await CameraActions.flip(invocation: invocation, using: camera)
            }),
        ]
    }
}

extension CameraControlCapability {
    public func retry(invocation: any FunctionInput) async throws { try await setEnabled(true, invocation: invocation) }
}

import Foundation
import FunctionContracts

/// Camera invocation admission and typed forwarding. Native ownership stays with CameraCoordinator.
@MainActor public final class CameraExecutionEndpoint: CameraControlCapability {
    private let camera: any CameraControlCapability
    private let rootSessionID: String
    private let validateSession: @MainActor (any FunctionInput) throws -> Void
    public init(
        camera: any CameraControlCapability, rootSessionID: String,
        validateSession: @escaping @MainActor (any FunctionInput) throws -> Void
    ) {
        self.camera = camera
        self.rootSessionID = rootSessionID
        self.validateSession = validateSession
    }
    private func validate(_ invocation: any FunctionInput) throws {
        if invocation.context.sessionID != rootSessionID { try validateSession(invocation) }
    }
    public func savePhoto(_ id: String?, invocation: any FunctionInput) async throws -> CameraPhotoCommandReceipt {
        try validate(invocation)
        return try await camera.savePhoto(id, invocation: invocation)
    }
    public func ignorePhoto(_ id: String?, invocation: any FunctionInput) async throws -> CameraPhotoCommandReceipt {
        try validate(invocation)
        return try await camera.ignorePhoto(id, invocation: invocation)
    }
    public func takePhoto(invocation: any FunctionInput) async throws -> CameraPhotoReceipt {
        try validate(invocation)
        return try await camera.takePhoto(invocation: invocation)
    }
    public func readPhoto(_ id: String, source: String, sessionID: String, inputID: String) async throws -> Data {
        try await camera.readPhoto(id, source: source, sessionID: sessionID, inputID: inputID)
    }
    public func setEnabled(_ enabled: Bool, invocation: any FunctionInput) async throws {
        try validate(invocation)
        try await camera.setEnabled(enabled, invocation: invocation)
    }
    public func flip(_ facing: CameraActions.Facing, invocation: any FunctionInput) async throws {
        try validate(invocation)
        try await camera.flip(facing, invocation: invocation)
    }
    public func retry(invocation: any FunctionInput) async throws {
        try validate(invocation)
        try await camera.retry(invocation: invocation)
    }
}

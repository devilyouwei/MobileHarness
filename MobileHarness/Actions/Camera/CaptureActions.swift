import Foundation
import FunctionContracts

/// Camera.Capture function ownership; current invocation paths remain compatible.
extension CameraActions {
    @Action(domain: "Camera", module: "Capture", title: "savePhoto", serializationKey: "Camera", timeout: .seconds(60))
    public static func savePhoto(invocation: any FunctionInput, using camera: any CameraControlCapability) async throws
        -> String
    {
        let id = try selectedPhotoID(invocation)
        try Task.checkCancellation()
        return String(
            decoding: try JSONEncoder().encode(await camera.savePhoto(id, invocation: invocation)), as: UTF8.self)
    }

    @Action(domain: "Camera", module: "Capture", title: "ignorePhoto", serializationKey: "Camera")
    public static func ignorePhoto(invocation: any FunctionInput, using camera: any CameraControlCapability)
        async throws
        -> String
    {
        let id = try selectedPhotoID(invocation)
        try Task.checkCancellation()
        return String(
            decoding: try JSONEncoder().encode(await camera.ignorePhoto(id, invocation: invocation)), as: UTF8.self)
    }

    private static func selectedPhotoID(_ invocation: any FunctionInput) throws -> UUID? {
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["photoID"])
        guard invocation.call.parameters["photoID"] != nil else { return nil }
        let raw = try arguments.requiredString("photoID", maximumUTF8Bytes: 36)
        guard let id = UUID(uuidString: raw) else { throw ActionArguments.ValidationError.invalidValue("photoID") }
        return id
    }

    @Action(domain: "Camera", module: "Capture", title: "takePhoto", serializationKey: "Camera", timeout: .seconds(15))
    public static func takePhoto(invocation: any FunctionInput, using camera: any CameraControlCapability) async throws
        -> String
    {
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        try Task.checkCancellation()
        let receipt = try await camera.takePhoto(invocation: invocation)
        return String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
    }

    @Action(domain: "Camera", module: "Capture", title: "retry", serializationKey: "Camera")
    public static func retry(invocation: any FunctionInput, using camera: any CameraControlCapability) async throws {
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        try Task.checkCancellation()
        try await camera.retry(invocation: invocation)
    }
    @Action(
        domain: "Camera", module: "Capture", title: "open", serializationKey: "Camera")
    public static func open(invocation: any FunctionInput, using camera: any CameraControlCapability) async throws
        -> String
    {
        try Task.checkCancellation()
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        try await camera.setEnabled(true, invocation: invocation)
        try Task.checkCancellation()
        return String(
            decoding: try JSONEncoder().encode(CameraCommandReceipt(operation: "open", enabled: true)), as: UTF8.self)
    }

    @Action(
        domain: "Camera", module: "Capture", title: "close", serializationKey: "Camera")
    public static func close(invocation: any FunctionInput, using camera: any CameraControlCapability) async throws
        -> String
    {
        try Task.checkCancellation()
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        try await camera.setEnabled(false, invocation: invocation)
        try Task.checkCancellation()
        return String(
            decoding: try JSONEncoder().encode(CameraCommandReceipt(operation: "close", enabled: false)), as: UTF8.self)
    }

    @Action(
        domain: "Camera", module: "Capture", title: "flip", serializationKey: "Camera")
    public static func flip(invocation: any FunctionInput, using camera: any CameraControlCapability) async throws
        -> String
    {
        try Task.checkCancellation()
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["facing"])
        let facing = try arguments.requiredEnum("facing", as: CameraActions.Facing.self)
        try await camera.flip(facing, invocation: invocation)
        try Task.checkCancellation()
        return String(
            decoding: try JSONEncoder().encode(CameraCommandReceipt(operation: "flip", facing: facing)), as: UTF8.self)
    }
}

import FunctionContracts

/// Camera.Capture function ownership; current invocation paths remain compatible.
extension CameraActions {
    @Action(
        domain: "Camera", module: "Capture", title: "open", serializationKey: "Camera")
    public static func open(invocation: any FunctionInput, using camera: any CameraControlCapability) async throws {
        try Task.checkCancellation()
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        try await camera.setEnabled(true, invocation: invocation)
        try Task.checkCancellation()
    }

    @Action(
        domain: "Camera", module: "Capture", title: "close", serializationKey: "Camera")
    public static func close(invocation: any FunctionInput, using camera: any CameraControlCapability) async throws {
        try Task.checkCancellation()
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        try await camera.setEnabled(false, invocation: invocation)
        try Task.checkCancellation()
    }

    @Action(
        domain: "Camera", module: "Capture", title: "flip", serializationKey: "Camera")
    public static func flip(invocation: any FunctionInput, using camera: any CameraControlCapability) async throws {
        try Task.checkCancellation()
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        try await camera.flip(invocation: invocation)
        try Task.checkCancellation()
    }
}

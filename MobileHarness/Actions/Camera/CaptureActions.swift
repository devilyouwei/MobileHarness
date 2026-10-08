import FunctionContracts

/// Camera.Capture function ownership; current invocation paths remain compatible.
extension CameraActions {
    @Action(domain: "Camera", module: "Capture", title: "retry", serializationKey: "Camera")
    public static func retry(invocation: any FunctionInput, using camera: any CameraControlCapability) async throws {
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        try Task.checkCancellation()
        try await camera.retry(invocation: invocation)
    }
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
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["facing"])
        let facing = try arguments.requiredEnum("facing", as: CameraActions.Facing.self)
        try await camera.flip(facing, invocation: invocation)
        try Task.checkCancellation()
    }
}

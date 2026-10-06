import ActionRuntime

/// Camera.Capture function ownership; current invocation paths remain compatible.
extension CameraActions {
    @Tool(path: "Camera.Capture.open", title: "open")
    public static func open(invocation: ToolInvocation, using camera: any CameraControlCapability) async throws {
        try Task.checkCancellation()
        try ToolArguments(invocation.call.arguments).validateAllowedKeys([])
        try await camera.setEnabled(true, invocation: invocation)
        try Task.checkCancellation()
    }

    @Tool(path: "Camera.Capture.close", title: "close")
    public static func close(invocation: ToolInvocation, using camera: any CameraControlCapability) async throws {
        try Task.checkCancellation()
        try ToolArguments(invocation.call.arguments).validateAllowedKeys([])
        try await camera.setEnabled(false, invocation: invocation)
        try Task.checkCancellation()
    }

    @Tool(path: "Camera.Capture.flip", title: "flip")
    public static func flip(invocation: ToolInvocation, using camera: any CameraControlCapability) async throws {
        try Task.checkCancellation()
        try ToolArguments(invocation.call.arguments).validateAllowedKeys([])
        try await camera.flip(invocation: invocation)
        try Task.checkCancellation()
    }
}

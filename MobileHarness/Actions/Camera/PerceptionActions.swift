import FunctionContracts

/// Background visual/following controls. No photo window is created by these functions.
extension CameraActions {
    @Action(
        domain: "Camera", module: "Perception", title: "open",
        doc: "Enable background vision and following, sharing the native camera. Does not open photography.",
        parameters: [], timeout: .seconds(60))
    public static func openVision(invocation: any FunctionInput, using camera: any CameraControlCapability) async throws
    {
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        try await camera.setPerceptionEnabled(true, invocation: invocation)
    }
    @Action(
        domain: "Camera", module: "Perception", title: "close",
        doc: "Stop background vision and following. Photography remains independent.", parameters: [],
        timeout: .seconds(60))
    public static func closeVision(invocation: any FunctionInput, using camera: any CameraControlCapability)
        async throws
    {
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        try await camera.setPerceptionEnabled(false, invocation: invocation)
    }
    @Action(
        domain: "Camera", module: "Perception", title: "retry",
        doc: "Retry background vision on explicit request without opening photography.", parameters: [],
        timeout: .seconds(60))
    public static func retryVision(invocation: any FunctionInput, using camera: any CameraControlCapability)
        async throws
    {
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        try await camera.setPerceptionEnabled(true, invocation: invocation)
    }
    @Action(
        domain: "Camera", module: "Perception", title: "flip",
        doc:
            "Switch the shared native lens only when background vision is the topmost visible camera surface. An expanded visible photo window owns switching instead.",
        parameters: [.init("facing", type: .string, required: true, description: "front or back")])
    public static func flipVision(invocation: any FunctionInput, using camera: any CameraControlCapability) async throws
    {
        let args = ActionArguments(invocation.call.parameters)
        try args.validateAllowedKeys(["facing"])
        let facing = try args.requiredEnum("facing", as: CameraActions.Facing.self)
        try Task.checkCancellation()
        try await camera.flipPerception(facing, invocation: invocation)
    }
}

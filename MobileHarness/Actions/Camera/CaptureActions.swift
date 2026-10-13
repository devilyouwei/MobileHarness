import Foundation
import FunctionContracts

/// Camera.Capture function ownership; current invocation paths remain compatible.
extension CameraActions {
    @Action(
        domain: "Camera", module: "Capture", title: "savePhoto",
        doc:
            "Save the displayed photo to Photos, join departure animation/cue and remove the preview. Import failure retains the photo. Receipt distinguishes committed save from feedbackIssues; repeated exact saved UUID does not duplicate import.",
        parameters: [
            .init(
                "photoID", type: .string, required: true, description: "Exact captured photo UUID.",
                constraints: "A photoID from actual capture feedback.")
        ], timeout: .seconds(60))
    public static func savePhoto(invocation: any FunctionInput, using camera: any CameraControlCapability) async throws
        -> String
    {
        let id = try selectedPhotoID(invocation)
        try Task.checkCancellation()
        return String(
            decoding: try JSONEncoder().encode(await camera.savePhoto(id, invocation: invocation)), as: UTF8.self)
    }

    @Action(
        domain: "Camera", module: "Capture", title: "ignorePhoto",
        doc:
            "Join the displayed preview's discard animation/cue and remove it. Does not delete album photos or private image evidence. Receipt includes optional feedbackIssues; camera remains open.",
        parameters: [
            .init(
                "photoID", type: .string, required: true, description: "Exact captured photo UUID.",
                constraints: "A photoID from actual capture feedback.")
        ])
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

    @Action(
        domain: "Camera", module: "Capture", title: "takePhoto",
        doc:
            "Capture once with the ready foreground camera, show preview and return photoID/image evidence. Does not save to Photos.",
        parameters: [], timeout: .seconds(15))
    public static func takePhoto(invocation: any FunctionInput, using camera: any CameraControlCapability) async throws
        -> String
    {
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        try Task.checkCancellation()
        let receipt = try await camera.takePhoto(invocation: invocation)
        return String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
    }

    @Action(
        domain: "Camera", module: "Capture", title: "retry",
        doc:
            "Retry a failed foreground camera operation on explicit user request.",
        parameters: [])
    public static func retry(invocation: any FunctionInput, using camera: any CameraControlCapability) async throws {
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        try Task.checkCancellation()
        try await camera.retry(invocation: invocation)
    }
    @Action(
        domain: "Camera", module: "Capture", title: "open",
        doc:
            "Enable camera preview/vision; permission is required. Returns capture readiness, not pose-model readiness.",
        parameters: [])
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
        domain: "Camera", module: "Capture", title: "close",
        doc:
            "Disable camera preview/vision and join cleanup. Returns the resulting camera state.",
        parameters: [])
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
        domain: "Camera", module: "Capture", title: "flip",
        doc:
            "Select the requested lens on an enabled camera. Already-selected lens is unchanged; disabled/busy/unavailable fails. Returns lens state.",
        parameters: [
            .init(
                "facing", type: .string, required: true, description: "Requested front or back lens.",
                constraints: "front or back; change only when requested.")
        ])
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

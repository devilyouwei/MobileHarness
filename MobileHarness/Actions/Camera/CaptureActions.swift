import Foundation
import FunctionContracts
import StorageCore

/// Camera.Capture function ownership; current invocation paths remain compatible.
extension CameraActions {
    @Action(
        domain: "Camera", module: "Capture", title: "savePhoto",
        doc:
            "Collect the preview into the App album, then join departure/cue. Failure retains preview. Receipt reports committed save and feedbackIssues; repeated exact saved ID is idempotent. Phone Photos export is only in the album page.",
        parameters: [
            .init(
                "mediaID", type: .string, required: true, description: "Exact captured photo String.",
                constraints: "A mediaID from actual capture feedback.")
        ], timeout: .seconds(60))
    public static func savePhoto(invocation: any FunctionInput, using camera: any CameraControlCapability) async throws
        -> String
    {
        let id = try selectedMediaID(invocation)
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
                "mediaID", type: .string, required: true, description: "Exact captured photo String.",
                constraints: "A mediaID from actual capture feedback.")
        ])
    public static func ignorePhoto(invocation: any FunctionInput, using camera: any CameraControlCapability)
        async throws
        -> String
    {
        let id = try selectedMediaID(invocation)
        try Task.checkCancellation()
        return String(
            decoding: try JSONEncoder().encode(await camera.ignorePhoto(id, invocation: invocation)), as: UTF8.self)
    }

    private static func selectedMediaID(_ invocation: any FunctionInput) throws -> String? {
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["mediaID"])
        guard invocation.call.parameters["mediaID"] != nil else { return nil }
        let raw = try arguments.requiredString("mediaID", maximumUTF8Bytes: 36)
        guard let id = BusinessRecordID(rawValue: raw), id.kind == .media else {
            throw ActionArguments.ValidationError.invalidValue("mediaID")
        }
        return id.rawValue
    }

    @Action(
        domain: "Camera", module: "Capture", title: "takePhoto",
        doc:
            "Open or restore the Camera window, prepare photo mode and capture once; return mediaID/image evidence. No separate openCamera needed. Does not save to Photos.",
        parameters: [], timeout: .seconds(110))
    public static func takePhoto(invocation: any FunctionInput, using camera: any CameraControlCapability) async throws
        -> String
    {
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        try Task.checkCancellation()
        let receipt = try await CameraCaptureWorkflow.run(
            invocation: invocation, camera: camera, capture: "takePhoto", timeout: .seconds(50)
        ) {
            try await camera.takePhoto(invocation: invocation)
        }
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
            "Present the Camera window and start capture after permission. Returns readiness and windowID; capture failure retains a retryable window.",
        parameters: [], timeout: .seconds(60))
    public static func open(invocation: any FunctionInput, using camera: any CameraControlCapability) async throws
        -> String
    {
        try Task.checkCancellation()
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        try await camera.setEnabled(true, invocation: invocation)
        try Task.checkCancellation()
        return String(
            decoding: try JSONEncoder().encode(
                CameraCommandReceipt(operation: "open", enabled: true, windowID: await camera.windowID())),
            as: UTF8.self)
    }

    @Action(
        domain: "Camera", module: "Capture", title: "close",
        doc:
            "Close the Camera window after photo disposition and joined capture cleanup. Cancel retains the window.",
        parameters: [], timeout: .seconds(60))
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
            "Select the shared lens only when the visible photo window owns lens control. Minimized/covered/disabled/busy/unavailable fails. Returns the confirmed lens.",
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

extension CameraActions {
    @Action(
        domain: "Camera", module: "Capture", title: "设置拍摄",
        doc:
            "Replace capture settings before capture. Omitted values default to photo, no delay, flash off, 1x, 600s maximum video. Read current settings to preserve other choices. Unsupported hardware settings fail.",
        parameters: [
            .init("mode", required: false, description: "Photo or video mode.", values: ["photo", "video"]),
            .init(
                "delaySeconds", type: .integer, required: false, description: "Photo countdown.",
                constraints: "0...30 seconds"),
            .init("flash", required: false, description: "Photo flash mode.", values: ["off", "on", "auto"]),
            .init(
                "zoom", type: .number, required: false, description: "Shared camera zoom.",
                constraints: "1...6; actual device maximum applies"),
            .init(
                "durationSeconds", type: .integer, required: false, description: "Video automatic stop limit.",
                constraints: "1...600 seconds"),
        ])
    public static func configure(invocation: any FunctionInput, using camera: any CameraControlCapability) async throws
        -> String
    {
        let a = ActionArguments(invocation.call.parameters)
        try a.validateAllowedKeys(["mode", "delaySeconds", "flash", "zoom", "durationSeconds"])
        let p = invocation.call.parameters
        let settings = CameraCaptureSettings(
            mode: p["mode"] == nil ? "photo" : try a.requiredString("mode", maximumUTF8Bytes: 5),
            delaySeconds: p["delaySeconds"] == nil ? 0 : try a.requiredInt("delaySeconds", range: 0...30),
            flash: p["flash"] == nil ? "off" : try a.requiredString("flash", maximumUTF8Bytes: 4),
            zoom: p["zoom"] == nil ? 1 : try a.requiredFiniteDouble("zoom", range: 1...6),
            durationSeconds: p["durationSeconds"] == nil ? 600 : try a.requiredInt("durationSeconds", range: 1...600))
        try settings.validate()
        try Task.checkCancellation()
        try await camera.configureCapture(settings, invocation: invocation)
        return String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
    }
    @Action(
        domain: "Camera", module: "Capture", title: "取消倒计时",
        doc: "Cancel and join a pending photo countdown. Does not discard a captured photo or stop video.",
        parameters: [])
    public static func cancelCapture(invocation: any FunctionInput, using camera: any CameraControlCapability)
        async throws -> String
    {
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        try await camera.cancelCapture(invocation: invocation)
        return "{\"countdown\":null}"
    }
}

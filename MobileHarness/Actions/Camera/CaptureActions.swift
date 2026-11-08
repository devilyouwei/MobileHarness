import Foundation
import FunctionContracts
import StorageCore

/// Camera.Capture owns capture, preview selection and disposition.
extension CameraActions {
    @Action(
        domain: "Camera", module: "Capture", title: "savePhoto",
        doc:
            "Save the exact current-session preview original to the App album, mark it saved and unload it from model State. Keep the cached original available to browse or load again until eviction/Camera close. Failure preserves the prior status. Repeated save is idempotent; feedbackIssues do not undo a committed save.",
        parameters: [
            .init(
                "previewID", type: .string, required: true, description: "Exact cached preview identity.",
                constraints: "A previewID from capture feedback or actions.camera.preview State.")
        ], timeout: .seconds(60))
    public static func savePhoto(invocation: any FunctionInput, using camera: any CameraControlCapability) async throws
        -> String
    {
        let id = try selectedPreviewID(invocation)
        try Task.checkCancellation()
        return String(
            decoding: try JSONEncoder().encode(await camera.savePhoto(id, invocation: invocation)), as: UTF8.self)
    }

    @Action(
        domain: "Camera", module: "Capture", title: "ignorePhoto",
        doc:
            "Mark the exact current-session preview ignored and unload its State selections, retaining the original for browsing or loading again. Does not delete album photos; already saved photos cannot be ignored. Receipt includes optional feedbackIssues.",
        parameters: [
            .init(
                "previewID", type: .string, required: true, description: "Exact cached preview identity.",
                constraints: "A previewID from capture feedback or actions.camera.preview State.")
        ])
    public static func ignorePhoto(invocation: any FunctionInput, using camera: any CameraControlCapability)
        async throws
        -> String
    {
        let id = try selectedPreviewID(invocation)
        try Task.checkCancellation()
        return String(
            decoding: try JSONEncoder().encode(await camera.ignorePhoto(id, invocation: invocation)), as: UTF8.self)
    }

    private static func selectedPreviewID(_ invocation: any FunctionInput) throws -> String? {
        let arguments = ActionArguments(invocation.call.parameters)
        try arguments.validateAllowedKeys(["previewID"])
        guard invocation.call.parameters["previewID"] != nil else { return nil }
        let raw = try arguments.requiredString("previewID", maximumUTF8Bytes: 64)
        guard let id = PreviewImageID(rawValue: raw) else {
            throw ActionArguments.ValidationError.invalidValue("previewID")
        }
        return id.rawValue
    }

    @Action(
        domain: "Camera", module: "Capture", title: "takePhoto",
        doc:
            "Open or restore the Camera window, prepare photo mode and capture once; return previewID/image evidence. No separate openCamera needed. Keeps the original in temporary memory; does not save to an album.",
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

extension CameraActions {
    @Action(
        domain: "Camera", module: "Capture", title: "加载预览图片",
        doc:
            "Load a cached preview into multimodal State across turns. Selects at most three explicit images plus the latest; FIFO eviction can expire selections. Saved or ignored images still in the session cache can be loaded. Does not change the UI or read the album.",
        parameters: [.init("previewID", required: true, description: "Exact previewID from actions.camera.preview.")])
    public static func loadPreviewImage(invocation: any FunctionInput, using camera: any CameraControlCapability)
        async throws -> String
    {
        guard let id = try selectedPreviewID(invocation) else { throw CameraControlError.photoUnavailable }
        return try await camera.loadPreviewImage(id, invocation: invocation)
    }
    @Action(
        domain: "Camera", module: "Capture", title: "卸载预览图片",
        doc:
            "Remove an explicit image selection without deleting cached bytes. The latest photo remains loaded automatically.",
        parameters: [.init("previewID", required: true, description: "Exact previewID from actions.camera.preview.")])
    public static func unloadPreviewImage(invocation: any FunctionInput, using camera: any CameraControlCapability)
        async throws -> String
    {
        guard let id = try selectedPreviewID(invocation) else { throw CameraControlError.photoUnavailable }
        return try await camera.unloadPreviewImage(id, invocation: invocation)
    }
}

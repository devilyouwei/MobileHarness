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
        domain: "Camera", module: "Capture", title: "saveAllPhotos",
        doc:
            "Save all unsaved photos in the current Camera session to the App album. Returns saved items and individual failures.",
        parameters: [], timeout: .seconds(120))
    public static func saveAllPhotos(invocation: any FunctionInput, using camera: any CameraControlCapability)
        async throws -> String
    {
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        try Task.checkCancellation()
        let receipt = try await camera.saveAllPhotos(invocation: invocation)
        return String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
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
            "Present the Camera window and start capture after permission. Wait for the first ready preview. On failure the window remains available for retry.",
        parameters: [], timeout: .seconds(60))
    public static func open(invocation: any FunctionInput, using camera: any CameraControlCapability) async throws {
        try Task.checkCancellation()
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        try await camera.setEnabled(true, invocation: invocation)
        try Task.checkCancellation()
    }

    @Action(
        domain: "Camera", module: "Capture", title: "close",
        doc:
            "Close the Camera window directly and clear temporary photos after joining capture cleanup. Save or discard pending video explicitly first.",
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
            "Update only supplied capture settings. Omitted fields retain their current values. Unsupported hardware settings fail.",
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
    {
        let a = ActionArguments(invocation.call.parameters)
        try a.validateAllowedKeys(["mode", "delaySeconds", "flash", "zoom", "durationSeconds"])
        let p = invocation.call.parameters
        let settings = CameraCaptureSettings.Update(
            mode: p["mode"] == nil ? nil : try a.requiredString("mode", maximumUTF8Bytes: 5),
            delaySeconds: p["delaySeconds"] == nil ? nil : try a.requiredInt("delaySeconds", range: 0...30),
            flash: p["flash"] == nil ? nil : try a.requiredString("flash", maximumUTF8Bytes: 4),
            zoom: p["zoom"] == nil ? nil : try a.requiredFiniteDouble("zoom", range: 1...6),
            durationSeconds: p["durationSeconds"] == nil ? nil : try a.requiredInt("durationSeconds", range: 1...600))
        guard settings.mode.map({ ["photo", "video"].contains($0) }) ?? true,
            settings.flash.map({ ["off", "on", "auto"].contains($0) }) ?? true
        else { throw ActionArguments.ValidationError.invalidValue("captureSettings") }
        try Task.checkCancellation()
        try await camera.configureCapture(settings, invocation: invocation)
    }
    @Action(
        domain: "Camera", module: "Capture", title: "取消倒计时",
        doc: "Cancel and join a pending photo countdown. Does not discard a captured photo or stop video.",
        parameters: [])
    public static func cancelCapture(invocation: any FunctionInput, using camera: any CameraControlCapability)
        async throws
    {
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        try await camera.cancelCapture(invocation: invocation)
    }
}

extension CameraActions {
    @Action(
        domain: "Camera", module: "Capture", title: "加载预览图片",
        doc:
            "Load up to five cached photos into multimodal State. Supply one previewID to append, or a JSON array previewIDs to replace selections. The latest photo fills a free slot. Use actual IDs from actions.camera.preview.",
        parameters: [
            .init("previewID", required: false, description: "One cached previewID to append."),
            .init("previewIDs", required: false, description: "JSON array of one to five unique cached previewIDs."),
        ])
    public static func loadPreviewImage(invocation: any FunctionInput, using camera: any CameraControlCapability)
        async throws -> String
    {
        let parameters = invocation.call.parameters
        if parameters["previewIDs"] != nil {
            let arguments = ActionArguments(parameters)
            try arguments.validateAllowedKeys(["previewIDs"])
            let value = try arguments.requiredString("previewIDs", maximumUTF8Bytes: 512)
            guard let ids = try? JSONDecoder().decode([String].self, from: Data(value.utf8)),
                (1...CameraPreviewStore.maximumLoadedPhotos).contains(ids.count),
                Set(ids).count == ids.count, ids.allSatisfy({ PreviewImageID(rawValue: $0) != nil })
            else { throw ActionArguments.ValidationError.invalidValue("previewIDs") }
            return try await camera.loadPreviewImages(ids, invocation: invocation)
        }
        guard let id = try selectedPreviewID(invocation) else { throw CameraControlError.photoUnavailable }
        return try await camera.loadPreviewImage(id, invocation: invocation)
    }
    @Action(
        domain: "Camera", module: "Capture", title: "卸载预览图片",
        doc:
            "Remove an explicit image selection without deleting cached bytes. The latest photo remains loaded automatically.",
        parameters: [.init("previewID", required: true, description: "Exact previewID from actions.camera.preview.")])
    public static func unloadPreviewImage(invocation: any FunctionInput, using camera: any CameraControlCapability)
        async throws
    {
        guard let id = try selectedPreviewID(invocation) else { throw CameraControlError.photoUnavailable }
        try await camera.unloadPreviewImage(id, invocation: invocation)
    }
}

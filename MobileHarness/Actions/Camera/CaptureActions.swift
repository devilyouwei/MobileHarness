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
            "Capture once with the ready foreground camera, show preview and return mediaID/image evidence. Does not save to Photos.",
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

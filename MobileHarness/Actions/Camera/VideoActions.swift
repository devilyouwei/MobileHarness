import Foundation
import FunctionContracts

extension CameraActions {
    @Action(
        domain: "Camera", module: "Video", title: "开始录像",
        doc:
            "Start one video with audio in the ready video-mode window. Pause listening until recording ends. Waits for native recording start, not file completion. Maximum duration is configured, at most 600 seconds; 512 MiB file bound.",
        parameters: [], timeout: .seconds(60))
    public static func startRecording(invocation: any FunctionInput, using camera: any CameraControlCapability)
        async throws -> String
    {
        try ActionArguments(invocation.call.parameters).validateAllowedKeys([])
        try Task.checkCancellation()
        return String(
            decoding: try JSONEncoder().encode(await camera.startRecording(invocation: invocation)), as: UTF8.self)
    }
    @Action(
        domain: "Camera", module: "Video", title: "结束录像",
        doc:
            "Stop this recording and wait for file finalization. Returns ready clip; does not collect into the App album.",
        parameters: [.init("recordingID", description: "Actual recording ID from start or current facts.")],
        timeout: .seconds(60))
    public static func stopRecording(invocation: any FunctionInput, using camera: any CameraControlCapability)
        async throws -> String
    {
        let id = try recordingID(invocation)
        return String(
            decoding: try JSONEncoder().encode(await camera.stopRecording(id, invocation: invocation)), as: UTF8.self)
    }
    @Action(
        domain: "Camera", module: "Video", title: "保存录像",
        doc:
            "Explicitly collect the finalized current clip into the App album. Can retry failed file preparation on user request; never records again.",
        parameters: [.init("recordingID", description: "Actual current recording ID.")], timeout: .seconds(60))
    public static func saveVideo(invocation: any FunctionInput, using camera: any CameraControlCapability) async throws
        -> String
    {
        let id = try recordingID(invocation)
        return String(
            decoding: try JSONEncoder().encode(await camera.saveVideo(id, invocation: invocation)), as: UTF8.self)
    }
    @Action(
        domain: "Camera", module: "Video", title: "忽略录像",
        doc: "Discard the uncollected current clip after recording has finished; never deletes a saved album item.",
        parameters: [.init("recordingID", description: "Actual current recording ID.")], timeout: .seconds(30))
    public static func ignoreVideo(invocation: any FunctionInput, using camera: any CameraControlCapability)
        async throws -> String
    {
        let id = try recordingID(invocation)
        return String(
            decoding: try JSONEncoder().encode(await camera.ignoreVideo(id, invocation: invocation)), as: UTF8.self)
    }
    private static func recordingID(_ invocation: any FunctionInput) throws -> String {
        let a = ActionArguments(invocation.call.parameters)
        try a.validateAllowedKeys(["recordingID"])
        let id = try a.requiredString("recordingID", maximumUTF8Bytes: 36)
        guard UUID(uuidString: id) != nil else { throw ActionArguments.ValidationError.invalidValue("recordingID") }
        try Task.checkCancellation()
        return id
    }
}

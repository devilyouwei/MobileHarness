import Foundation
import FunctionContracts

extension CameraActions {
    @Action(
        domain: "Camera", module: "Video", title: "开始录像",
        doc:
            "Open or restore the Camera window and prepare video mode; record with audio, pausing listening. Default completion returns a ready file with mediaID, fileName, actual durationSeconds and stopReason. Limits: 600 seconds / 512 MiB.",
        parameters: [
            .init(
                "durationSeconds", type: .integer, required: false,
                description: "1…600 seconds; omitted keeps current limit. No configureCamera needed."),
            .init(
                "waitForCompletion", type: .boolean, required: false,
                description:
                    "Default true waits for the ready file; false acknowledges startup only, without later feedback (interactive controls)."
            ),
        ], timeout: .seconds(780), dynamicTimeout: CameraActions.recordingBudget)
    public static func startRecording(invocation: any FunctionInput, using camera: any CameraControlCapability)
        async throws -> String
    {
        let wait = try recordingWait(invocation.call.parameters)
        let duration = try recordingDuration(invocation.call.parameters)
        try Task.checkCancellation()
        let receipt = try await CameraCaptureWorkflow.run(
            invocation: invocation, camera: camera, capture: "startRecording", timeout: .seconds(wait ? 720 : 60)
        ) {
            let started = try await camera.startRecording(durationSeconds: duration, invocation: invocation)
            if wait { return try await camera.waitForRecording(started.recordingID, invocation: invocation) }
            return started
        }
        return String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
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
    static func recordingWait(_ parameters: [String: String]) throws -> Bool {
        try ActionArguments(parameters).validateAllowedKeys(["waitForCompletion", "durationSeconds"])
        guard let value = parameters["waitForCompletion"] else { return true }
        guard value == "true" || value == "false" else {
            throw ActionArguments.ValidationError.invalidValue("waitForCompletion")
        }
        return value == "true"
    }
    static func recordingDuration(_ parameters: [String: String]) throws -> Int? {
        guard parameters["durationSeconds"] != nil else { return nil }
        return try ActionArguments(parameters).requiredInt("durationSeconds", range: 1...600)
    }
    static func recordingBudget(_ call: FunctionRequest) throws -> ActionExecutionBudget {
        try ActionExecutionBudget(expected: .zero, timeout: .seconds(recordingWait(call.parameters) ? 780 : 120))
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

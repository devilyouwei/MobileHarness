import FunctionContracts
import UI

/// Instance-local composition of narrow domain endpoints; it implements no business capability itself.
@MainActor public final class ActionEndpoints {
    public let presentation: RuntimePresentation
    public let speech: SpeechExecutionEndpoint
    public let camera: CameraExecutionEndpoint
    public let tasks: TaskControlEndpoint
    public init(
        cameraControl: any CameraControlCapability, rootSessionID: String,
        effects: any HomeEffectsPresenting, expressions: any ExpressionPresenting,
        homeBluetooth: any BluetoothConnectionPresenting, deviceBluetooth: any BluetoothConnectionPresenting
    ) {
        let speech = SpeechExecutionEndpoint(rootSessionID: rootSessionID)
        self.speech = speech
        camera = CameraExecutionEndpoint(
            camera: cameraControl, rootSessionID: rootSessionID,
            validateSession: { try speech.validateCameraControl(invocation: $0) })
        tasks = TaskControlEndpoint(rootSessionID: rootSessionID)
        presentation = RuntimePresentation(
            rootSessionID: rootSessionID, effects: effects, expressions: expressions,
            homeBluetooth: homeBluetooth, deviceBluetooth: deviceBluetooth,
            authorizeEffects: { try speech.validateEffects(invocation: $0) })
        presentation.feedback = speech
    }
    public func bindVoice(_ voice: any VoiceOutputHandling) throws {
        try speech.bind(voice)
        do { try presentation.bindVoice(voice) } catch {
            speech.unbind(voice)
            throw error
        }
    }
    public func unbindVoice(_ voice: any VoiceOutputHandling) {
        presentation.unbindVoice(voice)
        speech.unbind(voice)
    }
}

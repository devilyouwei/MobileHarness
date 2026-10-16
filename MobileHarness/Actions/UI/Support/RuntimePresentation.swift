import Actions
import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Storage
import UI

@MainActor
public protocol VoiceOutputHandling: AnyObject, Sendable {
    func validateCameraControl(invocation: any FunctionInput) throws
    func updateListening(
        enabled: Bool, paused: Bool, revision: UInt64, feedback: SpeechActions.ListeningFeedback,
        invocation: any FunctionInput) async throws
    func playCue(_ request: UIActions.CueRequest, invocation: any FunctionInput) async throws
    func vibrate(_ request: UIActions.HapticRequest, invocation: any FunctionInput) async throws
    func play(audioID: String, invocation: any FunctionInput) async throws
    func present(_ text: String, invocation: any FunctionInput) throws
    func presentTranscript(_ text: String, invocation: any FunctionInput) throws
    func finishTranscript(invocation: any FunctionInput) throws
    func beginReplyTurn(invocation: any FunctionInput) throws
    func presentVoiceState(_ state: UIActions.VoiceState, invocation: any FunctionInput) throws
    func presentExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) async throws
    func restoreExpression(invocation: any FunctionInput) async throws
    func setExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) throws
    func observeSpeech(_ input: AgentInput)
    func show(_ envelope: OutputEnvelope) async
}

@MainActor
public protocol CameraOutputHandling: AnyObject, Sendable {
    func present(_ target: UIActions.Gaze, invocation: any FunctionInput) throws
    func present(_ overlay: Actions.PoseOverlay, sessionID: String) throws
    func visionStatus(_ message: String?, sessionID: String)
}

/// A whole role binds atomically. Closures in the handler registry never own session resources.
@MainActor
public final class RuntimePresentation: UIPresentationCapability, UIUpdateCapability, SpeechPlaybackCapability,
    PosePresentationCapability, CameraControlCapability, SpeechListeningCapability, TaskControlCapability,
    UIFeedbackCapability, UIEffectCapability
{
    public var taskControl:
        (@Sendable (String, [String: String], String, String, String, String?) async throws -> String)?
    public func controlTask(_ operation: String, arguments: [String: String], invocation: any FunctionInput)
        async throws
        -> String
    {
        guard let taskControl else { throw CommunicationError.scopeClosed }
        if invocation.context.decisionID == nil {
            guard invocation.context.source == "assistant", invocation.context.sessionID == rootSessionID else {
                throw CommunicationError.unauthorized
            }
        }
        return try await taskControl(
            operation, arguments, invocation.context.source, invocation.context.sessionID,
            invocation.context.inputID, invocation.context.decisionID)
    }
    private let cameraControl: any CameraControlCapability
    private let rootSessionID: String
    public let homeEffects: HomeEffectsWorkflow
    public init(cameraControl: any CameraControlCapability, rootSessionID: String, activity: ActionActivityState) {
        homeEffects = HomeEffectsWorkflow(activity: activity)
        self.cameraControl = cameraControl
        self.rootSessionID = rootSessionID
    }
    private func validateEffects(_ invocation: any FunctionInput) throws {
        guard invocation.context.source == "assistant", let voice else { throw CommunicationError.unauthorized }
        try voice.validateCameraControl(invocation: invocation)
    }
    public func showNotice(_ request: UIActions.NoticeRequest, invocation: any FunctionInput) async throws {
        try validateEffects(invocation)
        try await homeEffects.showNotice(
            HomeNotice(text: request.text, tone: HomeNotice.Tone(rawValue: request.tone.rawValue) ?? .warning),
            durationMS: request.durationMS, invocation: invocation)
    }
    public func dismissNotice(invocation: any FunctionInput) async throws {
        try validateEffects(invocation)
        try await homeEffects.dismissNotice(invocation: invocation)
    }
    public func updateLight(_ request: UIActions.LightRequest, invocation: any FunctionInput) async throws {
        try validateEffects(invocation)
        try await homeEffects.updateLight(
            request.enabled
                ? DecorativeLight(
                    origin: .init(x: request.x, y: request.y), initialOpacity: request.initialOpacity,
                    intensity: request.intensity) : nil, durationMS: request.durationMS, invocation: invocation)
    }
    private enum CameraOperation { case open, close, flip, retry, savePhoto, ignorePhoto, cancel }
    private func cameraOperation(
        _ operation: CameraOperation, facing: CameraActions.Facing? = nil, mediaID: String? = nil,
        invocation: any FunctionInput
    )
        async throws -> String?
    {
        if ["photographer", "assistant"].contains(invocation.context.source) {
            if invocation.context.sessionID != rootSessionID {
                guard let voice else { throw CommunicationError.scopeClosed }
                try voice.validateCameraControl(invocation: invocation)
            }
            switch operation {
            case .open: try await cameraControl.setEnabled(true, invocation: invocation)
            case .close: try await cameraControl.setEnabled(false, invocation: invocation)
            case .flip:
                guard let facing else { throw CommunicationError.invalidPayload }
                try await cameraControl.flip(facing, invocation: invocation)
            case .retry: try await cameraControl.retry(invocation: invocation)
            case .savePhoto:
                return String(
                    decoding: try JSONEncoder().encode(await cameraControl.savePhoto(mediaID, invocation: invocation)),
                    as: UTF8.self)
            case .ignorePhoto:
                return String(
                    decoding: try JSONEncoder().encode(
                        await cameraControl.ignorePhoto(mediaID, invocation: invocation)), as: UTF8.self)
            case .cancel: throw CommunicationError.unauthorized
            }
            return nil
        }
        throw CommunicationError.unauthorized
    }
    public func savePhoto(_ id: String?, invocation: any FunctionInput) async throws -> CameraPhotoCommandReceipt {
        guard let result = try await cameraOperation(.savePhoto, mediaID: id, invocation: invocation) else {
            throw CommunicationError.invalidPayload
        }
        return try JSONDecoder().decode(CameraPhotoCommandReceipt.self, from: Data(result.utf8))
    }
    public func ignorePhoto(_ id: String?, invocation: any FunctionInput) async throws -> CameraPhotoCommandReceipt {
        guard let result = try await cameraOperation(.ignorePhoto, mediaID: id, invocation: invocation) else {
            throw CommunicationError.invalidPayload
        }
        return try JSONDecoder().decode(CameraPhotoCommandReceipt.self, from: Data(result.utf8))
    }
    public func takePhoto(invocation: any FunctionInput) async throws -> CameraPhotoReceipt {
        guard ["photographer", "assistant"].contains(invocation.context.source) else {
            throw CommunicationError.unauthorized
        }
        if invocation.context.sessionID != rootSessionID {
            guard let voice else { throw CommunicationError.scopeClosed }
            try voice.validateCameraControl(invocation: invocation)
        }
        return try await cameraControl.takePhoto(invocation: invocation)
    }
    public func readPhoto(_ id: String, source: String, sessionID: String, inputID: String) async throws -> Data {
        try await cameraControl.readPhoto(id, source: source, sessionID: sessionID, inputID: inputID)
    }
    public func setEnabled(_ enabled: Bool, invocation: any FunctionInput) async throws {
        _ = try await cameraOperation(enabled ? .open : .close, invocation: invocation)
    }
    public func flip(_ facing: CameraActions.Facing, invocation: any FunctionInput) async throws {
        _ = try await cameraOperation(.flip, facing: facing, invocation: invocation)
    }
    public func retry(invocation: any FunctionInput) async throws {
        _ = try await cameraOperation(.retry, invocation: invocation)
    }
    private weak var voice: (any VoiceOutputHandling)?
    private weak var camera: (any CameraOutputHandling)?
    public func bindVoice(_ value: any VoiceOutputHandling) throws {
        guard voice == nil else { throw CommunicationError.scopeClosed }
        voice = value
    }
    public func unbindVoice(_ value: any VoiceOutputHandling) {
        if voice === value {
            homeEffects.stop()
            voice = nil
        }
    }
    public func bindCamera(_ value: any CameraOutputHandling) throws {
        guard camera == nil else { throw CommunicationError.scopeClosed }
        camera = value
    }
    public func unbindCamera(_ value: any CameraOutputHandling) {
        if camera === value { camera = nil }
    }
    public func updateListening(
        enabled: Bool, paused: Bool, revision: UInt64, feedback: SpeechActions.ListeningFeedback,
        invocation: any FunctionInput
    ) async throws {
        guard invocation.context.source == "speechPerception", invocation.context.sessionID == rootSessionID,
            let voice
        else { throw CommunicationError.unauthorized }
        try await voice.updateListening(
            enabled: enabled, paused: paused, revision: revision, feedback: feedback, invocation: invocation)
    }
    public func playCue(_ request: UIActions.CueRequest, invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try await voice.playCue(request, invocation: invocation)
    }
    public func vibrate(_ request: UIActions.HapticRequest, invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try await voice.vibrate(request, invocation: invocation)
    }
    public func play(audioID: String, invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try await voice.play(audioID: audioID, invocation: invocation)
    }
    public func present(_ text: String, invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.present(text, invocation: invocation)
    }
    public func presentTranscript(_ text: String, invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.presentTranscript(text, invocation: invocation)
    }
    public func finishTranscript(invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.finishTranscript(invocation: invocation)
    }
    public func beginReplyTurn(invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.beginReplyTurn(invocation: invocation)
    }
    public func presentVoiceState(_ state: UIActions.VoiceState, invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.presentVoiceState(state, invocation: invocation)
    }
    public func presentExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try await voice.presentExpression(emotion, invocation: invocation)
    }
    public func restoreExpression(invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try await voice.restoreExpression(invocation: invocation)
    }
    public func setExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.setExpression(emotion, invocation: invocation)
    }
    public func present(_ target: UIActions.Gaze, invocation: any FunctionInput) async throws {
        guard let camera else { throw CommunicationError.scopeClosed }
        try camera.present(target, invocation: invocation)
    }
    public func present(_ overlay: Actions.PoseOverlay, sessionID: String) async throws {
        guard let camera else { throw CommunicationError.scopeClosed }
        try camera.present(overlay, sessionID: sessionID)
    }
    public func observe(_ input: AgentInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        voice.observeSpeech(input)
    }
    public func output(_ envelope: OutputEnvelope) async {
        guard
            ["assistant", "photographer", "memory", "applicationControl", "speechPerception"].contains(
                envelope.source.rawValue)
        else { return }
        await voice?.show(envelope)
    }
}

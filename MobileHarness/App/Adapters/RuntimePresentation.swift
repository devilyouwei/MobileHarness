import Actions
import AgentCore
import Agents
import AppWorkflows
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts

@MainActor
protocol VoiceOutputHandling: AnyObject, Sendable {
    func validateCameraControl(invocation: any FunctionInput) throws
    func play(audioID: UUID, invocation: any FunctionInput) async throws
    func present(_ text: String, invocation: any FunctionInput) throws
    func presentTranscript(_ text: String, invocation: any FunctionInput) throws
    func finishTranscript(invocation: any FunctionInput) throws
    func beginReplyTurn(invocation: any FunctionInput) throws
    func presentVoiceState(_ state: UIActions.VoiceState, invocation: any FunctionInput) throws
    func presentExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) async throws
    func restoreExpression(invocation: any FunctionInput) async throws
    func setExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) throws
    func observeSpeech(_ input: AgentInput)
    func show(_ envelope: OutputEnvelope)
}

@MainActor
protocol CameraOutputHandling: AnyObject, Sendable {
    func present(_ target: UIActions.Gaze, invocation: any FunctionInput) throws
    func present(_ overlay: PoseOverlay, sessionID: UUID) throws
    func visionStatus(_ message: String?, sessionID: UUID)
}

/// A whole role binds atomically. Closures in the handler registry never own session resources.
@MainActor
final class RuntimePresentation: UIPresentationCapability, UIUpdateCapability, SpeechPlaybackCapability,
    PosePresentationCapability, CameraControlCapability
{
    private let cameraControl: any CameraControlCapability
    private let rootSessionID: UUID
    init(cameraControl: any CameraControlCapability, rootSessionID: UUID) {
        self.cameraControl = cameraControl
        self.rootSessionID = rootSessionID
    }
    var cameraRequests:
        (
            @MainActor @Sendable (
                PhotographerCameraIntent.Operation, PhotographerCameraIntent.Facing?, any FunctionInput
            ) async throws -> Void
        )?
    private func cameraOperation(
        _ operation: PhotographerCameraIntent.Operation, facing: CameraActions.Facing? = nil,
        invocation: any FunctionInput
    )
        async throws
    {
        if invocation.context.source == "photographer" {
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
            case .cancel: throw CommunicationError.unauthorized
            }
            return
        }
        guard invocation.context.source == "assistant", let voice, let cameraRequests else {
            throw CommunicationError.unauthorized
        }
        try voice.validateCameraControl(invocation: invocation)
        do {
            try await cameraRequests(
                operation, facing.flatMap { PhotographerCameraIntent.Facing(rawValue: $0.rawValue) }, invocation)
        } catch PhotographerIntentFailure.execution(let result) {
            if case .report(let report)? = result.tool?.completion { throw ActionReportedError(report) }
            throw PhotographerIntentFailure.execution(result)
        }
    }
    func setEnabled(_ enabled: Bool, invocation: any FunctionInput) async throws {
        try await cameraOperation(enabled ? .open : .close, invocation: invocation)
    }
    func flip(_ facing: CameraActions.Facing, invocation: any FunctionInput) async throws {
        try await cameraOperation(.flip, facing: facing, invocation: invocation)
    }
    func retry(invocation: any FunctionInput) async throws { try await cameraOperation(.retry, invocation: invocation) }
    private weak var voice: (any VoiceOutputHandling)?
    private weak var camera: (any CameraOutputHandling)?
    func bindVoice(_ value: any VoiceOutputHandling) throws {
        guard voice == nil else { throw CommunicationError.scopeClosed }
        voice = value
    }
    func unbindVoice(_ value: any VoiceOutputHandling) {
        if voice === value { voice = nil }
    }
    func bindCamera(_ value: any CameraOutputHandling) throws {
        guard camera == nil else { throw CommunicationError.scopeClosed }
        camera = value
    }
    func unbindCamera(_ value: any CameraOutputHandling) {
        if camera === value { camera = nil }
    }
    func play(audioID: UUID, invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try await voice.play(audioID: audioID, invocation: invocation)
    }
    func present(_ text: String, invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.present(text, invocation: invocation)
    }
    func presentTranscript(_ text: String, invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.presentTranscript(text, invocation: invocation)
    }
    func finishTranscript(invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.finishTranscript(invocation: invocation)
    }
    func beginReplyTurn(invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.beginReplyTurn(invocation: invocation)
    }
    func presentVoiceState(_ state: UIActions.VoiceState, invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.presentVoiceState(state, invocation: invocation)
    }
    func presentExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try await voice.presentExpression(emotion, invocation: invocation)
    }
    func restoreExpression(invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try await voice.restoreExpression(invocation: invocation)
    }
    func setExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        try voice.setExpression(emotion, invocation: invocation)
    }
    func present(_ target: UIActions.Gaze, invocation: any FunctionInput) async throws {
        guard let camera else { throw CommunicationError.scopeClosed }
        try camera.present(target, invocation: invocation)
    }
    func present(_ overlay: PoseOverlay, sessionID: UUID) async throws {
        guard let camera else { throw CommunicationError.scopeClosed }
        try camera.present(overlay, sessionID: sessionID)
    }
    func observe(_ input: AgentInput) async throws {
        guard let voice else { throw CommunicationError.scopeClosed }
        voice.observeSpeech(input)
    }
    func output(_ envelope: OutputEnvelope) async {
        guard envelope.source.rawValue == "assistant" || envelope.source.rawValue == "speechPerception" else { return }
        voice?.show(envelope)
    }
}

import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import PlatformKit
import StorageCore
import UI

/// A whole role binds atomically. Closures in the handler registry never own session resources.
@MainActor
public final class RuntimePresentation: UIPresentationCapability, UIUpdateCapability,
    PosePresentationCapability, UIFeedbackCapability, UIEffectCapability, RuntimeFailurePresentationCapability,
    BluetoothStatusPresentationCapability, LoadingExpressionPresentationCapability
{
    private let rootSessionID: String
    private let homeBluetooth: any BluetoothConnectionPresenting
    private let deviceBluetooth: any BluetoothConnectionPresenting
    public func presentBluetoothHome(
        _ phase: BluetoothPresentationPhase, revision: UInt64, invocation: any FunctionInput
    ) async throws {
        try validateApplicationControl(invocation)
        guard let status = BluetoothConnectionStatus(rawValue: phase.rawValue),
            homeBluetooth.presentBluetoothConnection(status, revision: revision)
        else { throw UIContainerError.stale }
    }
    public func presentBluetoothSettings(
        _ phase: BluetoothPresentationPhase, revision: UInt64, invocation: any FunctionInput
    ) async throws {
        try validateApplicationControl(invocation)
        guard let status = BluetoothConnectionStatus(rawValue: phase.rawValue),
            deviceBluetooth.presentBluetoothConnection(status, revision: revision)
        else { throw UIContainerError.stale }
    }
    private func validateApplicationControl(_ invocation: any FunctionInput) throws {
        try Task.checkCancellation()
        guard invocation.context.sessionID == rootSessionID,
            invocation.context.taskID == nil
        else { throw ActionHostError.unauthorized }
    }
    public func setLoadingExpression(_ enabled: Bool, revision: UInt64, invocation: any FunctionInput) async throws {
        try validateApplicationControl(invocation)
        switch expressions.setLoading(enabled, revision: revision) {
        case .applied, .superseded: return
        case .rejected: throw UIContainerError.stale
        }
    }
    private let activity: any ActivityPresenting
    public func recordRuntimeFailure(_ issue: RuntimeIssue, invocation: any FunctionInput) async throws {
        try Task.checkCancellation()
        guard invocation.context.sessionID == rootSessionID,
            invocation.context.taskID == nil
        else { throw ActionHostError.unauthorized }
        try activity.requirePresentation()
        activity.recordIssue(
            .init(
                id: issue.id, title: issue.title, source: issue.source, message: issue.message, time: issue.time,
                failureCode: issue.failureCode,
                context: .init(
                    workerID: issue.workerID, sessionID: issue.sessionID, inputID: issue.inputID, callID: issue.callID,
                    roundID: issue.roundID
                ),
                userMessage: issue.userMessage, category: issue.category), showsToast: issue.userMessage != nil)
    }
    public weak var feedback: (any UIFeedbackCapability & AnyObject)?
    public let homeEffects: any HomeEffectsPresenting
    public let expressions: any ExpressionPresenting
    public init(
        rootSessionID: String, activity: any ActivityPresenting,
        effects: any HomeEffectsPresenting, expressions: any ExpressionPresenting,
        homeBluetooth: any BluetoothConnectionPresenting, deviceBluetooth: any BluetoothConnectionPresenting,
        authorizeEffects: @escaping @MainActor (any FunctionInput) throws -> Void = { _ in
            throw ActionHostError.unauthorized
        }
    ) {
        self.homeBluetooth = homeBluetooth
        self.deviceBluetooth = deviceBluetooth
        self.activity = activity
        homeEffects = effects
        self.expressions = expressions
        self.authorizeEffects = authorizeEffects
        self.rootSessionID = rootSessionID
    }
    private let authorizeEffects: @MainActor (any FunctionInput) throws -> Void
    private func validateEffects(_ invocation: any FunctionInput) throws {
        try authorizeEffects(invocation)
    }
    public func showNotice(_ request: UIActions.NoticeRequest, invocation: any FunctionInput) async throws {
        try validateEffects(invocation)
        try await homeEffects.showNotice(
            HomeNotice(text: request.text, tone: HomeNotice.Tone(rawValue: request.tone.rawValue) ?? .warning),
            durationMS: request.durationMS,
            owner: .init(source: invocation.context.source, session: invocation.context.sessionID))
    }
    public func dismissNotice(invocation: any FunctionInput) async throws {
        try validateEffects(invocation)
        try await homeEffects.dismissNotice(
            owner: .init(source: invocation.context.source, session: invocation.context.sessionID))
    }
    public func updateLight(_ request: UIActions.LightRequest, invocation: any FunctionInput) async throws {
        try validateEffects(invocation)
        try await homeEffects.updateLight(
            request.enabled
                ? DecorativeLight(
                    origin: .init(x: request.x, y: request.y), initialOpacity: request.initialOpacity,
                    intensity: request.intensity) : nil, durationMS: request.durationMS,
            owner: .init(source: invocation.context.source, session: invocation.context.sessionID))
    }
    private weak var voice: (any VoicePresentationHandling)?
    private weak var camera: (any CameraOutputHandling)?
    public func bindVoice(_ value: any VoicePresentationHandling) throws {
        guard voice == nil else { throw ActionHostError.scopeClosed }
        voice = value
    }
    public func unbindVoice(_ value: any VoicePresentationHandling) {
        if voice === value {
            homeEffects.stop()
            voice = nil
        }
    }
    public func bindCamera(_ value: any CameraOutputHandling) throws {
        guard camera == nil else { throw ActionHostError.scopeClosed }
        camera = value
    }
    public func unbindCamera(_ value: any CameraOutputHandling) {
        if camera === value { camera = nil }
    }
    public func playCue(_ request: UIActions.CueRequest, invocation: any FunctionInput) async throws {
        guard let feedback else { throw ActionHostError.scopeClosed }
        try await feedback.playCue(request, invocation: invocation)
    }
    public func vibrate(_ request: UIActions.HapticRequest, invocation: any FunctionInput) async throws {
        guard let feedback else { throw ActionHostError.scopeClosed }
        try await feedback.vibrate(request, invocation: invocation)
    }
    public func present(_ text: String, invocation: any FunctionInput) async throws {
        guard let voice else { throw ActionHostError.scopeClosed }
        try voice.present(text, invocation: invocation)
    }
    public func presentTranscript(_ text: String, invocation: any FunctionInput) async throws {
        guard let voice else { throw ActionHostError.scopeClosed }
        try voice.presentTranscript(text, invocation: invocation)
    }
    public func finishTranscript(invocation: any FunctionInput) async throws {
        guard let voice else { throw ActionHostError.scopeClosed }
        try voice.finishTranscript(invocation: invocation)
    }
    public func setReplyWaiting(_ enabled: Bool, requestID: String, invocation: any FunctionInput) async throws {
        guard let voice else { throw ActionHostError.scopeClosed }
        try voice.setReplyWaiting(enabled, requestID: requestID, invocation: invocation)
    }
    public func beginReplyTurn(invocation: any FunctionInput) async throws {
        guard let voice else { throw ActionHostError.scopeClosed }
        try voice.beginReplyTurn(invocation: invocation)
    }
    public func presentVoiceState(_ state: UIActions.VoiceState, invocation: any FunctionInput) async throws {
        guard let voice else { throw ActionHostError.scopeClosed }
        try voice.presentVoiceState(state, invocation: invocation)
    }
    public func presentExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) async throws {
        guard let voice else { throw ActionHostError.scopeClosed }
        try await voice.presentExpression(emotion, invocation: invocation)
    }
    public func restoreExpression(invocation: any FunctionInput) async throws {
        guard let voice else { throw ActionHostError.scopeClosed }
        try await voice.restoreExpression(invocation: invocation)
    }
    public func setExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) async throws {
        guard let voice else { throw ActionHostError.scopeClosed }
        try voice.setExpression(emotion, invocation: invocation)
    }
    public func present(_ target: UIActions.Gaze, invocation: any FunctionInput) async throws {
        guard let camera else { throw ActionHostError.scopeClosed }
        try camera.present(target, invocation: invocation)
    }
    public func present(_ overlay: Actions.PoseOverlay, sessionID: String) async throws {
        guard let camera else { throw ActionHostError.scopeClosed }
        try camera.present(overlay, frame: nil, sessionID: sessionID)
    }
    public func present(_ overlay: Actions.PoseOverlay, invocation: any FunctionInput) async throws {
        guard let camera else { throw ActionHostError.scopeClosed }
        try camera.present(
            overlay, frame: invocation.attachment as? CameraFrame, sessionID: invocation.context.sessionID)
    }

    public func observeTranscript(_ text: String, sessionID: String) throws {
        guard let voice else { throw ActionHostError.scopeClosed }
        voice.observeTranscript(text, sessionID: sessionID)
    }
    public func output(_ envelope: ActionOutputObservation) async {
        await voice?.show(envelope)
    }
}

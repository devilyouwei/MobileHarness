import Foundation
import Observation

public enum VoicePhase: Sendable, Equatable { case idle, loading, listening, processing, speaking, failed }

public enum EyeExpression: String, CaseIterable, Sendable {
    case clear, closed, smile, happy, laugh, thinking, surprised, sad, love, angry, scared, playful
}

/// MainActor presentation values and public rendering ports; module services own business sessions.
@MainActor @Observable
public final class ConversationState {
    public var voicePhase: VoicePhase = .loading
    public var liveTranscript = ""
    public var transcriptFinalized = false
    public var assistantReply = ""
    public var assistantReplyOpacity = 1.0
    public var expression: EyeExpression?
    /// Display transaction identity only; UI owns the renderer acknowledgment.
    public var expressionEmphasized = false
    public var expressionTransitionID: String?
    public var expressionRendererAvailable = false
    @ObservationIgnored public var expressionAnimationCompletion: (@MainActor (String, Bool) -> Void)?
    public var playbackSpectrum = [Float](repeating: 0, count: 32)
    public var microphoneSpectrum = [Float](repeating: 0, count: 32)
    public var isReady = false
    public var voiceStatus = "按住双眼，开启聆听"
    public var isVoiceActive = false { didSet { if !isVoiceActive { resetCaptions() } } }
    public var listeningAnimationID: String?
    /// Normalized content-space origin; latched by the renderer on each new listening generation.
    public var listeningLightOrigin: ListeningLightOrigin?
    public var decorativeLight: DecorativeLight?
    public var graphicsMessage: String?
    public var isReplyActive = false
    public var listeningControlMessage: String?
    /// Sleep is a presentation gate, independent of processing/speaking pauses in an enabled session.
    public var displayedExpression: EyeExpression { isVoiceActive ? (expression ?? .clear) : .closed }
    public init() {}
    public func presentPlaybackSpectrum(_ values: [Float]) { playbackSpectrum = values }
    public func presentTranscript(_ text: String) { liveTranscript = text }
    public func beginReply() { assistantReply = "" }
    public func appendReply(_ text: String) { assistantReply += text }
    public func presentVoiceStatus(_ status: String, clearMicrophone: Bool = false) {
        if clearMicrophone { microphoneSpectrum = [Float](repeating: 0, count: 32) }
        voiceStatus = status
    }
    public func resetCaptions() {
        liveTranscript = ""
        transcriptFinalized = false
        assistantReply = ""
        assistantReplyOpacity = 1
    }
    public func finishUserTranscript() { transcriptFinalized = true }
}

/// The pinned goal and movable ASR are independent, with reserved promoted-caption space.
public struct ConversationCaptionLayout: Sendable {
    public let captionHeight: CGFloat
    public let captionCenterY: CGFloat
    public let taskCenterY: CGFloat

    public init(
        viewportHeight: CGFloat, faceDiameter: CGFloat,
        hasTranscript: Bool, finalized: Bool, hasTask: Bool, hasActivity: Bool
    ) {
        captionHeight = min(100, viewportHeight * 0.16)
        let promotedTop = max(72, viewportHeight * 0.40 - faceDiameter * 0.5 - 31 - captionHeight * 0.5)
        taskCenterY = promotedTop + 9
        let captionCenter: CGFloat
        if finalized || !hasTranscript {
            captionCenter = promotedTop + (hasTask ? 26 : 0) + captionHeight * 0.5
        } else {
            captionCenter = viewportHeight - (hasActivity ? 240 : 120)
        }
        captionCenterY = captionCenter
    }
}

public enum AppDestination: String, Hashable, Sendable {
    case settings, language, recognition, synthesis, vision, bluetooth, history
}
@MainActor @Observable public final class NavigationState {
    public var path: [AppDestination] = []
    public init() {}
    public func show(_ destination: AppDestination?) {
        guard let destination else {
            path = []
            return
        }
        path = destination == .settings ? [.settings] : [.settings, destination]
    }
}

/// Decoration only: does not own listening consent or expression state.
public struct DecorativeLight: Sendable, Equatable {
    public let id: String
    public let origin: ListeningLightOrigin
    public let initialOpacity: Double
    public let intensity: Double
    public init(
        id: String = UUID().uuidString, origin: ListeningLightOrigin, initialOpacity: Double,
        intensity: Double
    ) {
        self.id = id
        self.origin = origin
        self.initialOpacity = initialOpacity
        self.intensity = intensity
    }
}

/// A notice reserves the bottom slot; promoted ASR and the Task goal are independent.
public enum ConversationCaptionVisibility {
    public static func user(isListening: Bool, finalized: Bool, hasNotice: Bool) -> Bool {
        isListening && (finalized || !hasNotice)
    }
    public static func reply(hasNotice: Bool) -> Bool { !hasNotice }
}

public enum ConversationExpressionError: Error, Equatable { case rendererUnavailable, busy }

/// UI-owned transaction and renderer acknowledgment; IDs fence replacement and late callbacks.
@MainActor public final class ConversationExpressionPresentation {
    private let state: ConversationState
    private var baseExpression: EyeExpression?
    private var expressionOwner: String?
    private var expressionWaiter: CheckedContinuation<Void, Error>?
    private var expressionWaitID: String?
    public init(state: ConversationState) { self.state = state }
    public func setBase(_ expression: EyeExpression?) {
        baseExpression = expression
        if expressionOwner == nil { state.expression = expression }
    }
    public func perform(_ expression: EyeExpression, owner: String) async throws {
        guard state.isVoiceActive || expression == .closed else {
            throw ConversationExpressionError.rendererUnavailable
        }
        guard expressionOwner == nil else { throw ConversationExpressionError.busy }
        expressionOwner = owner
        try await transitionExpression(to: expression, emphasized: true)
    }
    public func restore(owner: String, accepts: Bool) async throws {
        guard expressionOwner == owner else { return }
        if Task.isCancelled || !state.expressionRendererAvailable || !accepts {
            finishExpressionTransition(id: expressionWaitID, completed: false)
            expressionOwner = nil
            state.expressionEmphasized = false
            state.expression = baseExpression
            return
        }
        defer {
            if expressionOwner == owner {
                expressionOwner = nil
                state.expressionEmphasized = false
                state.expression = baseExpression
            }
        }
        try await transitionExpression(to: baseExpression)
    }
    private func transitionExpression(to target: EyeExpression?, emphasized: Bool = false) async throws {
        try Task.checkCancellation()
        guard state.expressionRendererAvailable else { throw ConversationExpressionError.rendererUnavailable }
        guard expressionWaiter == nil else { throw ConversationExpressionError.busy }
        let id = UUID().uuidString
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                expressionWaitID = id
                expressionWaiter = continuation
                state.expressionAnimationCompletion = { [weak self] id, completed in
                    self?.finishExpressionTransition(id: id, completed: completed)
                }
                state.expressionTransitionID = id
                state.expressionEmphasized = emphasized
                state.expression = target
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishExpressionTransition(id: id, completed: false) }
        }
    }

    private func finishExpressionTransition(id: String?, completed: Bool) {
        guard let id, expressionWaitID == id else { return }
        let waiter = expressionWaiter
        expressionWaiter = nil
        expressionWaitID = nil
        state.expressionTransitionID = nil
        state.expressionAnimationCompletion = nil
        if completed { waiter?.resume() } else { waiter?.resume(throwing: CancellationError()) }
    }

    public func resetExpression() {
        finishExpressionTransition(id: expressionWaitID, completed: false)
        expressionOwner = nil
        baseExpression = nil
        state.expressionEmphasized = false
        state.expression = nil
    }

}

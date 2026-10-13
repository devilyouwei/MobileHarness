import Foundation
import Observation

public enum VoicePhase: Sendable, Equatable { case idle, loading, listening, processing, speaking, failed }

public enum EyeExpression: String, CaseIterable, Sendable {
    case clear, closed, smile, happy, laugh, thinking, surprised, sad, love, angry, scared, playful
}

/// MainActor presentation only. App applies accepted updates and owns the running session.
@MainActor @Observable
public final class ConversationState {
    public var voicePhase: VoicePhase = .loading
    public var liveTranscript = ""
    public var transcriptFinalized = false
    public var assistantReply = ""
    public var assistantReplyOpacity = 1.0
    public var expression: EyeExpression?
    /// Display transaction identity only; App owns the waiting operation.
    public var expressionEmphasized = false
    public var expressionTransitionID: UUID?
    public var expressionRendererAvailable = false
    @ObservationIgnored public var expressionAnimationCompletion: (@MainActor (UUID, Bool) -> Void)?
    public var playbackSpectrum = [Float](repeating: 0, count: 32)
    public var microphoneSpectrum = [Float](repeating: 0, count: 32)
    public var isReady = false
    public var voiceStatus = "按住双眼，开启聆听"
    public var isVoiceActive = false { didSet { if !isVoiceActive { resetCaptions() } } }
    public var listeningAnimationID: UUID?
    /// Normalized content-space origin; latched by the renderer on each new listening generation.
    public var listeningLightOrigin: ListeningLightOrigin?
    public var decorativeLight: DecorativeLight?
    public var graphicsMessage: String?
    public var isReplyActive = false
    public var listeningControlMessage: String?
    /// Sleep is a presentation gate, independent of processing/speaking pauses in an enabled session.
    public var displayedExpression: EyeExpression { isVoiceActive ? (expression ?? .clear) : .closed }
    public init() {}
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
    public let id: UUID
    public let origin: ListeningLightOrigin
    public let initialOpacity: Double
    public let intensity: Double
    public init(id: UUID = UUID(), origin: ListeningLightOrigin, initialOpacity: Double, intensity: Double) {
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

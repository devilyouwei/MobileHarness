import Foundation
import Observation

public enum VoicePhase: Sendable { case idle, loading, listening, processing, speaking, failed }

public enum EyeExpression: String, CaseIterable, Sendable {
    case clear, smile, happy, laugh, thinking, surprised, sad, love, angry, scared, playful
}

/// MainActor presentation only. App applies accepted updates and owns the running session.
@MainActor @Observable
public final class ConversationState {
    public var voicePhase: VoicePhase = .loading
    public var liveTranscript = ""
    public var transcriptFinalized = false
    public var assistantReply = ""
    public var expression: EyeExpression?
    /// Display transaction identity only; App owns the waiting operation.
    public var expressionEmphasized = false
    public var expressionTransitionID: UUID?
    public var expressionRendererAvailable = false
    @ObservationIgnored public var expressionAnimationCompletion: (@MainActor (UUID, Bool) -> Void)?
    public var playbackSpectrum = [Float](repeating: 0, count: 32)
    public var microphoneSpectrum = [Float](repeating: 0, count: 32)
    public var isReady = false
    public var voiceStatus = "点击麦克风开始持续对话"
    public var isVoiceActive = false
    public init() {}
    public func resetCaptions() {
        liveTranscript = ""
        transcriptFinalized = false
        assistantReply = ""
    }
    public func finishUserTranscript() { transcriptFinalized = true }
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

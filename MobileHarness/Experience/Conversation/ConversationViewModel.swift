import Foundation
import Observation

/// Presentation state and user intents; no concrete Agent, model or device construction.
@MainActor @Observable
final class ConversationViewModel {
    private let lifecycle: AppLifecycleCoordinator
    init(lifecycle: AppLifecycleCoordinator) { self.lifecycle = lifecycle }

    var voicePhase: AppLifecycleCoordinator.VoicePhase { lifecycle.voicePhase }
    var liveTranscript: String { lifecycle.liveTranscript }
    var expression: String? { lifecycle.expression }
    var expressionID: UUID { lifecycle.expressionID }
    var assistantReply: String { lifecycle.assistantReply }
    var playbackLevel: Float { lifecycle.playbackLevel }
    func toggleVoice() { lifecycle.toggleVoice() }
    var isReady: Bool { lifecycle.isReady }
    var voiceStatus: String { lifecycle.voiceStatus }
    var audioLevel: Float { lifecycle.audioLevel }
    var isVoiceActive: Bool { lifecycle.isVoiceActive }
    func run() async { await lifecycle.run() }
    func stopVoice(message: String) { lifecycle.stopVoice(message: message) }
}

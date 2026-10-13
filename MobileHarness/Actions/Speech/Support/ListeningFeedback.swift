import Foundation

extension SpeechActions {
    public struct ListeningFeedback: Sendable, Equatable {
        public let cue: UIActions.CueRequest
        public let haptic: UIActions.HapticRequest
        public init(cue: UIActions.CueRequest, haptic: UIActions.HapticRequest) {
            self.cue = cue
            self.haptic = haptic
        }
    }
}

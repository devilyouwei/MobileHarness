import Foundation

extension SpeechActions {
    public struct ListeningPolicy: Sendable {
        public let enabled: Bool
        public let paused: Bool
        public let revision: UInt64
        public init(enabled: Bool, paused: Bool, revision: UInt64) {
            self.enabled = enabled
            self.paused = paused
            self.revision = revision
        }
    }

    public struct ListeningFeedback: Sendable, Equatable {
        public let cue: UIActions.CueRequest
        public let haptic: UIActions.HapticRequest
        public init(cue: UIActions.CueRequest, haptic: UIActions.HapticRequest) {
            self.cue = cue
            self.haptic = haptic
        }
    }
}

public enum SpeechActionError: Error { case missingAudio, listeningUnavailable }

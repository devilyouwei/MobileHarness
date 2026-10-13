import Foundation
import FunctionContracts

/// Session-owned playback of an already decoded handle, including checkout, drain and cleanup.
public protocol SpeechPlaybackCapability: Sendable {
    func play(audioID: UUID, invocation: any FunctionInput) async throws
}

public protocol SpeechListeningCapability: Sendable {
    func updateListening(
        enabled: Bool, paused: Bool, revision: UInt64, feedback: SpeechActions.ListeningFeedback,
        invocation: any FunctionInput) async throws
}

@ActionCatalog
public struct SpeechModule: CapabilityModule {
    private let listening: (any SpeechListeningCapability)?
    private let playback: any SpeechPlaybackCapability
    public init(playback: any SpeechPlaybackCapability, listening: (any SpeechListeningCapability)? = nil) {
        self.playback = playback
        self.listening = listening
    }
    public var definitions: [ActionFunction] {
        [
            SpeechActions.speakDefinition(handler: { [playback] invocation in
                try await SpeechActions.speak(invocation: invocation) {
                    try await playback.play(audioID: $0, invocation: $1)
                }
            }),
            SpeechActions.updateDefinition(handler: { [listening] invocation in
                guard let listening else { throw SpeechActionError.listeningUnavailable }
                try await SpeechActions.update(invocation: invocation) { enabled, paused, revision, feedback in
                    try await listening.updateListening(
                        enabled: enabled, paused: paused, revision: revision, feedback: feedback,
                        invocation: invocation)
                }
            }),
        ]
    }
}

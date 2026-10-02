import ActionRuntime
import Foundation

/// Session-owned playback of an already decoded handle, including checkout, drain and cleanup.
public protocol SpeechPlaybackCapability: Sendable {
    func play(audioID: UUID, invocation: ActionInvocation) async throws
}

public struct SpeechActionModule: ActionModule {
    private let playback: any SpeechPlaybackCapability
    public init(playback: any SpeechPlaybackCapability) { self.playback = playback }
    public var definitions: [ActionDefinition] {
        [
            SpeechActions.speakDefinition(handler: { [playback] invocation in
                try await SpeechActions.speak(invocation: invocation) {
                    try await playback.play(audioID: $0, invocation: $1)
                }
            })
        ]
    }
}

import Foundation
import FunctionContracts

/// Session-owned playback of an already decoded handle, including checkout, drain and cleanup.
public protocol SpeechPlaybackCapability: Sendable {
    func play(audioID: UUID, invocation: any FunctionInput) async throws
}

public struct SpeechModule: CapabilityModule {
    private let playback: any SpeechPlaybackCapability
    public init(playback: any SpeechPlaybackCapability) { self.playback = playback }
    public var definitions: [ActionFunction] {
        [
            SpeechActions.speakDefinition(handler: { [playback] invocation in
                try await SpeechActions.speak(invocation: invocation) {
                    try await playback.play(audioID: $0, invocation: $1)
                }
            })
        ]
    }
}

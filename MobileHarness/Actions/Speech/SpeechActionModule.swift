import AgentCore

public struct SpeechActionModule: ActionModule {
    private let playback: any SpeechPlaybackCapability
    public init(playback: any SpeechPlaybackCapability) { self.playback = playback }
    public var definitions: [ActionDefinition] {
        [
            ActionDefinition(
                path: ActionPath(module: "Speech", function: "speak"), kind: .finite,
                completion: "Playback drained and audio lease released.",
                handler: { [playback] invocation in
                    try await SpeechActions.speak(invocation: invocation) {
                        try await playback.play(audioID: $0, invocation: $1)
                    }
                })
        ]
    }
}

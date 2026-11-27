import FunctionContracts

@ActionCatalog
public struct SpeechModule: CapabilityModule {
    private let listening: (any SpeechListeningCapability)?
    private let playback: any SpeechPlaybackCapability
    private let gesture: (any SpeechListeningGestureCapability)?
    private let detection: (any AudioDetectionCapability)?
    public init(
        playback: any SpeechPlaybackCapability, listening: (any SpeechListeningCapability)? = nil,
        gesture: (any SpeechListeningGestureCapability)? = nil, detection: (any AudioDetectionCapability)? = nil
    ) {
        self.gesture = gesture
        self.detection = detection
        self.playback = playback
        self.listening = listening
    }
    public var definitions: [ActionFunction] {
        var values = [
            SpeechActions.speakDefinition(completing: { [playback] invocation in
                try await SpeechPlaybackExecution(playback: playback).execute(invocation)
            }).supportingControls([.pause, .resume, .cancel]),
            SpeechActions.setVolumeDefinition(handler: { [playback] invocation in
                try await SpeechActions.setVolume(invocation: invocation) {
                    try await playback.setVolume($0, executionID: $1, invocation: $2)
                }
            }),
            SpeechActions.startListeningDefinition(handler: { [listening] invocation in
                guard let listening else { throw SpeechActionError.listeningUnavailable }
                try await SpeechActions.startListening(invocation: invocation, using: listening)
            }),
            SpeechActions.stopListeningDefinition(handler: { [listening] invocation in
                guard let listening else { throw SpeechActionError.listeningUnavailable }
                try await SpeechActions.stopListening(invocation: invocation, using: listening)
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
        values.append(
            SpeechActions.prepareListeningFunction(
                using: gesture ?? UnavailableListeningGesture()))
        values.append(
            SpeechActions.detectionFunction(
                using: detection ?? UnavailableAudioDetection()))
        return values
    }
}

private struct UnavailableListeningGesture: SpeechListeningGestureCapability {
    func prepareListening(pressed: Bool, invocation: any FunctionInput) throws {
        throw SpeechActionError.listeningUnavailable
    }
}
private struct UnavailableAudioDetection: AudioDetectionCapability {
    func runDetection(invocation: any FunctionInput) throws { throw SpeechActionError.listeningUnavailable }
}

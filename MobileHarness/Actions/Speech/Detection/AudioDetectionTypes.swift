import Foundation
import PlatformKit
import UI

/// Processed measurements only; no PCM or Agent transport enters the execution service.
public enum AudioDetectionObservation: Sendable {
    case microphone(MicrophoneChannelLayout, Int, Float, ContinuousClock.Instant)
    case direction(AudioDetectionSnapshot.Direction, Double?, Double?, ContinuousClock.Instant?)
}

@MainActor public struct AudioDetectionPerception {
    public let perception: any VoicePerceptionHandling
    public let stop: @MainActor () async -> Void
    public init(perception: any VoicePerceptionHandling, stop: @escaping @MainActor () async -> Void) {
        self.perception = perception
        self.stop = stop
    }
}

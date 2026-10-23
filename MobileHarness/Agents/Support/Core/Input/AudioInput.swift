import Foundation

public enum AudioValidationError: Error, Equatable, Sendable {
    case invalidRequest(String)
}

/// Generic interleaved PCM channel ordering; no perception or device policy.
public enum AudioChannelLayout: Sendable, Equatable {
    case mono
    case firstOrderAmbisonicsACNSN3D
    public var channelCount: Int { self == .mono ? 1 : 4 }
}

/// Immutable local PCM prepared by its consuming role; no device or transport ownership.
public struct AudioInput: Sendable {
    public let samples: [Float]
    public let sampleRate: Int
    public let layout: AudioChannelLayout
    public let capturedAt: ContinuousClock.Instant
    public let sequence: UInt64
    public let timestamp: TimeInterval
    public var sampleCount: Int { samples.count }
    public var frameCount: Int { sampleCount / layout.channelCount }
    public init(
        samples: [Float], sampleRate: Int, sequence: UInt64, timestamp: TimeInterval,
        layout: AudioChannelLayout = .mono, capturedAt: ContinuousClock.Instant = .now
    ) throws {
        guard (8_000...192_000).contains(sampleRate), !samples.isEmpty, samples.count <= 16_000,
            samples.count.isMultiple(of: layout.channelCount), samples.allSatisfy(\.isFinite),
            timestamp.isFinite, timestamp >= 0
        else { throw AudioValidationError.invalidRequest("Invalid native PCM") }
        self.samples = samples
        self.sampleRate = sampleRate
        self.sequence = sequence
        self.timestamp = timestamp
        self.layout = layout
        self.capturedAt = capturedAt
    }
}

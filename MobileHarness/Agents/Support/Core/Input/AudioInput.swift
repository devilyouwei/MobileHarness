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

/// Transport-owned PCM. ModelKit conversion belongs to the calling perception Agent, never Gateway.
public struct AudioInput: Sendable {
    public let samples: Data
    public let sampleRate: Int
    public let layout: AudioChannelLayout
    public let capturedAt: ContinuousClock.Instant
    public let sequence: UInt64
    public let timestamp: TimeInterval
    public var sampleCount: Int { samples.count / 4 }
    public var frameCount: Int { sampleCount / layout.channelCount }
    public init(
        samples: Data, sampleRate: Int, sequence: UInt64, timestamp: TimeInterval,
        layout: AudioChannelLayout = .mono, capturedAt: ContinuousClock.Instant = .now
    ) throws {
        guard (8_000...192_000).contains(sampleRate), !samples.isEmpty, samples.count <= 64_000,
            samples.count.isMultiple(of: 4 * layout.channelCount),
            timestamp.isFinite, timestamp >= 0
        else { throw AudioValidationError.invalidRequest("Invalid PCM transport") }
        self.layout = layout
        self.capturedAt = capturedAt
        self.samples = samples
        self.sampleRate = sampleRate
        self.sequence = sequence
        self.timestamp = timestamp
    }
}

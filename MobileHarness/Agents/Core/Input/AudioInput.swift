import Foundation

public enum AudioValidationError: Error, Equatable, Sendable {
    case invalidRequest(String)
}

/// Transport-owned PCM. ModelKit conversion belongs to the calling perception Agent, never Gateway.
public struct AudioInput: Sendable {
    public let samples: Data
    public let sampleRate: Int
    public let sequence: UInt64
    public let timestamp: TimeInterval
    public var sampleCount: Int { samples.count / 4 }
    public init(samples: Data, sampleRate: Int, sequence: UInt64, timestamp: TimeInterval) throws {
        guard (8_000...192_000).contains(sampleRate), !samples.isEmpty, samples.count <= 64_000,
            samples.count.isMultiple(of: 4),
            timestamp.isFinite, timestamp >= 0
        else { throw AudioValidationError.invalidRequest("Invalid PCM transport") }
        self.samples = samples
        self.sampleRate = sampleRate
        self.sequence = sequence
        self.timestamp = timestamp
    }
}

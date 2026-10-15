import Foundation
import Storage

/// Interleaved PCM. Storage PCM is independent of model/device input contracts.
public struct SpeechPCMFormat: Equatable, Sendable {
    public enum Encoding: Sendable { case signedInt16, float32 }
    public let sampleRate: Int
    public let channels: Int
    public let encoding: Encoding
    public var bytesPerSample: Int { encoding == .signedInt16 ? 2 : 4 }

    public init(sampleRate: Int, channels: Int, encoding: Encoding) throws {
        guard (8_000...192_000).contains(sampleRate), (1...8).contains(channels)
        else { throw SpeechAudioError.invalidAudio }
        self.sampleRate = sampleRate
        self.channels = channels
        self.encoding = encoding
    }
}

public struct SpeechPCMFrame: Equatable, Sendable {
    public let data: Data
    public let format: SpeechPCMFormat
    public let sequence: UInt64
    public let timestamp: TimeInterval
    public var sampleCount: Int { data.count / (format.channels * format.bytesPerSample) }
    public var duration: TimeInterval { Double(sampleCount) / Double(format.sampleRate) }

    public init(data: Data, format: SpeechPCMFormat, sequence: UInt64, timestamp: TimeInterval) throws {
        guard !data.isEmpty, data.count <= 1_048_576,
            data.count % (format.channels * format.bytesPerSample) == 0,
            timestamp.isFinite, timestamp >= 0
        else { throw SpeechAudioError.invalidAudio }
        self.data = data
        self.format = format
        self.sequence = sequence
        self.timestamp = timestamp
    }
}

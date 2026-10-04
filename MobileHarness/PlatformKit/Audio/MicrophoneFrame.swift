import Foundation

public enum MicrophoneChannelLayout: Sendable, Equatable {
    case mono
    case firstOrderAmbisonicsACNSN3D
    public var channelCount: Int { self == .mono ? 1 : 4 }
}

/// Native-rate interleaved device PCM. The first FOA channel is omnidirectional W.
public struct MicrophoneFrame: Sendable {
    public let samples: [Float]
    public let sampleRate: Int
    public let layout: MicrophoneChannelLayout
    public let timestamp: TimeInterval
    public let capturedAt: ContinuousClock.Instant
    public let sequence: UInt64
    public init(
        samples: [Float], sampleRate: Int, sequence: UInt64,
        layout: MicrophoneChannelLayout = .mono, timestamp: TimeInterval = 0,
        capturedAt: ContinuousClock.Instant = .now
    ) {
        self.layout = layout
        self.timestamp = timestamp
        self.capturedAt = capturedAt
        self.samples = samples
        self.sampleRate = sampleRate
        self.sequence = sequence
    }
    public var duration: Double { Double(samples.count / layout.channelCount) / Double(max(sampleRate, 1)) }
    public var omnidirectionalSamples: [Float] {
        if layout == .mono { return samples }
        return stride(from: 0, to: samples.count, by: layout.channelCount).map { samples[$0] }
    }
    public var rms: Float {
        let values = omnidirectionalSamples
        guard !values.isEmpty else { return 0 }
        return sqrt(values.reduce(Float(0)) { $0 + $1 * $1 } / Float(values.count))
    }
}

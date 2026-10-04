import Foundation

public struct MicrophoneFrame: Sendable {
    public let samples: [Float]
    public let sampleRate: Int
    public let sequence: UInt64
    public init(samples: [Float], sampleRate: Int, sequence: UInt64) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.sequence = sequence
    }
    public var duration: Double { Double(samples.count) / Double(max(sampleRate, 1)) }
    public var rms: Float {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
    }
}

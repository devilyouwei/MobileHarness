import Foundation

/// Sample positions are relative to the start of this session (or its latest reset).
/// Each score covers contiguous input samples; it does not identify a model or backend.
public struct VoiceActivityScore: Equatable, Sendable {
    public let startSample: Int64
    public let sampleCount: Int
    public let probability: Float
    public init(startSample: Int64, sampleCount: Int, probability: Float) throws {
        guard startSample >= 0, (1...16000).contains(sampleCount), probability.isFinite,
            (0...1).contains(probability)
        else { throw CapabilityError.invalidRequest("Invalid voice activity score") }
        self.startSample = startSample
        self.sampleCount = sampleCount
        self.probability = probability
    }
}

public protocol VoiceActivityCapability: Capability {
    func detectVoiceActivity(format: AudioFormat) async throws -> any VoiceActivitySession
}

/// Ordered, backpressured input. At most 16,000 samples per call and 64 scores per result.
/// finish flushes residual input and releases the session; cancel discards residual input.
/// reset starts unrelated audio, clearing recurrent state and sample positions.
public protocol VoiceActivitySession: Sendable {
    func process(_ frame: AudioFrame) async throws -> [VoiceActivityScore]
    func finish() async throws -> [VoiceActivityScore]
    func reset() async throws
    func cancel() async
}

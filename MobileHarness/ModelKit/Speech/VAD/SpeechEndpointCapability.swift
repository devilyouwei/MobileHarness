/// Scores whether a speaker has finished a turn after acoustic silence is detected.
public protocol SpeechEndpointCapability: Capability {
    /// Accepts 1...128,000 samples of 16 kHz mono Float32 PCM from the current turn.
    /// Returns a probability in 0...1, or nil when no provider is ready.
    func completionProbability(for samples: [Float]) async throws -> Float?
}

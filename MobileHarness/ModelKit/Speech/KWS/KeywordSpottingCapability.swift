/// One keyword in the model vocabulary, supplied by the consumer.
public struct SpeechKeyword: Sendable {
    public static let defaultThreshold: Float = 0.25
    public let label: String
    public let tokens: [String]
    public let standalone: Bool
    public let threshold: Float

    public init(
        label: String, tokens: [String], standalone: Bool = false, threshold: Float = SpeechKeyword.defaultThreshold
    ) {
        self.label = label
        self.tokens = tokens
        self.standalone = standalone
        self.threshold = threshold
    }
}

public protocol KeywordSpottingCapability: Sendable {
    var availability: CapabilityAvailability { get async }
    /// A cold or absent optional resource returns nil and does not start a load.
    func openKeywords(_ keywords: [SpeechKeyword]) async throws -> (any KeywordSpottingSession)?
}

public protocol KeywordSpottingSession: Sendable {
    /// Accepts bounded 16 kHz mono PCM. The first matched label seals the stream.
    func accept(_ samples: [Float]) async throws -> String?
    func cancel() async
}

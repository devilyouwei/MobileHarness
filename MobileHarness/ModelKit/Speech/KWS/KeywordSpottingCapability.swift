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
    /// Accepts bounded 16 kHz mono PCM. The first match seals the stream.
    func accept(_ samples: [Float]) async throws -> KeywordSpottingMatch?
    func cancel() async
}

public struct KeywordSpottingMatch: Sendable, Equatable {
    public struct Metadata: Sendable, Equatable {
        public let model: InferenceModelIdentity
        /// Cumulative inference work for this stream through the match.
        public let inferenceDuration: Duration

        public init(model: InferenceModelIdentity, inferenceDuration: Duration) {
            self.model = model
            self.inferenceDuration = inferenceDuration
        }
    }

    public let label: String
    public let metadata: Metadata

    public init(label: String, metadata: Metadata) {
        self.label = label
        self.metadata = metadata
    }
}

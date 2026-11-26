import AgentCore
import Foundation

/// A keyword match in captured speech, correlated to the same utterance as VAD and ASR.
public struct SpeechKeywordMatch: Codable, Sendable, Equatable {
    public static let contract = "perception.speech.keyword.v1"
    public static let channel = "perception.speech.keyword"
    public static let event = "keywordMatched"

    public struct Detection: Codable, Sendable, Equatable {
        public let modelID: String
        public let modelName: String?
        public let inferenceDuration: Duration
        public let completedAt: Duration

        public init(modelID: String, modelName: String?, inferenceDuration: Duration, completedAt: Duration) {
            self.modelID = modelID
            self.modelName = modelName
            self.inferenceDuration = inferenceDuration
            self.completedAt = completedAt
        }
    }

    public let generation: String
    public let utterance: String
    public let label: String
    public let keyword: String
    public let onset: Duration
    public let matchedAt: Duration
    public let detection: Detection?

    public init(
        generation: String, utterance: String, label: String, keyword: String, onset: Duration, matchedAt: Duration,
        detection: Detection? = nil
    ) {
        self.generation = generation
        self.utterance = utterance
        self.label = label
        self.keyword = keyword
        self.onset = onset
        self.matchedAt = matchedAt
        self.detection = detection
    }

    func validate() throws {
        guard [generation, utterance, label, keyword].allSatisfy({ (1...128).contains($0.utf8.count) }),
            onset <= matchedAt
        else { throw CommunicationError.invalidPayload }
        if let detection {
            guard (1...128).contains(detection.modelID.utf8.count),
                detection.modelName.map({ (1...128).contains($0.utf8.count) }) ?? true,
                onset <= detection.completedAt, detection.inferenceDuration >= .zero
            else { throw CommunicationError.invalidPayload }
        }
    }

    public func message() -> AgentMessage {
        .init(
            contract: Self.contract, content: self, maximumBytes: 1024, event: Self.event,
            validate: { try $0.validate() })
    }
}

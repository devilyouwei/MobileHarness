import AgentCore
import Foundation

/// A keyword match in captured speech, correlated to the same utterance as VAD and ASR.
public struct SpeechKeywordMatch: Codable, Sendable, Equatable {
    public static let contract = "perception.speech.keyword.v1"
    public static let channel = "perception.speech.keyword"
    public static let event = "keywordMatched"

    public let generation: String
    public let utterance: String
    public let label: String
    public let keyword: String
    public let onset: Duration
    public let matchedAt: Duration

    public init(
        generation: String, utterance: String, label: String, keyword: String, onset: Duration, matchedAt: Duration
    ) {
        self.generation = generation
        self.utterance = utterance
        self.label = label
        self.keyword = keyword
        self.onset = onset
        self.matchedAt = matchedAt
    }

    func validate() throws {
        guard [generation, utterance, label, keyword].allSatisfy({ (1...128).contains($0.utf8.count) }),
            onset <= matchedAt
        else { throw CommunicationError.invalidPayload }
    }

    public func message() -> AgentMessage {
        .init(
            contract: Self.contract, content: self, maximumBytes: 1024, event: Self.event,
            validate: { try $0.validate() })
    }
}

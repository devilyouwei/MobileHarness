import AgentCore
import Foundation

/// Streaming transcription. Every admitted utterance can end with text, empty text, or recognition failure.
public struct SpeechRecognition: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case partial, final }

    public static let contract = "user.input.speech.v1"
    public static let channel = "user.input.speech"
    public let kind: Kind
    public let text: String
    public let generation: String?
    public let failure: String?
    public let oldestWindowBeforeOnset: Duration?

    public init(
        _ kind: Kind, text: String, generation: String?, failure: String? = nil,
        oldestWindowBeforeOnset: Duration? = nil
    ) {
        self.kind = kind
        self.text = text
        self.generation = generation
        self.failure = failure
        self.oldestWindowBeforeOnset = oldestWindowBeforeOnset
    }

    func validate() throws {
        guard text.utf8.count <= (kind == .final ? 4096 : 16_000),
            generation.map({ (1...128).contains($0.utf8.count) }) ?? true,
            failure.map({ kind == .final && text.isEmpty && (1...512).contains($0.utf8.count) }) ?? true
        else { throw CommunicationError.invalidPayload }
    }

    public func message() -> AgentMessage {
        .init(contract: Self.contract, content: self, event: kind.rawValue, validate: { try $0.validate() })
    }
}

extension InputPayload {
    public var speechRecognition: SpeechRecognition? {
        guard case .observation(let message) = self, message.contract == SpeechRecognition.contract else { return nil }
        return message.content(as: SpeechRecognition.self)
    }
}

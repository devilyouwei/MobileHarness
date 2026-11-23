import AgentCore
import Foundation

/// Speech facts SpeechPerception publishes for any subscriber: capture generations and utterance onset/lifecycle.
/// No audio or text; the final text travels as `user.input.speech.v1`.
public struct SpeechActivity: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case captureStarted, captureStopped
        /// Whether the current capture generation cancels echo, so full duplex may be used.
        case duplexSupport
        /// A voice-activity onset candidate began, or ended before it was confirmed as speech.
        case onsetStarted, onsetCleared
        /// The candidate was confirmed; `utterance` identifies the new utterance.
        case onsetConfirmed
        /// An utterance was retired without a final text: empty or failed recognition, or failed publication.
        case utteranceEnded
        case utterancesCleared
        /// The perception Agent stopped.
        case ended
    }
    public static let contract = "perception.speech.activity.v1"
    public static let channel = "perception.speech.activity"

    public let kind: Kind
    public let generation: String?
    public let utterance: String?
    public let fullDuplex: Bool?

    public init(_ kind: Kind, generation: String? = nil, utterance: String? = nil, fullDuplex: Bool? = nil) {
        self.kind = kind
        self.generation = generation
        self.utterance = utterance
        self.fullDuplex = fullDuplex
    }

    func validate() throws {
        let valid: Bool
        switch kind {
        case .captureStarted, .captureStopped: valid = generation != nil
        case .duplexSupport: valid = fullDuplex != nil
        case .onsetConfirmed, .utteranceEnded: valid = utterance != nil
        case .onsetStarted, .onsetCleared, .utterancesCleared, .ended: valid = true
        }
        guard valid, [generation, utterance].allSatisfy({ ($0?.utf8.count ?? 0) <= 128 }) else {
            throw CommunicationError.invalidPayload
        }
    }

    public func message() -> AgentMessage {
        AgentMessage(
            contract: Self.contract, content: self, maximumBytes: 1024, event: kind.rawValue,
            validate: { try $0.validate() })
    }
}

extension InputPayload {
    public var speechActivity: SpeechActivity? {
        guard case .observation(let message) = self, message.contract == SpeechActivity.contract else { return nil }
        return message.content(as: SpeechActivity.self)
    }
}

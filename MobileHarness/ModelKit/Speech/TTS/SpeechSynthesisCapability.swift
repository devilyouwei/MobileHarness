import Foundation

public struct SpeechSynthesisRequest: Sendable {
    public let context: InferenceContext
    public let text: String
    public let locale: String
    public init(text: String, locale: String, context: InferenceContext = InferenceContext()) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !locale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw CapabilityError.invalidRequest("Missing synthesis text or locale") }
        self.text = text
        self.locale = locale
        self.context = context
    }
}

public enum SynthesisEvent: Equatable, Sendable {
    case audio(AudioFrame)
    case finished
    public var estimatedBytes: Int {
        switch self {
        case .audio(let frame): frame.data.count + 64
        case .finished: 32
        }
    }
}

public protocol SpeechSynthesisCapability: Capability {
    /// Produces audio; it must not open the speaker, request permissions, or capture a microphone.
    func synthesize(_ request: SpeechSynthesisRequest) async throws -> InferenceSession<SynthesisEvent>
}

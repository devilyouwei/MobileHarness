import Foundation

public struct ChatMessage: Equatable, Sendable {
    public enum Role: String, Sendable { case system, user, assistant }
    public let role: Role
    public let content: String
    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public struct ChatRequest: Sendable {
    public let context: InferenceContext
    public let messages: [ChatMessage]
    public let maximumOutputTokens: Int?
    public let temperature: Double

    public init(
        messages: [ChatMessage], context: InferenceContext = InferenceContext(),
        maximumOutputTokens: Int? = nil, temperature: Double = 0.7
    ) throws {
        guard !messages.isEmpty, maximumOutputTokens.map { $0 > 0 } ?? true, temperature.isFinite,
            (0...2).contains(temperature)
        else { throw CapabilityError.invalidRequest("Invalid chat messages or generation options") }
        self.context = context
        self.messages = messages
        self.maximumOutputTokens = maximumOutputTokens
        self.temperature = temperature
    }
}

public enum ChatEvent: Equatable, Sendable {
    public enum FinishReason: Sendable { case stop, lengthLimit }
    case text(String)
    case finished(FinishReason)

    public var estimatedBytes: Int {
        switch self {
        case .text(let value): value.utf8.count + 32
        case .finished: 32
        }
    }
}

public protocol ChatCapability: Capability {
    /// Each call owns its generation state. History is supplied by the caller, never shared implicitly.
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent>
}

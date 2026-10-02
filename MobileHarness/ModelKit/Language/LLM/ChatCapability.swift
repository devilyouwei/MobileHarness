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

/// Provider-neutral function declaration; schema is validated at the capability boundary.
public struct ChatToolDefinition: Sendable {
    public let name: String
    public let declaration: Data
    public init(declaration: Data) throws {
        guard declaration.count <= 65536,
            let object = try JSONSerialization.jsonObject(with: declaration) as? [String: Any],
            object["type"] as? String == "function",
            let function = object["function"] as? [String: Any],
            let name = function["name"] as? String, !name.isEmpty, name.utf8.count <= 64,
            function["parameters"] is [String: Any]
        else { throw CapabilityError.invalidRequest("Invalid tool declaration") }
        self.name = name
        self.declaration = declaration
    }
}

public struct ChatToolCall: Equatable, Sendable {
    public let id: String
    public let name: String
    public let argumentsJSON: String
    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct ChatRequest: Sendable {
    public let context: InferenceContext
    public let messages: [ChatMessage]
    public let maximumOutputTokens: Int?
    public let temperature: Double
    public let tools: [ChatToolDefinition]

    public init(
        messages: [ChatMessage], context: InferenceContext = InferenceContext(),
        maximumOutputTokens: Int? = nil, temperature: Double = 0.7, tools: [ChatToolDefinition] = []
    ) throws {
        guard !messages.isEmpty, maximumOutputTokens.map({ $0 > 0 }) ?? true, temperature.isFinite,
            (0...2).contains(temperature)
        else { throw CapabilityError.invalidRequest("Invalid chat messages or generation options") }
        guard tools.count <= 128, Set(tools.map(\.name)).count == tools.count,
            tools.reduce(0, { $0 + $1.declaration.count }) <= 65536
        else { throw CapabilityError.invalidRequest("Tool declarations exceed limits or contain duplicates") }
        self.tools = tools
        self.context = context
        self.messages = messages
        self.maximumOutputTokens = maximumOutputTokens
        self.temperature = temperature
    }
}

public enum ChatEvent: Equatable, Sendable {
    public enum FinishReason: Sendable { case stop, lengthLimit, toolCalls }
    case text(String)
    case toolCall(ChatToolCall)
    case finished(FinishReason)

    public var estimatedBytes: Int {
        switch self {
        case .text(let value): value.utf8.count + 32
        case .toolCall(let call): call.id.utf8.count + call.name.utf8.count + call.argumentsJSON.utf8.count + 64
        case .finished: 32
        }
    }
}

public protocol ChatCapability: Capability {
    var supportsToolCalls: Bool { get async }
    /// Each call owns its generation state. History is supplied by the caller, never shared implicitly.
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent>
}

public extension ChatCapability {
    var supportsToolCalls: Bool { get async { false } }
}

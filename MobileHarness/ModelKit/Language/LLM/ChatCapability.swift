import Foundation
import Synchronization

/// Safe protocol evidence, independent of Agent policy, UI strings and provider response bodies.
public struct ChatFailureDiagnostic: Equatable, Sendable, CustomStringConvertible {
    public enum Reason: String, Sendable {
        case malformedEvent = "response.malformedEvent"
        case invalidText = "response.invalidText"
        case invalidItem = "response.invalidItem"
        case invalidToolIdentity = "tool.invalidIdentity"
        case undeclaredTool = "tool.undeclaredName"
        case invalidToolArguments = "tool.invalidArguments"
        case toolArgumentsMismatch = "tool.argumentsMismatch"
        case toolSequence = "tool.sequenceMismatch"
        case invalidCompletion = "response.invalidCompletion"
        case invalidUsage = "response.invalidUsage"
        case invalidReasoning = "response.invalidReasoning"
        case unsupportedOutput = "response.unsupportedOutput"
        case providerFailure = "provider"
        case httpStatus = "httpStatus"
        case invalidHTTPResponse = "response.invalidHTTP"
        case unexpectedContentType = "response.contentType"
        case truncatedStream = "stream.truncated"
        case responseTooLarge = "stream.limitExceeded"
        case transport
    }
    public enum Stage: String, Sendable {
        case http, framing, event, toolStart, toolArguments, toolEnd, completion, usage, reasoning
    }
    public let reason: Reason
    public let stage: Stage
    public let event: String?
    public let field: String?
    public let outputIndex: Int?
    public let toolName: String?
    public let declaredNames: [String]
    public let declaredCount: Int
    public let statusCode: Int?
    public let providerCode: String?
    public init(
        _ reason: Reason, stage: Stage, event: String? = nil, field: String? = nil, outputIndex: Int? = nil,
        toolName: String? = nil, declaredNames: [String] = [], statusCode: Int? = nil, providerCode: String? = nil
    ) {
        self.reason = reason
        self.stage = stage
        self.event = event.map { Self.identifier($0, limit: 96) }
        self.field = field.map { Self.identifier($0, limit: 96) }
        self.outputIndex = outputIndex
        self.toolName = toolName.map { Self.identifier($0, limit: 64) }
        self.declaredNames = declaredNames.prefix(8).map { Self.identifier($0, limit: 64) }
        self.declaredCount = declaredNames.count
        self.statusCode = statusCode
        self.providerCode = providerCode.map { Self.identifier($0, limit: 128) }
    }
    private static func identifier(_ value: String, limit: Int) -> String {
        guard !value.isEmpty, value.utf8.count <= limit,
            value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) })
        else { return "<invalid-identifier>" }
        return value
    }
    public var description: String {
        var lines = ["code=\(reason.rawValue)", "stage=\(stage.rawValue)"]
        if let event { lines.append("event=\(event)") }
        if let field { lines.append("field=\(field)") }
        if let outputIndex { lines.append("outputIndex=\(outputIndex)") }
        if let toolName { lines.append("tool=\(toolName)") }
        if declaredCount > 0 || reason == .undeclaredTool {
            lines.append("declaredTools(\(declaredCount))=\(declaredNames.joined(separator: ","))")
            if declaredCount > declaredNames.count { lines.append("declaredToolsTruncated=true") }
        }
        if let statusCode { lines.append("httpStatus=\(statusCode)") }
        if let providerCode { lines.append("providerCode=\(providerCode)") }
        return lines.joined(separator: "\n")
    }
}

public protocol ChatFailureProviding: Error {
    var chatFailure: ChatFailureDiagnostic { get }
}

/// Bounded image bytes, independent of platform images and Agent storage.
public struct ChatImage: Codable, Equatable, Sendable {
    public let id: String
    public let mimeType: String
    public let data: Data
    public init(id: String, mimeType: String = "image/jpeg", data: Data) throws {
        guard ["image/jpeg", "image/png"].contains(mimeType), !data.isEmpty, data.count <= 4 * 1024 * 1024 else {
            throw CapabilityError.invalidRequest("Image attachment exceeds limits or has unsupported MIME")
        }
        self.id = id
        self.mimeType = mimeType
        self.data = data
    }
}

public struct ChatMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case system, user, assistant, tool }
    public let role: Role
    public let content: String
    public let toolCalls: [ChatToolCall]
    public let toolCallID: String?
    public let images: [ChatImage]?
    public init(
        role: Role, content: String, toolCalls: [ChatToolCall] = [], toolCallID: String? = nil, images: [ChatImage] = []
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.images = images.isEmpty ? nil : images
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

public struct ChatToolCall: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let argumentsJSON: String
    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// Per-request provider timing. Sampling never waits for the consumer or persistence.
public final class ChatTiming: Sendable {
    public struct Snapshot: Sendable, Equatable {
        public let startedAt: Date
        public let firstTokenAt: Date?
        public let firstTokenLatency: Double?
    }
    private struct State {
        var startedAt: Date?
        var started: ContinuousClock.Instant?
        var firstTokenAt: Date?
        var latency: Double?
    }
    private let state = Mutex(State())
    public init() {}
    public func start() {
        state.withLock {
            guard $0.started == nil else { return }
            $0.startedAt = Date()
            $0.started = .now
        }
    }
    public func recordText(_ text: String) {
        guard !text.isEmpty else { return }
        recordFirstOutput()
    }
    /// Called by the provider after validating a streamed native argument delta's identity.
    public func recordToolArguments(_ delta: String) {
        guard !delta.isEmpty else { return }
        recordFirstOutput()
    }
    private func recordFirstOutput() {
        state.withLock {
            guard let start = $0.started, $0.firstTokenAt == nil else { return }
            let elapsed = start.duration(to: .now).components
            $0.firstTokenAt = Date()
            $0.latency = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }
    }
    public var snapshot: Snapshot? {
        state.withLock {
            guard let start = $0.startedAt else { return nil }
            return Snapshot(startedAt: start, firstTokenAt: $0.firstTokenAt, firstTokenLatency: $0.latency)
        }
    }
}

public struct ChatRequest: Sendable {
    public var timing: ChatTiming?
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
        var pending: Set<String> = []
        var callIDs: Set<String> = []
        var bytes = 0
        var imageCount = 0
        var imageBytes = 0
        guard messages.count <= 64 else { throw CapabilityError.invalidRequest("Chat transcript exceeds bounds") }
        for message in messages {
            bytes += message.content.utf8.count
            if let images = message.images {
                guard message.role == .user else { throw CapabilityError.invalidRequest("Images require user role") }
                for image in images {
                    _ = try ChatImage(id: image.id, mimeType: image.mimeType, data: image.data)
                    imageCount += 1
                    imageBytes += image.data.count
                }
            }
            if message.role == .tool {
                guard message.toolCalls.isEmpty, let id = message.toolCallID, pending.remove(id) != nil else {
                    throw CapabilityError.invalidRequest("Uncorrelated tool result")
                }
                bytes += id.utf8.count
            } else {
                guard pending.isEmpty, message.toolCallID == nil,
                    message.toolCalls.isEmpty || message.role == .assistant
                else {
                    throw CapabilityError.invalidRequest("Incomplete tool transcript")
                }
                for call in message.toolCalls {
                    guard !call.id.isEmpty, call.id.utf8.count <= 512, !call.name.isEmpty,
                        call.name.utf8.count <= 64, call.argumentsJSON.utf8.count <= 4096,
                        callIDs.insert(call.id).inserted
                    else {
                        throw CapabilityError.invalidRequest("Invalid native call transcript")
                    }
                    pending.insert(call.id)
                    bytes += call.id.utf8.count + call.name.utf8.count + call.argumentsJSON.utf8.count
                }
            }
        }
        guard pending.isEmpty, bytes <= 65_536, imageCount <= 4, imageBytes <= 16 * 1024 * 1024 else {
            throw CapabilityError.invalidRequest("Incomplete or oversized tool transcript")
        }
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

public struct ChatTokenUsage: Equatable, Sendable {
    public let input: Int
    public let generated: Int
    public let total: Int
    public let cachedInput: Int?
    public let cacheWriteInput: Int?
    public init(
        input: Int, generated: Int, total: Int, cachedInput: Int? = nil, cacheWriteInput: Int? = nil
    ) throws {
        guard input >= 0, generated >= 0, total >= 0,
            cachedInput.map({ (0...input).contains($0) }) ?? true,
            cacheWriteInput.map({ (0...input).contains($0) }) ?? true,
            (cachedInput ?? 0) <= input - (cacheWriteInput ?? 0)
        else {
            throw CapabilityError.invalidRequest("Invalid token usage")
        }
        self.input = input
        self.generated = generated
        self.total = total
        self.cachedInput = cachedInput
        self.cacheWriteInput = cacheWriteInput
    }
}

public enum ChatEvent: Equatable, Sendable {
    public enum FinishReason: Sendable { case stop, lengthLimit, toolCalls }
    case text(String)
    case toolCall(ChatToolCall)
    case usage(ChatTokenUsage)
    case finished(FinishReason)

    public var estimatedBytes: Int {
        switch self {
        case .text(let value): value.utf8.count + 32
        case .toolCall(let call): call.id.utf8.count + call.name.utf8.count + call.argumentsJSON.utf8.count + 64
        case .usage: 88
        case .finished: 32
        }
    }
}

public protocol ChatCapability: Capability {
    var supportsToolCalls: Bool { get async }
    var supportsImages: Bool { get async }
    /// Each call owns its generation state. History is supplied by the caller, never shared implicitly.
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent>
}

extension ChatCapability {
    public var supportsToolCalls: Bool { get async { false } }
    public var supportsImages: Bool { get async { false } }
}

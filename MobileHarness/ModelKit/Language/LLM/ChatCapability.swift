import Foundation

/// Safe protocol evidence, independent of Agent policy, UI strings and provider response bodies.
public struct ChatFailureDiagnostic: Equatable, Sendable, CustomStringConvertible {
    public enum NetworkReason: String, Sendable { case timeout, dns, tls, connection, offline, cancelled, other }
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
        case http, stream, framing, event, toolStart, toolArguments, toolEnd, completion, usage, reasoning
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
    public let networkReason: NetworkReason?
    public let networkCode: Int?
    public let requestID: String?
    public let providerType: String?
    public let providerParameter: String?
    public let providerMessage: String?
    public init(
        _ reason: Reason, stage: Stage, event: String? = nil, field: String? = nil, outputIndex: Int? = nil,
        toolName: String? = nil, declaredNames: [String] = [], statusCode: Int? = nil, providerCode: String? = nil,
        networkReason: NetworkReason? = nil, networkCode: Int? = nil, requestID: String? = nil,
        providerType: String? = nil, providerParameter: String? = nil, providerMessage: String? = nil
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
        self.networkReason = networkReason
        self.networkCode = networkCode
        self.requestID = requestID.map { Self.identifier($0, limit: 128) }
        self.providerType = providerType.map { Self.identifier($0, limit: 128) }
        self.providerParameter = providerParameter.map { Self.identifier($0, limit: 128) }
        self.providerMessage = providerMessage.map { String($0.prefix(1024)) }
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
        if let networkReason { lines.append("networkReason=\(networkReason.rawValue)") }
        if let networkCode { lines.append("networkCode=\(networkCode)") }
        if let requestID { lines.append("requestID=\(requestID)") }
        if let providerType { lines.append("providerType=\(providerType)") }
        if let providerParameter { lines.append("providerParameter=\(providerParameter)") }
        if let providerMessage { lines.append("providerMessage=\(providerMessage)") }
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
    /// String parameters for which a provider may accept a JSON integer and emit its decimal string.
    public let integerStringParameters: Set<String>
    public init(declaration: Data, integerStringParameters: Set<String> = []) throws {
        guard declaration.count <= 65536,
            let object = try JSONSerialization.jsonObject(with: declaration) as? [String: Any],
            object["type"] as? String == "function",
            let function = object["function"] as? [String: Any],
            let name = function["name"] as? String, !name.isEmpty, name.utf8.count <= 64,
            let parameters = function["parameters"] as? [String: Any]
        else { throw CapabilityError.invalidRequest("Invalid tool declaration") }
        let properties = parameters["properties"] as? [String: [String: Any]]
        guard integerStringParameters.allSatisfy({ properties?[$0]?["type"] as? String == "string" }) else {
            throw CapabilityError.invalidRequest("Integer compatibility requires declared string parameters")
        }
        self.name = name
        self.declaration = declaration
        self.integerStringParameters = integerStringParameters
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

public typealias ChatTiming = InferenceTiming

extension InferenceTiming {
    public func recordText(_ text: String) {
        guard !text.isEmpty else { return }
        recordFirstOutput()
    }
    /// Called by the provider after validating a streamed native argument delta's identity.
    public func recordToolArguments(_ delta: String) {
        guard !delta.isEmpty else { return }
        recordFirstOutput()
    }
}

/// Application-layer HTTP evidence. The consumer owns persistence; providers never import business storage.
public enum ChatTransportEvent: Sendable {
    case request(method: String, url: String, headers: [String: String], body: Data, at: Date)
    case response(status: Int, headers: [String: String], at: Date)
    case bytes(Data, at: Date)
    case finished(at: Date, error: String?)
}

public enum ChatToolChoice: Sendable, Equatable {
    case automatic
    case required(name: String)
}

public struct ChatRequest: Sendable {
    public static let maximumImageCount = 5
    /// Called after provider preparation, immediately before HTTP dispatch or native inference.
    public var onDispatch: (@Sendable () async throws -> Void)?
    public var onModelDispatch: (@Sendable (InferenceModelIdentity) async throws -> Void)?
    @_spi(InferenceAdapter) public var inferenceMetadata: InferenceMetadataRecorder?
    public var metadata: InferenceMetadata? { inferenceMetadata?.snapshot }
    public var transportCapture: (@Sendable (ChatTransportEvent) async -> Void)?
    public var timing: ChatTiming?
    public let context: InferenceContext
    public let messages: [ChatMessage]
    public let maximumOutputTokens: Int?
    public let temperature: Double
    public let tools: [ChatToolDefinition]
    public let toolChoice: ChatToolChoice

    public init(
        messages: [ChatMessage], context: InferenceContext = InferenceContext(),
        maximumOutputTokens: Int? = nil, temperature: Double = 0.7, tools: [ChatToolDefinition] = [],
        toolChoice: ChatToolChoice = .automatic
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
                        call.name.utf8.count <= 64,
                        callIDs.insert(call.id).inserted
                    else {
                        throw CapabilityError.invalidRequest("Invalid native call transcript")
                    }
                    pending.insert(call.id)
                    // Native arguments are opaque payload; the provider owns its actual token window.
                    bytes += call.id.utf8.count + call.name.utf8.count
                }
            }
        }
        guard pending.isEmpty, bytes <= 65_536, imageCount <= Self.maximumImageCount, imageBytes <= 16 * 1024 * 1024
        else {
            throw CapabilityError.invalidRequest("Incomplete or oversized tool transcript")
        }
        guard tools.count <= 128, Set(tools.map(\.name)).count == tools.count,
            tools.reduce(0, { $0 + $1.declaration.count }) <= 65536
        else { throw CapabilityError.invalidRequest("Tool declarations exceed limits or contain duplicates") }
        if case .required(let name) = toolChoice, !tools.contains(where: { $0.name == name }) {
            throw CapabilityError.invalidRequest("Required tool is not declared")
        }
        self.toolChoice = toolChoice
        self.tools = tools
        self.context = context
        self.messages = messages
        self.maximumOutputTokens = maximumOutputTokens
        self.temperature = temperature
    }
}

extension ChatRequest {
    /// Prepare an observation value for one call, including failures before a session is returned.
    public func measuringInference() -> Self { measuringInference(model: nil) }

    @_spi(InferenceAdapter) public func measuringInference(model: InferenceModelIdentity?) -> Self {
        var request = self
        let recorder = inferenceMetadata ?? InferenceMetadataRecorder(model: model, timing: timing)
        recorder.bind(model)
        request.inferenceMetadata = recorder
        request.timing = recorder.timing
        return request
    }

    /// Called at the existing provider dispatch boundary, once preparation has succeeded.
    @_spi(InferenceAdapter) public func dispatchInference() async throws {
        try Task.checkCancellation()
        try await onDispatch?()
        if let model = inferenceMetadata?.snapshot.model { try await onModelDispatch?(model) }
        try Task.checkCancellation()
        timing?.start()
    }

    @_spi(InferenceAdapter) public func makeInferenceSession(
        limits: StreamLimits, onTermination: @escaping @Sendable (SessionTermination) -> Void,
        phase: InferencePhase = .running, waitForCompletion: @escaping @Sendable () async -> Void
    ) -> (session: InferenceSession<ChatEvent>, emitter: InferenceEmitter<ChatEvent>) {
        let recorder = inferenceMetadata ?? InferenceMetadataRecorder(timing: timing)
        return InferenceSession<ChatEvent>.make(
            context: context, limits: limits, estimatedBytes: { $0.estimatedBytes },
            onTermination: onTermination, phase: phase, waitForCompletion: waitForCompletion,
            metadata: recorder,
            onEvent: { event in
                switch event {
                case .usage(let usage): recorder.recordUsage(usage)
                case .finished(let reason): recorder.recordFinishReason(reason)
                case .text, .toolCall: break
                }
            })
    }
}

public typealias ChatTokenUsage = InferenceTokenUsage

public enum ChatEvent: Equatable, Sendable {
    public typealias FinishReason = InferenceFinishReason
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

/// Immutable model selection handle. Inference resources and concurrency belong to the SDK.
public struct ChatModel: Sendable {
    public let modelName: String?
    public let capability: any ChatCapability
    public init(capability: any ChatCapability, modelName: String? = nil) {
        self.capability = capability
        self.modelName = modelName
    }
}

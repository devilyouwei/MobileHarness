import Foundation
import ModelKit

/// Assembly configuration only. Keep credentials in the host's secure storage, never in Agent JSON.
public struct OpenAIChatConfiguration: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let defaultBaseURL = "https://api.openai.com/v1"
    public static let defaultModel = "gpt-4o-mini"

    public static func endpoint(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.isEmpty ? defaultBaseURL : trimmed) else {
            throw CapabilityError.invalidRequest("Invalid HTTP/HTTPS endpoint")
        }
        return url
    }

    public enum Thinking: Sendable { case minimum, enabled }
    public let thinking: Thinking
    public let baseURL: URL
    public let model: String
    public let timeout: TimeInterval
    private let apiKey: String

    public init(baseURL: URL, apiKey: String, model: String, timeout: TimeInterval = 60, thinking: Thinking = .minimum)
        throws
    {
        guard ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""), baseURL.host?.isEmpty == false,
            baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
            !apiKey.contains(where: { $0.isNewline }),
            !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            timeout.isFinite, (1...600).contains(timeout)
        else { throw CapabilityError.invalidRequest("Invalid HTTP/HTTPS endpoint, credential, model or timeout") }
        self.baseURL = baseURL
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.timeout = timeout
        self.thinking = thinking
    }

    public var description: String { "OpenAIChatConfiguration(credentials: redacted)" }
    public var debugDescription: String { description }

    /// Uses the same validated endpoint and credential; no chat or billable generation is requested.
    public static func models(baseURL: URL, apiKey: String) async throws -> [String] {
        let configuration = try Self(baseURL: baseURL, apiKey: apiKey, model: "discovery", timeout: 30)
        return try await configuration.fetchModels(sessionConfiguration: .ephemeral)
    }

    func fetchModels(sessionConfiguration: URLSessionConfiguration) async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout
        sessionConfiguration.timeoutIntervalForResource = timeout
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCache = nil
        let session = URLSession(configuration: sessionConfiguration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw OpenAIChatError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else {
                throw OpenAIChatError.httpStatus(response.statusCode)
            }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 1024 * 1024 else { throw OpenAIChatError.responseTooLarge }
                data.append(byte)
            }
            return try Self.decodeModels(data)
        } catch is CancellationError { throw CancellationError() } catch let error as OpenAIChatError {
            throw error
        } catch { throw OpenAIChatError.transport }
    }

    static func decodeModels(_ data: Data) throws -> [String] {
        struct List: Decodable {
            struct Item: Decodable { let id: String }
            let data: [Item]
        }
        guard let list = try? JSONDecoder().decode(List.self, from: data), list.data.count <= 2048 else {
            throw OpenAIChatError.invalidResponse
        }
        var seen: Set<String> = []
        let ids = list.data.map(\.id)
        guard ids.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 512 })
        else {
            throw OpenAIChatError.invalidResponse
        }
        return ids.filter { seen.insert($0).inserted }
    }

    func redactedProviderMessage(_ message: String) -> String {
        var value = apiKey.isEmpty ? message : message.replacingOccurrences(of: apiKey, with: "[redacted]")
        for pattern in [#"(?i)Bearer\s+[^\s,;\"']+"#, #"\bsk-[A-Za-z0-9_-]+"#, #"(?i)https?://[^\s<>\"']+"#] {
            value = value.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return String(value.map { $0.isNewline || $0.isWhitespace ? " " : $0 }.prefix(1024))
    }

    static func toolNames(_ tools: [ChatToolDefinition], historical: [ChatToolCall] = []) -> [String: String] {
        var names = tools.map(\.name)
        var seen = Set(names)
        names += historical.compactMap { seen.insert($0.name).inserted ? $0.name : nil }
        return Dictionary(
            uniqueKeysWithValues: names.enumerated().map { index, name in
                let stem = name.map { character in
                    character.isASCII && (character.isLetter || character.isNumber || character == "_")
                        ? character : "_"
                }
                return (String(stem.prefix(48)) + "_" + String(index), name)
            })
    }

    func request(_ chat: ChatRequest) throws -> URLRequest {
        guard chat.messages.count <= 64,
            chat.messages.reduce(0, { $0 + $1.content.utf8.count }) <= 65536
        else { throw CapabilityError.invalidRequest("Cloud chat exceeds message limits") }
        var request = URLRequest(url: baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let names = Self.toolNames(chat.tools, historical: chat.messages.flatMap(\.toolCalls))
        var input: [[String: Any]] = []
        for message in chat.messages {
            if message.role == .tool {
                guard let id = message.toolCallID else { throw CapabilityError.invalidRequest("Missing call identity") }
                input.append(["type": "function_call_output", "call_id": id, "output": message.content])
                continue
            }
            if !message.content.isEmpty || message.toolCalls.isEmpty {
                var parts: [[String: Any]] = [
                    message.role == .assistant
                        ? ["type": "output_text", "text": message.content, "annotations": []]
                        : ["type": "input_text", "text": message.content]
                ]
                parts += (message.images ?? []).map {
                    [
                        "type": "input_image",
                        "image_url": "data:\($0.mimeType);base64,\($0.data.base64EncodedString())",
                        "detail": "auto",
                    ]
                }
                input.append(["role": message.role.rawValue, "content": parts])
            }
            for call in message.toolCalls {
                guard let name = names.first(where: { $0.value == call.name })?.key else {
                    throw CapabilityError.invalidRequest("Missing transcript tool name")
                }
                input.append([
                    "type": "function_call", "call_id": call.id, "name": name,
                    "arguments": call.argumentsJSON,
                ])
            }
        }
        var body: [String: Any] = [
            "model": model, "input": input, "temperature": chat.temperature,
            "stream": true, "store": false,
        ]
        if let maximum = chat.maximumOutputTokens { body["max_output_tokens"] = maximum }
        applyThinking(in: &body)
        if !chat.tools.isEmpty {
            body["tools"] = try chat.tools.map { tool in
                guard let object = try JSONSerialization.jsonObject(with: tool.declaration) as? [String: Any],
                    var function = object["function"] as? [String: Any],
                    let name = names.first(where: { $0.value == tool.name })?.key
                else { throw CapabilityError.invalidRequest("Invalid tool declaration") }
                function["name"] = name
                function["type"] = "function"
                // Preserve optional fields instead of implicit strict schema normalization.
                function["strict"] = false
                return function
            }
            switch chat.toolChoice {
            case .automatic: body["tool_choice"] = "auto"
            case .required(let name):
                guard let encoded = names.first(where: { $0.value == name })?.key else {
                    throw CapabilityError.invalidRequest("Required tool is not declared")
                }
                body["tool_choice"] = ["type": "function", "name": encoded]
                body["parallel_tool_calls"] = false
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func applyThinking(in body: inout [String: Any]) {
        let host = baseURL.host?.lowercased() ?? ""
        let name = model.lowercased()
        let isAliyun =
            host.hasSuffix(".maas.aliyuncs.com")
            || [
                "dashscope.aliyuncs.com", "dashscope-intl.aliyuncs.com", "dashscope-us.aliyuncs.com",
                "cn-hongkong.dashscope.aliyuncs.com", "coding.dashscope.aliyuncs.com",
            ].contains(host)
        if isAliyun {
            body["enable_thinking"] = thinking == .enabled
            if thinking == .minimum { body["reasoning"] = ["effort": "none"] }
            return
        }
        let reasoning =
            name == "gpt-5" || name.hasPrefix("gpt-5-") || name.hasPrefix("gpt-5.")
            || name == "gpt-6" || name.hasPrefix("gpt-6-") || name.hasPrefix("gpt-6.")
            || ["o1", "o3", "o4"].contains(where: { name == $0 || name.hasPrefix($0 + "-") })
        guard reasoning, !name.hasSuffix("-chat-latest") else { return }
        let minimum: String
        if name == "gpt-5-pro" || name.hasPrefix("gpt-5-pro-") || name.hasPrefix("o1-pro") {
            minimum = "high"
        } else if name.contains("-pro") {
            minimum = "medium"
        } else if name.contains("-codex") || name.hasPrefix("gpt-6-astra") || name.hasPrefix("gpt-6.1-sol")
            || ["o1", "o3", "o4"].contains(where: { name == $0 || name.hasPrefix($0 + "-") })
        {
            minimum = "low"
        } else if name == "gpt-5" || name.hasPrefix("gpt-5-") {
            minimum = "minimal"
        } else {
            minimum = "none"
        }
        let effort = thinking == .minimum ? minimum : (minimum == "high" ? "high" : "medium")
        body["reasoning"] = ["effort": effort]
        if effort != "none" { body.removeValue(forKey: "temperature") }

    }
}

/// Excludes raw response bodies, URLs and credentials; retains safe structured provider/network evidence.
public enum OpenAIChatError: Error, Equatable, Sendable, ChatFailureProviding, CustomStringConvertible {
    case httpStatus(Int)
    case invalidResponse
    case providerCode(String)
    case unsupportedOutput
    case truncatedStream
    case responseTooLarge
    case transport
    case responseFailure(ChatFailureDiagnostic)

    public var chatFailure: ChatFailureDiagnostic {
        switch self {
        case .responseFailure(let failure): failure
        case .httpStatus(let status): .init(.httpStatus, stage: .http, statusCode: status)
        case .invalidResponse: .init(.malformedEvent, stage: .event)
        case .providerCode(let code): .init(.providerFailure, stage: .event, providerCode: code)
        case .unsupportedOutput: .init(.unsupportedOutput, stage: .event)
        case .truncatedStream: .init(.truncatedStream, stage: .framing)
        case .responseTooLarge: .init(.responseTooLarge, stage: .framing)
        case .transport: .init(.transport, stage: .http)
        }
    }
    public var description: String { chatFailure.description }
}

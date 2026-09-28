import Foundation
import ModelKit

/// Assembly configuration only. Keep credentials in the host's secure storage, never in Agent JSON.
public struct OpenAIChatConfiguration: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let defaultBaseURL = "https://api.openai.com/v1"
    public static let defaultModel = "gpt-4o-mini"

    public static func endpoint(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.isEmpty ? defaultBaseURL : trimmed) else {
            throw CapabilityError.invalidRequest("Invalid HTTPS endpoint")
        }
        return url
    }

    public let baseURL: URL
    public let model: String
    public let timeout: TimeInterval
    private let apiKey: String

    public init(baseURL: URL, apiKey: String, model: String, timeout: TimeInterval = 60) throws {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host?.isEmpty == false,
            baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
            !apiKey.contains(where: { $0.isNewline }),
            !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            timeout.isFinite, (1...600).contains(timeout)
        else { throw CapabilityError.invalidRequest("Invalid HTTPS endpoint, credential, model or timeout") }
        self.baseURL = baseURL
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.timeout = timeout
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
        return ids.filter { isLikelyChatModel($0) && seen.insert($0).inserted }
    }

    // /models has no standard capability field. Exclude known non-chat families while
    // retaining opaque third-party deployment names; discovery is not a compatibility probe.
    static func isLikelyChatModel(_ id: String) -> Bool {
        let name = id.lowercased()
        let excluded = [
            "embedding", "embed-", "rerank", "moderation", "whisper", "tts", "transcribe",
            "transcription", "realtime", "audio", "dall-e", "dalle", "image", "sora",
            "stable-diffusion", "flux", "video", "davinci", "babbage", "gpt-3.5-turbo-instruct",
            "deep-research", "computer-use", "codex",
        ]
        if excluded.contains(where: { name.contains($0) }) { return false }
        return !["o1-pro", "o3-pro", "gpt-5-pro", "gpt-5.2-pro", "gpt-5.4-pro", "gpt-5.5-pro"].contains {
            name == $0 || name.hasPrefix($0 + "-")
        }
    }

    func request(_ chat: ChatRequest) throws -> URLRequest {
        guard chat.messages.count <= 64,
            chat.messages.reduce(0, { $0 + $1.content.utf8.count }) <= 65536,
            chat.maximumOutputTokens.map { $0 <= 32768 } ?? true
        else { throw CapabilityError.invalidRequest("Cloud chat exceeds message or output limits") }
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var body: [String: Any] = [
            "model": model,
            "messages": chat.messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "temperature": chat.temperature, "stream": true,
        ]
        if let maximum = chat.maximumOutputTokens { body["max_tokens"] = maximum }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

/// Deliberately excludes response bodies, URLs and credentials from surfaced failures.
public enum OpenAIChatError: Error, Equatable, Sendable {
    case httpStatus(Int)
    case invalidResponse
    case unsupportedOutput
    case truncatedStream
    case responseTooLarge
    case transport
}

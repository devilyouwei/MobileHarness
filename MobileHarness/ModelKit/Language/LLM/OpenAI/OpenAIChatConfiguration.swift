import Foundation
import ModelKit

/// Assembly configuration only. Keep credentials in the host's secure storage, never in Agent JSON.
public struct OpenAIChatConfiguration: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let baseURL: URL
    public let model: String
    public let timeout: TimeInterval
    private let apiKey: String

    public init(baseURL: URL, apiKey: String, model: String, timeout: TimeInterval = 60) throws {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host?.isEmpty == false,
            baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
            !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !apiKey.contains(where: { $0.isNewline }),
            !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            timeout.isFinite, (1...600).contains(timeout)
        else { throw CapabilityError.invalidRequest("Invalid HTTPS endpoint, credential, model or timeout") }
        self.baseURL = baseURL
        self.apiKey = apiKey
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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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

    func request(_ chat: ChatRequest) throws -> URLRequest {
        guard chat.messages.count <= 64,
            chat.messages.reduce(0, { $0 + $1.content.utf8.count }) <= 65536,
            chat.maximumOutputTokens <= 32768
        else { throw CapabilityError.invalidRequest("Cloud chat exceeds message or output limits") }
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": chat.messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "temperature": chat.temperature, "max_tokens": chat.maximumOutputTokens, "stream": true,
        ])
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

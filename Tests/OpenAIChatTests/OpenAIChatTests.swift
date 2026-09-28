import Foundation
@_spi(ModelManagement) import ModelKit
@_spi(ModelAssembly) import ModelKitRuntime
import Testing

@testable import ModelKitOpenAI

private func config() throws -> OpenAIChatConfiguration {
    try OpenAIChatConfiguration(
        baseURL: #require(URL(string: "https://example.test/custom/v1/")), apiKey: "test-only", model: "third-party")
}

@Test func configurationAndRequest() throws {
    let configuration = try config()
    let request = try configuration.request(
        ChatRequest(
            messages: [.init(role: .system, content: "Instructions"), .init(role: .user, content: "你好")],
            maximumOutputTokens: 42, temperature: 0))
    #expect(request.url?.absoluteString == "https://example.test/custom/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only")
    let bodyData = try #require(request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    #expect(body["model"] as? String == "third-party")
    #expect(body["max_tokens"] as? Int == 42)
    #expect(body["stream"] as? Bool == true)
    #expect(!String(reflecting: configuration).contains("test-only"))
    for url in ["http://example.test", "https://user:pass@example.test", "https://example.test?key=secret"] {
        #expect(throws: (any Error).self) {
            try OpenAIChatConfiguration(baseURL: #require(URL(string: url)), apiKey: "key", model: "model")
        }
    }
    #expect(throws: (any Error).self) {
        try OpenAIChatConfiguration(
            baseURL: #require(URL(string: "https://example.test")), apiKey: "key\r\nInjected: yes", model: "model")
    }
}

private func decode(_ text: String) throws -> [ChatEvent] {
    var decoder = ChatEventDecoder()
    var result: [ChatEvent] = []
    for byte in text.utf8 { result += try decoder.consume(byte) }
    return result
}

@Test func streamingFramingAndUnicode() throws {
    let wire =
        ": heartbeat\r\ndata: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"你好\"},\"finish_reason\":null}]}\r\n\r\n"
        + "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"length\"}]}\n\n"
    #expect(try decode(wire) == [.text("你好"), .finished(.lengthLimit)])
    #expect(try decode("data: {\ndata: \"choices\": []}\n\n").isEmpty)
}

@Test func rejectsMalformedUnsupportedAndOversizeStreams() throws {
    #expect(throws: OpenAIChatError.truncatedStream) { try decode("data: [DONE]\n\n") }
    #expect(throws: OpenAIChatError.invalidResponse) { try decode("data: {broken}\n\n") }
    #expect(throws: OpenAIChatError.unsupportedOutput) {
        try decode("data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[]},\"finish_reason\":null}]}\n\n")
    }
    #expect(throws: OpenAIChatError.responseTooLarge) { try decode(String(repeating: "x", count: 65537)) }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let text =
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello\"},\"finish_reason\":null}]}\n\n"
            + "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func managedCapabilityStreamsAndShutsDown() async throws {
    let manager = ModelManager()
    let configuration = try config()
    try await manager.register(
        ModelRegistration(id: ModelID("cloud"), capabilities: [.chat]) { context in
            ProvidedCapabilities(
                chat: try OpenAIChat(
                    context: context, configuration: configuration,
                    sessionConfiguration: {
                        let settings = URLSessionConfiguration.ephemeral
                        settings.protocolClasses = [StubProtocol.self]
                        return settings
                    }))
        }, defaults: [.chat])
    let capability = try await manager.get(.chat)
    let request = try ChatRequest(messages: [.init(role: .user, content: "Hi")])
    let session = try await capability.chat(request)
    #expect(session.context == request.context)
    var events: [ChatEvent] = []
    for try await event in session.events { events.append(event) }
    #expect(events == [.text("Hello"), .finished(.stop)])
    try await manager.unload(.chat)
    let next = try await capability.chat(request)
    for try await _ in next.events {}
    await manager.shutdown()
    await #expect(throws: CapabilityError.sessionClosed) { try await capability.chat(request) }
}

private final class HangingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

@Test func overlapCancellationAndShutdown() async throws {
    let manager = ModelManager()
    let configuration = try config()
    try await manager.register(
        ModelRegistration(id: ModelID("cloud"), capabilities: [.chat]) { context in
            ProvidedCapabilities(
                chat: try OpenAIChat(
                    context: context, configuration: configuration,
                    sessionConfiguration: {
                        let settings = URLSessionConfiguration.ephemeral
                        settings.protocolClasses = [HangingProtocol.self]
                        return settings
                    }))
        }, defaults: [.chat])
    let chat = try await manager.get(.chat)
    let request = try ChatRequest(messages: [.init(role: .user, content: "Hello")])
    let session = try await chat.chat(request)
    await #expect(throws: CapabilityError.inputBusy) { try await chat.chat(request) }
    session.cancel()
    var iterator = session.events.makeAsyncIterator()
    await #expect(throws: CancellationError.self) { try await iterator.next() }
    // unload joins the cancelled request before reusing its admission lease.
    try await manager.unload(.chat)
    let next = try await chat.chat(request)
    await manager.shutdown()
    var nextIterator = next.events.makeAsyncIterator()
    await #expect(throws: CancellationError.self) { try await nextIterator.next() }
}

private final class ErrorProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: [:])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("secret-provider-response".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func httpErrorsAreSanitized() async throws {
    let chat = try OpenAIChat(
        context: ModelContext(), configuration: config(),
        sessionConfiguration: {
            let settings = URLSessionConfiguration.ephemeral
            settings.protocolClasses = [ErrorProtocol.self]
            return settings
        })
    let session = try await chat.chat(ChatRequest(messages: [.init(role: .user, content: "Hi")]))
    await #expect(throws: OpenAIChatError.httpStatus(401)) {
        for try await _ in session.events {}
    }
}

@Test func modelDiscoveryValidation() throws {
    #expect(
        try OpenAIChatConfiguration.decodeModels(
            Data(#"{"data":[{"id":"model-a"},{"id":"model-b"},{"id":"model-a"}]}"#.utf8)) == ["model-a", "model-b"])
    #expect(try OpenAIChatConfiguration.decodeModels(Data(#"{"data":[]}"#.utf8)).isEmpty)
    #expect(throws: OpenAIChatError.invalidResponse) {
        try OpenAIChatConfiguration.decodeModels(Data(#"{"data":[{"id":""}]}"#.utf8))
    }
}

@Test func replacementClosesOldCapabilityAndPreservesOtherModels() async throws {
    let manager = ModelManager()
    let configuration = try config()
    func registration(_ id: String) throws -> ModelRegistration {
        try ModelRegistration(id: ModelID(id), capabilities: [.chat]) { context in
            ProvidedCapabilities(
                chat: try OpenAIChat(
                    context: context, configuration: configuration,
                    sessionConfiguration: {
                        let settings = URLSessionConfiguration.ephemeral
                        settings.protocolClasses = [HangingProtocol.self]
                        return settings
                    }))
        }
    }
    try await manager.register(registration("cloud"), defaults: [.chat])
    try await manager.register(registration("other"))
    let old = try await manager.get(.chat)
    let other = try await manager.get(ModelID("other"), as: .chat)
    let request = try ChatRequest(messages: [.init(role: .user, content: "Hi")])
    let session = try await old.chat(request)
    await #expect(throws: CapabilityError.invalidRequest("candidate failure")) {
        try await manager.replace(
            ModelRegistration(id: ModelID("cloud"), capabilities: [.chat]) { _ in
                throw CapabilityError.invalidRequest("candidate failure")
            })
    }
    await #expect(throws: CapabilityError.inputBusy) { try await old.chat(request) }
    try await manager.replace(registration("cloud"))
    var events = session.events.makeAsyncIterator()
    await #expect(throws: CancellationError.self) { try await events.next() }
    await #expect(throws: CapabilityError.sessionClosed) { try await old.chat(request) }
    let replacement = try await manager.get(.chat)
    let replaced = (replacement as AnyObject) !== (old as AnyObject)
    #expect(replaced)
    let sameOther = try await manager.get(ModelID("other"), as: .chat)
    let preserved = (sameOther as AnyObject) === (other as AnyObject)
    #expect(preserved)
    let next = try await replacement.chat(request)
    next.cancel()
    await manager.shutdown()
}

private final class ModelListProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let valid =
            request.url?.path == "/custom/v1/models"
            && request.httpMethod == "GET"
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only"
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: valid ? 200 : 400, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":[{"id":"chat-a"},{"id":"chat-b"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func discoveryUsesConfiguredEndpointAndKey() async throws {
    let settings = URLSessionConfiguration.ephemeral
    settings.protocolClasses = [ModelListProtocol.self]
    let models = try await config().fetchModels(sessionConfiguration: settings)
    #expect(models == ["chat-a", "chat-b"])
}

@Test func emptyCredentialsOmitAuthorizationAndBlankEndpointUsesOfficialDefault() throws {
    for key in ["", "   "] {
        let configuration = try OpenAIChatConfiguration(
            baseURL: OpenAIChatConfiguration.endpoint("  \n "), apiKey: key,
            model: OpenAIChatConfiguration.defaultModel)
        let request = try configuration.request(ChatRequest(messages: [.init(role: .user, content: "Hi")]))
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }
}

@Test func chatDiscoveryFiltersSpecializedModelsButKeepsThirdPartyChatNames() throws {
    let allowed = ["gpt-4o-mini", "gpt-4.1", "o3-mini", "deepseek-chat", "Qwen3-Instruct", "my-deployment"]
    let excluded = [
        "text-embedding-3-small", "tts-1", "whisper-1", "gpt-4o-transcribe", "gpt-realtime",
        "gpt-image-1", "sora-2", "omni-moderation-latest", "bge-reranker", "davinci-002",
        "gpt-3.5-turbo-instruct", "o3-deep-research", "gpt-5-pro", "gpt-5.3-codex",
    ]
    let data = try JSONSerialization.data(withJSONObject: ["data": (allowed + excluded + allowed).map { ["id": $0] }])
    #expect(try OpenAIChatConfiguration.decodeModels(data) == allowed)
}

private final class AnonymousModelListProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let valid =
            request.url?.absoluteString == "https://api.openai.com/v1/models"
            && request.value(forHTTPHeaderField: "Authorization") == nil
        guard let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: valid ? 401 : 400, httpVersion: nil, headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func anonymousDiscoveryActuallyRequestsAndSurfacesServerFailure() async throws {
    let settings = URLSessionConfiguration.ephemeral
    settings.protocolClasses = [AnonymousModelListProtocol.self]
    let configuration = try OpenAIChatConfiguration(
        baseURL: OpenAIChatConfiguration.endpoint(""), apiKey: "", model: OpenAIChatConfiguration.defaultModel)
    await #expect(throws: OpenAIChatError.httpStatus(401)) {
        try await configuration.fetchModels(sessionConfiguration: settings)
    }
}

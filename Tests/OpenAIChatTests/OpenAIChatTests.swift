import Foundation
@_spi(ModelManagement) import ModelKit
@_spi(ModelAssembly) import ModelKitRuntime
import Synchronization
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
    #expect(request.url?.absoluteString == "https://example.test/custom/v1/responses")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only")
    let bodyData = try #require(request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    #expect(body["model"] as? String == "third-party")
    #expect(body["max_output_tokens"] as? Int == 42)
    #expect(body["stream"] as? Bool == true)
    #expect(body["store"] as? Bool == false)
    #expect(body["messages"] == nil && body["stream_options"] == nil && body["reasoning"] == nil)
    #expect(body["tools"] == nil && body["tool_choice"] == nil)
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
        ": heartbeat\r\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"你好\"}\n\r\n"
        + "data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"output\":[],\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}\n\n"
    #expect(try decode(wire) == [.text("你好"), .finished(.lengthLimit)])
    #expect(try decode("data: {\ndata: \"type\": \"response.in_progress\"}\n\n").isEmpty)
}

@Test func rejectsMalformedUnsupportedAndOversizeStreams() throws {
    #expect(throws: OpenAIChatError.truncatedStream) { try decode("data: [DONE]\n\n") }
    #expect(throws: OpenAIChatError.invalidResponse) { try decode("data: {broken}\n\n") }
    #expect(throws: OpenAIChatError.unsupportedOutput) {
        try decode(
            "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"unsupported\"}}\n\n"
        )
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
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n\n"
            + "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}\n\n"
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
    var request = try ChatRequest(messages: [.init(role: .user, content: "Hi")])
    let timing = ChatTiming()
    request.timing = timing
    let session = try await capability.chat(request)
    #expect(session.context == request.context)
    var events: [ChatEvent] = []
    for try await event in session.events { events.append(event) }
    #expect(events == [.text("Hello"), .finished(.stop)])
    let measured = try #require(timing.snapshot)
    #expect(measured.firstTokenAt != nil && measured.firstTokenLatency != nil)
    #expect(measured.firstTokenLatency! >= 0)
    let evidence = timing.snapshot
    timing.recordText("later")
    #expect(timing.snapshot == evidence)
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

private final class LongReplyProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var wire = ""
        for index in 0..<1024 {
            wire +=
                "data: {\"type\":\"response.output_text.delta\",\"delta\":\"\(index)你\"}\n\n"
        }
        wire += "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}\n\n"
        client?.urlProtocol(self, didLoad: Data(wire.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test(.timeLimit(.minutes(1))) func longCloudReplyCompletesBeforeConsumerStarts() async throws {
    let manager = ModelManager()
    let configuration = try config()
    try await manager.register(
        ModelRegistration(id: ModelID("long-cloud"), capabilities: [.chat]) { context in
            ProvidedCapabilities(
                chat: try OpenAIChat(
                    context: context, configuration: configuration,
                    sessionConfiguration: {
                        let settings = URLSessionConfiguration.ephemeral
                        settings.protocolClasses = [LongReplyProtocol.self]
                        return settings
                    }))
        }, defaults: [.chat])
    let chat = try await manager.get(.chat)
    let session = try await chat.chat(ChatRequest(messages: [.init(role: .user, content: "Long reply")]))
    // Unload joins producer cleanup without cancelling it. Do not consume until it releases its lease.
    try await manager.unload(.chat)
    var events: [ChatEvent] = []
    for try await event in session.events { events.append(event) }
    #expect(events == (0..<1024).map { .text("\($0)你") } + [.finished(.stop)])
    await manager.shutdown()
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
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }
}

@Test func nativeDiscoveryReturnsRawModelsWithoutBusinessEligibility() throws {
    let allowed = ["gpt-4o-mini", "gpt-4.1", "o3-mini", "deepseek-chat", "Qwen3-Instruct", "my-deployment"]
    let excluded = [
        "text-embedding-3-small", "tts-1", "whisper-1", "gpt-4o-transcribe", "gpt-realtime",
        "gpt-image-1", "sora-2", "omni-moderation-latest", "bge-reranker", "davinci-002",
        "gpt-3.5-turbo-instruct", "o3-deep-research", "gpt-5-pro", "gpt-5.3-codex",
    ]
    let data = try JSONSerialization.data(withJSONObject: ["data": (allowed + excluded + allowed).map { ["id": $0] }])
    #expect(try OpenAIChatConfiguration.decodeModels(data) == allowed + excluded)
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

@Test func defaultOutputBudgetIsOmittedFromProviderRequest() throws {
    let chat = try ChatRequest(messages: [.init(role: .user, content: "Hello")])
    #expect(chat.maximumOutputTokens == nil)
    let request = try config().request(chat)
    let data = try #require(request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(body["max_tokens"] == nil)
    #expect(body["max_completion_tokens"] == nil)
    #expect(body["max_output_tokens"] == nil)
    #expect(throws: CapabilityError.self) {
        try ChatRequest(messages: chat.messages, maximumOutputTokens: 0)
    }
}

@Test func streamReportsTerminalUsageAndRejectsInvalidCounts() throws {
    let usage =
        #"data: {"type":"response.completed","response":{"status":"completed","output":[],"usage":{"input_tokens":1,"output_tokens":2,"total_tokens":3}}}"#
        + "\n\n"
    #expect(
        try decode(usage + "data: [DONE]\n\n") == [
            .usage(try ChatTokenUsage(input: 1, generated: 2, total: 3)), .finished(.stop),
        ])
    #expect(throws: OpenAIChatError.invalidResponse) { try decode(usage + usage) }
    for invalid in ["true", "-2"] {
        #expect(throws: OpenAIChatError.invalidResponse) {
            try decode(usage.replacingOccurrences(of: "\"input_tokens\":1", with: "\"input_tokens\":" + invalid))
        }
    }
    let request = try config().request(ChatRequest(messages: [.init(role: .user, content: "usage")]))
    let data = try #require(request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(body["stream_options"] == nil)
    #expect(body["store"] as? Bool == false)
    #expect(body["max_output_tokens"] == nil)
}

private final class UsageProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in [
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hi\"}\n\n",

            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":12,\"output_tokens\":4,\"total_tokens\":16}}}\n\n",
            "data: [DONE]\n\n",
        ] { client?.urlProtocol(self, didLoad: Data(chunk.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func capabilityEmitsResponseUsageBeforeTerminalEvent() async throws {
    let manager = ModelManager()
    let configuration = try config()
    try await manager.register(
        ModelRegistration(id: ModelID("usage-fixture"), capabilities: [.chat]) { context in
            ProvidedCapabilities(
                chat: try OpenAIChat(
                    context: context, configuration: configuration,
                    sessionConfiguration: {
                        let settings = URLSessionConfiguration.ephemeral
                        settings.protocolClasses = [UsageProtocol.self]
                        return settings
                    }))
        }, defaults: [.chat])
    let session = try await manager.get(.chat).chat(ChatRequest(messages: [.init(role: .user, content: "Hi")]))
    var events: [ChatEvent] = []
    for try await event in session.events { events.append(event) }
    #expect(events == [.text("Hi"), .usage(try ChatTokenUsage(input: 12, generated: 4, total: 16)), .finished(.stop)])
    await manager.shutdown()
}

@Test func multiTurnHistoryUsesOutputTextForAssistantOnly() throws {
    let chat = try ChatRequest(messages: [
        .init(role: .system, content: "Reply briefly."),
        .init(role: .user, content: "Hello"),
        .init(role: .assistant, content: "Hi"),
        .init(role: .user, content: "Say OK"),
    ])
    let encoded = try #require(try config().request(chat).httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let input = try #require(body["input"] as? [[String: Any]])
    for (index, expected) in ["input_text", "input_text", "output_text", "input_text"].enumerated() {
        let parts = try #require(input[index]["content"] as? [[String: Any]])
        #expect(parts[0]["type"] as? String == expected)
        #expect(parts[0]["text"] as? String == chat.messages[index].content)
        if index == 2 {
            #expect((parts[0]["annotations"] as? [Any])?.isEmpty == true)
        } else {
            #expect(parts[0]["annotations"] == nil)
        }
    }
}

@Test func nativeContinuationSerializesMatchingAliasesAndToolReceipt() throws {
    let declaration = try ChatToolDefinition(
        declaration: Data(
            #"{"type":"function","function":{"name":"Read.State","parameters":{"type":"object","properties":{},"required":[]}}}"#
                .utf8))
    let request = try ChatRequest(
        messages: [
            .init(role: .user, content: "Read state"),
            .init(
                role: .assistant, content: "", toolCalls: [.init(id: "call-1", name: "Read.State", argumentsJSON: "{}")]
            ),
            .init(role: .tool, content: "actual state", toolCallID: "call-1"),
        ], tools: [declaration])
    let data = try #require(config().request(request).httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let messages = try #require(body["input"] as? [[String: Any]])
    #expect(messages[1]["type"] as? String == "function_call")
    #expect(messages[1]["name"] as? String == "Read_State_0")
    #expect(messages[1]["call_id"] as? String == "call-1")
    #expect(messages[2]["type"] as? String == "function_call_output")
    #expect(messages[2]["call_id"] as? String == "call-1")
    let tools = try #require(body["tools"] as? [[String: Any]])
    #expect(tools[0]["name"] as? String == "Read_State_0")
    #expect(tools[0]["function"] == nil)
    #expect(throws: CapabilityError.self) {
        try ChatRequest(messages: [.init(role: .tool, content: "forged", toolCallID: "missing")])
    }
    let withText = try ChatRequest(
        messages: [
            .init(role: .user, content: "Read state"),
            .init(
                role: .assistant, content: "I will read the state.",
                toolCalls: [.init(id: "call-1", name: "Read.State", argumentsJSON: "{}")]),
            .init(role: .tool, content: "actual state", toolCallID: "call-1"),
        ], tools: [declaration])
    let withTextData = try #require(config().request(withText).httpBody)
    let withTextBody = try #require(JSONSerialization.jsonObject(with: withTextData) as? [String: Any])
    let withTextInput = try #require(withTextBody["input"] as? [[String: Any]])
    let parts = try #require(withTextInput[1]["content"] as? [[String: Any]])
    #expect(parts[0]["type"] as? String == "output_text")
    #expect(withTextInput[2]["type"] as? String == "function_call")
    #expect(withTextInput[3]["type"] as? String == "function_call_output")
    #expect(withTextInput[2]["call_id"] as? String == withTextInput[3]["call_id"] as? String)
}

@Test func photoAttachmentsEncodeAsNativeImageContentAndHaveSeparateBounds() throws {
    let bytes = Data([0xff, 0xd8, 0xff, 0xd9])
    let image = try ChatImage(id: UUID(), data: bytes)
    let chat = try ChatRequest(messages: [.init(role: .user, content: "Describe the captured photo", images: [image])])
    let encoded = try #require(try config().request(chat).httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let messages = try #require(body["input"] as? [[String: Any]])
    let content = try #require(messages[0]["content"] as? [[String: Any]])
    #expect(content[0]["text"] as? String == "Describe the captured photo")
    #expect(content[1]["type"] as? String == "input_image")
    let url = try #require(content[1]["image_url"] as? String)
    #expect(url == "data:image/jpeg;base64," + bytes.base64EncodedString())
    #expect(content[1]["detail"] as? String == "auto")
    #expect(throws: (any Error).self) {
        try ChatRequest(messages: [.init(role: .assistant, content: "bad", images: [image])])
    }
    #expect(throws: (any Error).self) {
        try ChatRequest(messages: [.init(role: .user, content: "bad", images: Array(repeating: image, count: 5))])
    }
    #expect(throws: (any Error).self) { try ChatImage(id: UUID(), data: Data(count: 4 * 1024 * 1024 + 1)) }
    let old = Data("{\"role\":\"user\",\"content\":\"old\",\"toolCalls\":[]}".utf8)
    #expect(try JSONDecoder().decode(ChatMessage.self, from: old).images == nil)
}

@Test func modelInterfaceTimingIgnoresEmptyTextAndPreservesFirstSample() throws {
    let timing = ChatTiming()
    timing.recordText("before request")
    #expect(timing.snapshot == nil)
    timing.start()
    let start = try #require(timing.snapshot)
    #expect(start.firstTokenAt == nil && start.firstTokenLatency == nil)
    timing.recordText("")
    #expect(timing.snapshot == start)
    timing.start()
    #expect(timing.snapshot == start)
    timing.recordText("first")
    let first = try #require(timing.snapshot)
    #expect(first.startedAt == start.startedAt && first.firstTokenAt != nil)
    #expect(first.firstTokenLatency.map { $0 >= 0 } == true)
    timing.recordText("second")
    #expect(timing.snapshot == first)
}

private func eventWire(_ object: [String: Any]) throws -> String {
    "data: " + String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n\n"
}

@Test func responsesFunctionCallsRequireCompletedValidatedPairs() throws {
    let added: [String: Any] = ["type": "function_call", "id": "item-1", "call_id": "call-1", "name": "Read_State_0"]
    var completed = added
    completed["arguments"] = "{}"
    let prefix =
        try eventWire(["type": "response.output_item.added", "output_index": 0, "item": added])
        + eventWire([
            "type": "response.function_call_arguments.delta", "output_index": 0, "item_id": "item-1", "delta": "{",
        ])
        + eventWire([
            "type": "response.function_call_arguments.delta", "output_index": 0, "item_id": "item-1", "delta": "}",
        ])
    let itemDone = try eventWire(["type": "response.output_item.done", "output_index": 0, "item": completed])
    let terminal = try eventWire([
        "type": "response.completed", "response": ["status": "completed", "output": [completed]],
    ])
    func parse(_ wire: String) throws -> [ChatEvent] {
        var decoder = ChatEventDecoder(toolNames: ["Read_State_0": "Read.State"])
        var events: [ChatEvent] = []
        for byte in wire.utf8 { events += try decoder.consume(byte) }
        return events
    }
    #expect(try parse(prefix + itemDone).isEmpty)
    #expect(
        try parse(prefix + itemDone + terminal) == [
            .toolCall(.init(id: "call-1", name: "Read.State", argumentsJSON: "{}")), .finished(.toolCalls),
        ])
    #expect(throws: OpenAIChatError.invalidResponse) { try parse(prefix + terminal) }
    #expect(throws: OpenAIChatError.invalidResponse) {
        try parse(prefix + itemDone.replacingOccurrences(of: "call-1", with: "forged"))
    }
    #expect(throws: OpenAIChatError.invalidResponse) {
        try parse(prefix + itemDone + eventWire(["type": "response.failed", "response": ["status": "failed"]]))
    }
    #expect(throws: OpenAIChatError.unsupportedOutput) {
        try decode(try eventWire(["type": "response.refusal.delta", "delta": "refusal"]))
    }
    #expect(throws: OpenAIChatError.truncatedStream) {
        try parse(
            prefix
                + eventWire([
                    "type": "response.incomplete",
                    "response": [
                        "status": "incomplete", "output": [], "incomplete_details": ["reason": "max_output_tokens"],
                    ],
                ]))
    }
}

private final class ReusableProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.httpBody.map({ String(decoding: $0, as: UTF8.self).contains("hang") }) == true { return }
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let wire =
            #"data: {"type":"response.output_text.delta","delta":"reused"}"# + "\n\n"
            + #"data: {"type":"response.completed","response":{"status":"completed","output":[]}}"# + "\n\n"
        client?.urlProtocol(self, didLoad: Data(wire.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test(.timeLimit(.minutes(1))) func cancelledRequestDoesNotDestroyReusableSession() async throws {
    let count = Mutex(0)
    let manager = ModelManager()
    let configuration = try config()
    try await manager.register(
        ModelRegistration(id: ModelID("reuse"), capabilities: [.chat]) { context in
            ProvidedCapabilities(
                chat: try OpenAIChat(
                    context: context, configuration: configuration,
                    sessionConfiguration: {
                        count.withLock { $0 += 1 }
                        let settings = URLSessionConfiguration.ephemeral
                        settings.protocolClasses = [ReusableProtocol.self]
                        return settings
                    }))
        }, defaults: [.chat])
    let capability = try await manager.get(.chat)
    let hung = try await capability.chat(ChatRequest(messages: [.init(role: .user, content: "hang")]))
    hung.cancel()
    await #expect(throws: CancellationError.self) { for try await _ in hung.events {} }
    // Wait for lease cleanup without unloading (which intentionally closes the pooled session).
    var next: InferenceSession<ChatEvent>?
    for _ in 0..<1000 {
        do {
            next = try await capability.chat(ChatRequest(messages: [.init(role: .user, content: "next")]))
            break
        } catch CapabilityError.inputBusy { await Task.yield() }
    }
    let accepted = try #require(next)
    var events: [ChatEvent] = []
    for try await event in accepted.events { events.append(event) }
    #expect(events == [.text("reused"), .finished(.stop)])
    let again = try await capability.chat(ChatRequest(messages: [.init(role: .user, content: "again")]))
    for try await _ in again.events {}
    #expect(count.withLock { $0 } == 1)
    try await manager.unload(.chat)
    let reloaded = try await capability.chat(ChatRequest(messages: [.init(role: .user, content: "reload")]))
    for try await _ in reloaded.events {}
    #expect(count.withLock { $0 } == 2)
    await manager.shutdown()
    await #expect(throws: CapabilityError.sessionClosed) {
        try await capability.chat(ChatRequest(messages: [.init(role: .user, content: "closed")]))
    }
}

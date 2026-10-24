import Foundation
@_spi(ModelManagement) import ModelKit
@_spi(ModelAssembly) import ModelKitRuntime
import Synchronization
import Testing

@testable import ModelKitOpenAI

private func config(replyFragments: Int? = nil) throws -> OpenAIChatConfiguration {
    try OpenAIChatConfiguration(
        baseURL: #require(URL(string: "https://example.test/\(replyFragments.map { "reply-\($0)" } ?? "custom")/v1/")),
        apiKey: "test-only", model: "third-party")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_LIVE_CHAT"] == "1"))
func liveProviderPreservesConsecutiveUsers() async throws {
    let environment = ProcessInfo.processInfo.environment
    let endpoint = try #require(environment["HARNESS_LIVE_CHAT_URL"])
    let key = try #require(environment["HARNESS_LIVE_CHAT_KEY"])
    let model = try #require(environment["HARNESS_LIVE_CHAT_MODEL"])
    let configuration = try OpenAIChatConfiguration(
        baseURL: OpenAIChatConfiguration.endpoint(endpoint), apiKey: key, model: model, timeout: 60)
    let context = try ModelContext(loadGate: ModelLoadGate(maximumConcurrentLoads: 4), maximumLoadWaiters: 32)
    let capability = try OpenAIChat(context: context, configuration: configuration)
    var chat = try ChatRequest(
        messages: [
            .init(role: .system, content: "Respond briefly in Chinese."),
            .init(role: .user, content: "请记住数字 12。"),
            .init(role: .user, content: "只回答：收到。"),
            .init(role: .assistant, content: "收到。"),
            .init(role: .user, content: "把刚才的数字加 3。"),
            .init(role: .user, content: "只回答最终数字。"),
        ], maximumOutputTokens: 64, temperature: 0)
    let timing = ChatTiming()
    chat.timing = timing
    let http = try configuration.request(chat)
    let data = try #require(http.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let input = try #require(body["input"] as? [[String: Any]])
    let roles = input.compactMap { $0["role"] as? String }
    #expect(roles == chat.messages.map { $0.role.rawValue })
    #expect(input.count == chat.messages.count)
    print("LIVE_CHAT model=\(model) source_messages=\(chat.messages.count) encoded_roles=\(roles)")
    do {
        let session = try await capability.chat(chat)
        var text = ""
        var completed = false
        for try await event in session.events {
            if case .text(let delta) = event { text += delta }
            if case .finished = event { completed = true }
        }
        #expect(completed)
        #expect(!text.isEmpty)
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == "15")
        print(
            "LIVE_CHAT completed=\(completed) text_bytes=\(text.utf8.count) ttft=\(String(describing: timing.snapshot?.firstTokenLatency))"
        )
        try await context.unload()
    } catch {
        try await context.unload()
        print("LIVE_CHAT capability_error=\(error)")
        // Explicit diagnostic only: this is not a production retry or fallback.
        let (data, response) = try await URLSession.shared.data(for: http)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        print("LIVE_CHAT diagnostic_status=\(status)")
        if data.count <= 65536,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            let detail = object["error"] as? [String: Any] ?? object
            for field in ["code", "type", "message"] {
                if let value = detail[field] as? String {
                    print(
                        "LIVE_CHAT \(field)=\(String(value.replacingOccurrences(of: key, with: "[REDACTED]").prefix(2048)))"
                    )
                }
            }
        }
        if status == 200, data.count <= 65536 {
            var seen: Set<String> = []
            for line in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
            where line.hasPrefix("data:") {
                guard
                    let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
                else { continue }
                let item = object["item"] as? [String: Any] ?? [:]
                let response = object["response"] as? [String: Any] ?? [:]
                let output = response["output"] as? [[String: Any]] ?? []
                let summary =
                    "event=\(object["type"] ?? "missing") item=\(item["type"] ?? "none") "
                    + "status=\(response["status"] ?? "none") output_types=\(output.compactMap { $0["type"] as? String })"
                if seen.insert(summary).inserted {
                    print(
                        "LIVE_CHAT SSE \(String(summary.replacingOccurrences(of: key, with: "[REDACTED]").prefix(2048)))"
                    )
                }
            }
        }
        throw error
    }
}

@Test func aliyunRequestsDisableThinkingForChatAndTitles() throws {
    for endpoint in [
        "https://dashscope.aliyuncs.com/compatible-mode/v1",
        "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        "https://workspace.cn-beijing.maas.aliyuncs.com/compatible-mode/v1",
    ] {
        let configuration = try OpenAIChatConfiguration(
            baseURL: OpenAIChatConfiguration.endpoint(endpoint), apiKey: "test-only", model: "qwen3.8-flash")
        for budget: Int? in [nil, 64] {
            let request = try configuration.request(
                ChatRequest(
                    messages: [.init(role: .system, content: "Instructions"), .init(role: .user, content: "Input")],
                    maximumOutputTokens: budget, temperature: 0))
            let data = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect((body["reasoning"] as? [String: String])?["effort"] == "none")
            #expect(body["enable_thinking"] as? Bool == false)
            #expect(body["max_output_tokens"] as? Int == budget)
            #expect(body["extra_body"] == nil && body["reasoning_effort"] == nil)
            #expect(body["temperature"] as? Double == 0)
        }
    }
}

@Test func openAINonThinkingParametersRespectModelAndProviderCompatibility() throws {
    for model in ["gpt-5.1", "gpt-5.2", "gpt-5.4", "gpt-5.4-2026-03-05", "gpt-5.5", "gpt-6-sol", "gpt-6-luna"] {
        for endpoint in ["https://api.openai.com/v1", "https://example.test/proxy/v1"] {
            let configuration = try OpenAIChatConfiguration(
                baseURL: OpenAIChatConfiguration.endpoint(endpoint), apiKey: "test-only", model: model)
            let request = try configuration.request(ChatRequest(messages: [.init(role: .user, content: "Hi")]))
            let data = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect((body["reasoning"] as? [String: String])?["effort"] == "none")
            #expect(body["enable_thinking"] == nil)
        }
    }
    for model in ["gpt-4.1", "gpt-4o-mini", "gpt-3.5-turbo", "gpt-5-chat-latest", "third-party"] {
        let configuration = try OpenAIChatConfiguration(
            baseURL: OpenAIChatConfiguration.endpoint("https://example.test/v1"), apiKey: "test-only", model: model)
        let request = try configuration.request(ChatRequest(messages: [.init(role: .user, content: "Hi")]))
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["reasoning"] == nil && body["enable_thinking"] == nil)
    }
}

@Test func mandatoryThinkingModelsFailWithoutSilentlyLoweringEffort() throws {
    for model in [
        "gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-5.4-pro", "gpt-5.1-codex", "gpt-6-astra", "gpt-6.1-sol", "o1", "o3",
        "o4-mini",
    ] {
        let configuration = try OpenAIChatConfiguration(
            baseURL: OpenAIChatConfiguration.endpoint("https://api.openai.com/v1"), apiKey: "test-only", model: model)
        #expect(
            throws: CapabilityError.invalidRequest(
                "Selected OpenAI model cannot disable thinking; choose a non-thinking model")
        ) {
            try configuration.request(ChatRequest(messages: [.init(role: .user, content: "Hi")]))
        }
    }
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
    for url in ["ftp://example.test", "https://user:pass@example.test", "https://example.test?key=secret"] {
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
    expectResponseFailure(.malformedEvent) { try decode("data: {broken}\n\n") }
    expectResponseFailure(.unsupportedOutput) {
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
    let manager = try ModelManager()
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
        let count = url.path.contains("reply-127") ? 127 : url.path.contains("reply-128") ? 128 : 1024
        var wire = ""
        for index in 0..<count {
            wire +=
                "data: {\"type\":\"response.output_text.delta\",\"delta\":\"\(index)你\"}\n\n"
        }
        wire += "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}\n\n"
        client?.urlProtocol(self, didLoad: Data(wire.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test(.timeLimit(.minutes(1)), arguments: [127, 128, 1024])
func longCloudReplyDrainsWithDelayedConsumer(fragmentCount: Int) async throws {
    let manager = try ModelManager()
    let configuration = try config(replyFragments: fragmentCount)
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
    let session = try await chat.chat(ChatRequest(messages: [.init(role: .user, content: "reply-\(fragmentCount)")]))
    defer { session.cancel() }
    // Consume before awaiting unload, which otherwise may wait on a full queue.
    for _ in 0..<100 { await Task.yield() }
    var events: [ChatEvent] = []
    for try await event in session.events {
        events.append(event)
        await Task.yield()
    }
    #expect(events == (0..<fragmentCount).map { .text("\($0)你") } + [.finished(.stop)])
    try await manager.unload(.chat)
    await manager.shutdown()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func pausedLongCloudReplyCanCancelOrShutdown(shutdown: Bool) async throws {
    let manager = try ModelManager()
    let configuration = try config()
    try await manager.register(
        ModelRegistration(id: ModelID("paused-cloud"), capabilities: [.chat]) { context in
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
    let request = try ChatRequest(messages: [.init(role: .user, content: "reply-1024")])
    let session = try await chat.chat(request)
    defer { session.cancel() }
    var iterator = session.events.makeAsyncIterator()
    #expect(try await iterator.next() == .text("0你"))
    // Stop consuming while the finite event queue fills.
    for _ in 0..<100 { await Task.yield() }
    if shutdown {
        await manager.shutdown()
        await #expect(throws: CapabilityError.sessionClosed) { try await chat.chat(request) }
    } else {
        session.cancel()
        try await manager.unload(.chat)
        let next = try await chat.chat(request)
        var events: [ChatEvent] = []
        for try await event in next.events { events.append(event) }
        #expect(events == (0..<1024).map { .text("\($0)你") } + [.finished(.stop)])
        await manager.shutdown()
    }
    await #expect(throws: CancellationError.self) { try await iterator.next() }
}

@Test func overlapCancellationAndShutdown() async throws {
    let manager = try ModelManager()
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
        context: ModelContext(loadGate: ModelLoadGate(maximumConcurrentLoads: 4), maximumLoadWaiters: 32),
        configuration: config(),
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
    let manager = try ModelManager()
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
    expectResponseFailure(.invalidCompletion) { try decode(usage + usage) }
    for invalid in ["true", "-2"] {
        expectResponseFailure(.invalidUsage) {
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
    let manager = try ModelManager()
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

@Test func consecutiveUsersRetainOriginalMessageAndImageBoundaries() throws {
    let image = try ChatImage(id: UUID().uuidString, mimeType: "image/png", data: Data([1, 2]))
    let messages: [ChatMessage] = [
        .init(role: .system, content: "Instructions"),
        .init(role: .user, content: "你好", images: [image]),
        .init(role: .user, content: "补充条件"),
        .init(role: .assistant, content: "Answer"),
        .init(role: .user, content: "Next"),
        .init(role: .user, content: "More"),
    ]
    let chat = try ChatRequest(messages: messages)
    let data = try #require(try config().request(chat).httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let input = try #require(body["input"] as? [[String: Any]])
    try #require(input.count == messages.count)
    #expect(input.compactMap { $0["role"] as? String } == messages.map { $0.role.rawValue })
    for (index, message) in messages.enumerated() {
        let parts = try #require(input[index]["content"] as? [[String: Any]])
        #expect(parts.first?["text"] as? String == message.content)
        #expect(parts.count == 1 + (message.images?.count ?? 0))
        if index == 1 {
            #expect(parts[1]["image_url"] as? String == "data:image/png;base64,AQI=")
        }
    }
    #expect(chat.messages == messages)
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
    #expect(tools[0]["strict"] as? Bool == false)
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
    let image = try ChatImage(id: UUID().uuidString, data: bytes)
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
    #expect(throws: (any Error).self) {
        try ChatImage(id: UUID().uuidString, data: Data(count: 4 * 1024 * 1024 + 1))
    }
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

@Test(arguments: [false, true])
func nativeArgumentTimingPreservesFirstTextOrToolSample(textFirst: Bool) throws {
    let timing = ChatTiming()
    timing.recordToolArguments("before start")
    #expect(timing.snapshot == nil)
    timing.start()
    let start = try #require(timing.snapshot)
    timing.recordToolArguments("")
    #expect(timing.snapshot == start)
    if textFirst { timing.recordText("first text") }
    let textSample = timing.snapshot
    var decoder = ChatEventDecoder(toolNames: ["Read_State_0": "Read.State"], timing: timing)
    let added: [String: Any] = [
        "type": "function_call", "id": "item-1", "call_id": "call-1", "name": "Read_State_0",
    ]
    for byte in try
        (reasoningWire()
        + eventWire(["type": "response.output_item.added", "output_index": 0, "item": added])
        + eventWire([
            "type": "response.function_call_arguments.delta", "output_index": 0, "item_id": "item-1", "delta": "",
        ])).utf8
    {
        #expect(try decoder.consume(byte).isEmpty)
    }
    #expect(timing.snapshot == textSample)
    for byte in try eventWire([
        "type": "response.function_call_arguments.delta", "output_index": 0, "item_id": "item-1", "delta": "{",
    ]).utf8 {
        #expect(try decoder.consume(byte).isEmpty)
    }
    let first = try #require(timing.snapshot)
    #expect(first.firstTokenAt != nil && first.firstTokenLatency.map { $0 >= 0 } == true)
    if textFirst { #expect(first == textSample) }
    timing.recordText("later text")
    timing.recordToolArguments("later args")
    #expect(timing.snapshot == first && !decoder.finished)

    let invalidTiming = ChatTiming()
    invalidTiming.start()
    var invalid = ChatEventDecoder(toolNames: ["Read_State_0": "Read.State"], timing: invalidTiming)
    for byte in try eventWire(["type": "response.output_item.added", "output_index": 0, "item": added]).utf8 {
        _ = try invalid.consume(byte)
    }
    expectResponseFailure(.invalidToolIdentity) {
        for byte in try eventWire([
            "type": "response.function_call_arguments.delta", "output_index": 0, "item_id": "forged", "delta": "{",
        ]).utf8 { _ = try invalid.consume(byte) }
    }
    #expect(invalidTiming.snapshot?.firstTokenAt == nil)
}

private final class NativeTimingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let url = try #require(request.url)
            let response = try #require(
                HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "text/event-stream"]))
            let item: [String: Any] = [
                "type": "function_call", "id": "item-1", "call_id": "call-1", "name": "Read_State_0", "arguments": "{}",
            ]
            let wire =
                try eventWire(["type": "response.output_item.added", "output_index": 0, "item": item])
                + eventWire([
                    "type": "response.function_call_arguments.delta", "output_index": 0, "item_id": "item-1",
                    "delta": "{}",
                ]) + eventWire(["type": "response.output_item.done", "output_index": 0, "item": item])
                + eventWire([
                    "type": "response.completed", "response": ["status": "completed", "output": [item]],
                ])
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(wire.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Test func nativeOnlyCapabilityReportsTimingWithoutPublicText() async throws {
    let capability = try OpenAIChat(
        context: ModelContext(loadGate: ModelLoadGate(maximumConcurrentLoads: 4), maximumLoadWaiters: 32),
        configuration: config(),
        sessionConfiguration: {
            let settings = URLSessionConfiguration.ephemeral
            settings.protocolClasses = [NativeTimingProtocol.self]
            return settings
        })
    let tool = try ChatToolDefinition(
        declaration: Data(
            #"{"type":"function","function":{"name":"Read.State","parameters":{"type":"object","properties":{},"required":[]}}}"#
                .utf8))
    var request = try ChatRequest(messages: [.init(role: .user, content: "read state")], tools: [tool])
    let timing = ChatTiming()
    request.timing = timing
    let session = try await capability.chat(request)
    var events: [ChatEvent] = []
    for try await event in session.events { events.append(event) }
    #expect(events == [.toolCall(.init(id: "call-1", name: "Read.State", argumentsJSON: "{}")), .finished(.toolCalls)])
    let snapshot = try #require(timing.snapshot)
    #expect(snapshot.firstTokenAt != nil && snapshot.firstTokenLatency.map { $0 >= 0 } == true)
}

private func eventWire(_ object: [String: Any]) throws -> String {
    "data: " + String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n\n"
}

private func reasoningWire() throws -> String {
    try eventWire([
        "type": "response.output_item.added", "output_index": 0,
        "item": ["type": "reasoning", "id": "reason-1", "summary": []],
    ])
        + eventWire([
            "type": "response.reasoning_text.delta", "output_index": 0, "item_id": "reason-1",
            "delta": "private thought",
        ])
        + eventWire([
            "type": "response.reasoning_text.done", "output_index": 0, "item_id": "reason-1", "text": "private thought",
        ])
        + eventWire([
            "type": "response.output_item.done", "output_index": 0,
            "item": [
                "type": "reasoning", "id": "reason-1",
                "summary": [["type": "summary_text", "text": "private thought"]],
            ],
        ])
}

@Test func responsesReasoningDoesNotBecomePublicText() throws {
    let prefix = try reasoningWire()
    #expect(try decode(prefix).isEmpty)
    let reasoning: [String: Any] = [
        "type": "reasoning", "id": "reason-1", "summary": [["type": "summary_text", "text": "private thought"]],
    ]
    let message: [String: Any] = ["type": "message", "content": [["type": "output_text", "text": "15"]]]
    let wire =
        try prefix + eventWire(["type": "response.output_text.delta", "delta": "15"])
        + eventWire(["type": "response.output_item.done", "output_index": 1, "item": message])
        + eventWire([
            "type": "response.completed",
            "response": [
                "status": "completed", "output": [reasoning, message],
                "usage": ["input_tokens": 10, "output_tokens": 20, "total_tokens": 30],
            ],
        ])
    #expect(
        try decode(wire) == [
            .text("15"), .usage(try ChatTokenUsage(input: 10, generated: 20, total: 30)), .finished(.stop),
        ])
    #expect(
        try decode(
            prefix
                + eventWire([
                    "type": "response.incomplete",
                    "response": [
                        "status": "incomplete", "output": [reasoning],
                        "incomplete_details": ["reason": "max_output_tokens"],
                    ],
                ])) == [.finished(.lengthLimit)])
    #expect(throws: OpenAIChatError.truncatedStream) { try decode(prefix + "data: [DONE]\n\n") }
}

@Test func reasoningBeforeNativeCallPreservesOriginalCallIndex() throws {
    let reasoning: [String: Any] = ["type": "reasoning", "id": "reason-1", "summary": []]
    let call: [String: Any] = [
        "type": "function_call", "id": "item-1", "call_id": "call-1", "name": "Read_State_0", "arguments": "{}",
    ]
    let summary = try eventWire([
        "type": "response.reasoning_summary_text.delta", "output_index": 0, "item_id": "reason-1",
        "summary_index": 0, "delta": "private fixture",
    ])
    let wire =
        try reasoningWire() + summary
        + eventWire(["type": "response.output_item.added", "output_index": 1, "item": call])
        + eventWire([
            "type": "response.function_call_arguments.delta", "output_index": 1, "item_id": "item-1", "delta": "{}",
        ]) + eventWire(["type": "response.output_item.done", "output_index": 1, "item": call])
        + eventWire([
            "type": "response.completed", "response": ["status": "completed", "output": [reasoning, call]],
        ])
    var decoder = ChatEventDecoder(toolNames: ["Read_State_0": "Read.State"])
    var events: [ChatEvent] = []
    for byte in wire.utf8 { events += try decoder.consume(byte) }
    #expect(events == [.toolCall(.init(id: "call-1", name: "Read.State", argumentsJSON: "{}")), .finished(.toolCalls)])
}

@Test(arguments: ["Provider_readSettings", "loadSkills", "Bluetooth_readStatus"])
func qwenUndeclaredNativeNamesFailBeforePublishingCalls(_ name: String) throws {
    let names = [
        "ModelResources_snapshot_0": "ModelResources.snapshot",
        "Provider_readSettings_1": "Provider.readSettings",
        "Bluetooth_readStatus_2": "Bluetooth.readStatus",
    ]
    let wire = try eventWire([
        "type": "response.output_item.added", "output_index": 0,
        "item": ["type": "function_call", "id": "synthetic-item", "call_id": "synthetic-call", "name": name],
    ])
    var decoder = ChatEventDecoder(toolNames: names)
    var delivered: [ChatEvent] = []
    expectResponseFailure(.undeclaredTool) {
        for byte in wire.utf8 { delivered += try decoder.consume(byte) }
    }
    #expect(delivered.isEmpty && !decoder.finished)
}

@Test func malformedReasoningMetadataIsRejected() throws {
    for item: [String: Any] in [
        ["type": "reasoning", "id": "", "summary": []],
        ["type": "reasoning", "id": "reason-1", "summary": [["type": "output_text", "text": "bad"]]],
        ["type": "reasoning", "id": "reason-1", "summary": [["type": "summary_text", "text": 1]]],
        ["type": "reasoning", "id": "reason-1"],
    ] {
        for type in ["response.output_item.added", "response.output_item.done"] {
            expectResponseFailure(.invalidReasoning) {
                try decode(try eventWire(["type": type, "output_index": 0, "item": item]))
            }
        }
        expectResponseFailure(.invalidReasoning) {
            try decode(
                try eventWire(["type": "response.completed", "response": ["status": "completed", "output": [item]]]))
        }
    }
    for type in ["response.reasoning_text.delta", "response.reasoning_text.done"] {
        expectResponseFailure(.invalidReasoning) {
            try decode(try eventWire(["type": type, "output_index": 0, "item_id": "reason-1", "delta": 1, "text": 1]))
        }
    }
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
    expectResponseFailure(.toolSequence) { try parse(prefix + terminal) }
    expectResponseFailure(.invalidToolIdentity) {
        try parse(prefix + itemDone.replacingOccurrences(of: "call-1", with: "forged"))
    }
    expectResponseFailure(.providerFailure) {
        try parse(prefix + itemDone + eventWire(["type": "response.failed", "response": ["status": "failed"]]))
    }
    expectResponseFailure(.unsupportedOutput) {
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
    let manager = try ModelManager()
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

@Test func responsesDoesNotPromoteOptionalTaskFieldsToRequired() throws {
    let declaration = try ChatToolDefinition(
        declaration: Data(
            #"{"type":"function","function":{"name":"startTask","parameters":{"type":"object","additionalProperties":false,"properties":{"goal":{"type":"string"},"target":{"type":"string"}},"required":["goal"]}}}"#
                .utf8))
    let request = try config().request(
        ChatRequest(messages: [.init(role: .user, content: "Take a photo")], tools: [declaration]))
    let encoded = try #require(request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let tools = try #require(body["tools"] as? [[String: Any]])
    #expect(tools[0]["strict"] as? Bool == false)
    let schema = try #require(tools[0]["parameters"] as? [String: Any])
    #expect(schema["required"] as? [String] == ["goal"])
    #expect((schema["properties"] as? [String: Any])?["target"] != nil)
}

@Test func historicalToolPairsSurviveReleasedCurrentCatalog() throws {
    let call = try ChatToolCall(id: "prior-call", name: "History.list", argumentsJSON: "{}")
    let request = try ChatRequest(messages: [
        .init(role: .system, content: "Current catalog has no native tools"),
        .init(role: .assistant, content: "", toolCalls: [call]),
        .init(role: .tool, content: "stored results", toolCallID: call.id),
        .init(role: .user, content: "new action request"),
    ])
    let data = try #require(config().request(request).httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(body["tools"] == nil)
    let items = try #require(body["input"] as? [[String: Any]])
    #expect(items[1]["type"] as? String == "function_call")
    #expect(items[1]["name"] as? String == "History_list_0")
    #expect(items[2]["call_id"] as? String == call.id)
    #expect(items[2]["output"] as? String == "stored results")
    #expect(OpenAIChatConfiguration.toolNames(request.tools).isEmpty)
}

@Test func providerQuotaCodeSurvivesFailedSSEWithoutMessageLeakage() throws {
    for event in [
        ["type": "error", "error": ["code": "credit_balance_exhausted", "message": "private provider detail"]],
        [
            "type": "response.failed",
            "response": [
                "status": "failed",
                "error": ["code": "credit_balance_exhausted", "message": "private provider detail"],
            ],
        ],
    ] as [[String: Any]] {
        var decoder = ChatEventDecoder()
        let json = try JSONSerialization.data(withJSONObject: event)
        let wire = "data: " + String(decoding: json, as: UTF8.self) + "\n\n"
        #expect(throws: OpenAIChatError.providerCode("credit_balance_exhausted")) {
            for byte in wire.utf8 { _ = try decoder.consume(byte) }
        }
    }
}

@Test(
    arguments: [nil, "null", "{}", "{\"cached_tokens\":0}", "{\"cached_tokens\":6,\"cache_write_tokens\":2}"]
        as [String?])
func terminalUsagePreservesOptionalCacheCounts(details: String?) throws {
    let field = details.map { ",\"input_tokens_details\":\($0)" } ?? ""
    let stream =
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":10,\"output_tokens\":2,\"total_tokens\":12\(field)}}}\n\n"
    let events = try decode(stream)
    guard case .usage(let usage) = events.first else {
        Issue.record("Missing usage")
        return
    }
    #expect(
        usage.cachedInput
            == (details?.contains("cached_tokens") == true ? (details?.contains(":6") == true ? 6 : 0) : nil))
    #expect(usage.cacheWriteInput == (details?.contains("cache_write_tokens") == true ? 2 : nil))
}

@Test(arguments: ["true", "-1", "11", "1.5", "\"2\""])
func terminalUsageRejectsInvalidCacheCounts(value: String) throws {
    for key in ["cached_tokens", "cache_write_tokens"] {
        let stream =
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":10,\"output_tokens\":2,\"total_tokens\":12,\"input_tokens_details\":{\"\(key)\":\(value)}}}}\n\n"
        expectResponseFailure(.invalidUsage) { try decode(stream) }
    }
}

@Test func responsesPreserveLateSystemFactsAfterCompleteNativePair() throws {
    let messages: [ChatMessage] = [
        .init(role: .system, content: "stable rules"), .init(role: .user, content: "query"),
        .init(role: .assistant, content: "", toolCalls: [.init(id: "call-1", name: "inspect", argumentsJSON: "{}")]),
        .init(role: .tool, content: "actual result", toolCallID: "call-1"),
        .init(role: .system, content: "CURRENT STATE: current facts"),
    ]
    let request = try config().request(ChatRequest(messages: messages))
    let data = try #require(request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let input = try #require(body["input"] as? [[String: Any]])
    #expect(input.count == 5)
    #expect(input[0]["role"] as? String == "system")
    #expect(input[2]["type"] as? String == "function_call")
    #expect(input[3]["type"] as? String == "function_call_output")
    #expect(input[4]["role"] as? String == "system")
    let content = try #require(input[4]["content"] as? [[String: Any]])
    #expect(content.first?["text"] as? String == "CURRENT STATE: current facts")
}

private func expectResponseFailure<Result>(_ reason: ChatFailureDiagnostic.Reason, _ body: () throws -> Result) {
    do {
        _ = try body()
        Issue.record("Expected typed response failure: \(reason.rawValue)")
    } catch OpenAIChatError.responseFailure(let diagnostic) {
        #expect(diagnostic.reason == reason)
    } catch {
        Issue.record("Expected response failure \(reason.rawValue), received \(error)")
    }
}

@Test func undeclaredToolDiagnosticRetainsBoundedNamesAndNeverArguments() throws {
    let names = Dictionary(uniqueKeysWithValues: (0..<12).map { ("Tool_\($0)", "Tool.\($0)") })
    let wire = try eventWire([
        "type": "response.output_item.added", "output_index": 0,
        "item": [
            "type": "function_call", "id": "item-1", "call_id": "call-1", "name": "loadSkills",
            "arguments": "PRIVATE_ARGUMENT_BODY",
        ],
    ])
    var decoder = ChatEventDecoder(toolNames: names)
    do {
        for byte in wire.utf8 { _ = try decoder.consume(byte) }
        Issue.record("Undeclared Tool was accepted")
    } catch OpenAIChatError.responseFailure(let diagnostic) {
        #expect(diagnostic.reason == .undeclaredTool && diagnostic.stage == .toolStart)
        #expect(diagnostic.event == "response.output_item.added" && diagnostic.field == "name")
        #expect(diagnostic.outputIndex == 0 && diagnostic.toolName == "loadSkills")
        #expect(diagnostic.declaredNames.count == 8 && diagnostic.declaredCount == 12)
        #expect(diagnostic.description.contains("declaredToolsTruncated=true"))
        #expect(!diagnostic.description.contains("PRIVATE_ARGUMENT_BODY"))
        #expect(!decoder.finished)
    }
    let malicious = ChatFailureDiagnostic(
        .undeclaredTool, stage: .toolStart,
        event: "response.output_item.added\nPRIVATE", toolName: "private prompt body with spaces")
    #expect(!malicious.description.contains("PRIVATE") && !malicious.description.contains("private prompt"))
    #expect(malicious.toolName == "<invalid-identifier>")
}

@Test(arguments: ["{broken", "{\"limit\":5}", "[]", "null"])
func nativeArgumentShapeAndIncrementMismatchHaveDifferentDiagnostics(arguments: String) throws {
    let added: [String: Any] = ["type": "function_call", "id": "item-1", "call_id": "call-1", "name": "Read_0"]
    var item = added
    item["arguments"] = arguments
    let prefix = try eventWire(["type": "response.output_item.added", "output_index": 0, "item": added])
    let delta = try eventWire([
        "type": "response.function_call_arguments.delta", "output_index": 0,
        "item_id": "item-1", "delta": arguments,
    ])
    let end = try eventWire(["type": "response.output_item.done", "output_index": 0, "item": item])
    func parse(_ wire: String) throws {
        var decoder = ChatEventDecoder(toolNames: ["Read_0": "Read"])
        for byte in wire.utf8 { _ = try decoder.consume(byte) }
    }
    expectResponseFailure(.invalidToolArguments) { try parse(prefix + delta + end) }
    expectResponseFailure(.toolArgumentsMismatch) { try parse(prefix + end) }
}

@Test func providerAcceptsHTTPAndHTTPSIPAddressesWithoutChangingRequestScheme() throws {
    for endpoint in ["http://192.168.1.20:11434/v1", "https://192.168.1.20:8443/v1", "http://[::1]:8080/v1"] {
        let configuration = try OpenAIChatConfiguration(
            baseURL: OpenAIChatConfiguration.endpoint(endpoint), apiKey: "", model: "test-model")
        let request = try configuration.request(ChatRequest(messages: [.init(role: .user, content: "test")]))
        #expect(request.url?.absoluteString == endpoint + "/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }
}

@Test func reasoningSummaryEventsAreValidatedAndNeverBecomeAnswerText() throws {
    var prefix = try eventWire([
        "type": "response.output_item.added", "output_index": 0,
        "item": ["type": "reasoning", "id": "reason-1", "summary": []],
    ])
    for type in [
        "response.reasoning_summary_part.added", "response.reasoning_summary_text.delta",
        "response.reasoning_summary_text.done", "response.reasoning_summary_part.done",
    ] {
        var event: [String: Any] = ["type": type, "output_index": 0, "item_id": "reason-1", "summary_index": 0]
        if type.contains("_part.") {
            event["part"] = ["type": "summary_text", "text": "private fixture"]
        } else {
            event[type.hasSuffix(".delta") ? "delta" : "text"] = "private fixture"
        }
        prefix += try eventWire(event)
        #expect(try decode(prefix).isEmpty)
        for invalid: Any in [-1, 128, true, "0", 0.5] {
            var malformed = event
            malformed["summary_index"] = invalid
            expectResponseFailure(.invalidReasoning) { try decode(try eventWire(malformed)) }
        }
        var missing = event
        missing.removeValue(forKey: "summary_index")
        expectResponseFailure(.invalidReasoning) { try decode(try eventWire(missing)) }
        var malformed = event
        if type.contains("_part.") {
            malformed["part"] = ["type": "output_text", "text": "bad"]
        } else {
            malformed[type.hasSuffix(".delta") ? "delta" : "text"] = 1
        }
        expectResponseFailure(.invalidReasoning) { try decode(try eventWire(malformed)) }
    }
    let message: [String: Any] = ["type": "message", "content": [["type": "output_text", "text": "OK"]]]
    let terminal = try eventWire([
        "type": "response.completed",
        "response": [
            "status": "completed",
            "output": [
                [
                    "type": "reasoning", "id": "reason-1",
                    "summary": [["type": "summary_text", "text": "private fixture"]],
                ], message,
            ],
        ],
    ])
    #expect(
        try decode(prefix + eventWire(["type": "response.output_text.delta", "delta": "OK"]) + terminal) == [
            .text("OK"), .finished(.stop),
        ])
    #expect(throws: OpenAIChatError.truncatedStream) { try decode(prefix + "data: [DONE]\n\n") }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_LIVE_OLLAMA"] == "1"))
func liveOllamaResponsesReasoningCompatibility() async throws {
    let endpoint = try #require(ProcessInfo.processInfo.environment["HARNESS_LIVE_CHAT_URL"])
    let model = try #require(ProcessInfo.processInfo.environment["HARNESS_LIVE_CHAT_MODEL"])
    let configuration = try OpenAIChatConfiguration(
        baseURL: OpenAIChatConfiguration.endpoint(endpoint), apiKey: "", model: model, timeout: 120)
    let context = try ModelContext(loadGate: ModelLoadGate(maximumConcurrentLoads: 4), maximumLoadWaiters: 32)
    let capability = try OpenAIChat(context: context, configuration: configuration)
    do {
        let session = try await capability.chat(
            ChatRequest(
                messages: [.init(role: .user, content: "Reply with only OK.")], maximumOutputTokens: 1024,
                temperature: 0))
        var text = ""
        var completed = false
        for try await event in session.events {
            if case .text(let delta) = event { text += delta }
            if case .finished(.stop) = event { completed = true }
        }
        #expect(completed)
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == "OK")
        print(
            "OLLAMA_LIVE completed=\(completed) answer_matches=\(text.trimmingCharacters(in: .whitespacesAndNewlines) == "OK")"
        )
        let tool = try ChatToolDefinition(
            declaration: Data(
                #"{"type":"function","function":{"name":"Read.State","description":"Read a synthetic test state","parameters":{"type":"object","properties":{},"required":[]}}}"#
                    .utf8))
        let prompt = ChatMessage(
            role: .user,
            content:
                "Call the Read.State tool exactly once with empty arguments to read the test state. Do not answer before calling the tool."
        )
        let toolSession = try await capability.chat(
            ChatRequest(messages: [prompt], maximumOutputTokens: 1024, temperature: 0, tools: [tool]))
        var calls: [ChatToolCall] = []
        var toolFinished = false
        for try await event in toolSession.events {
            if case .toolCall(let call) = event { calls.append(call) }
            if case .finished(.toolCalls) = event { toolFinished = true }
        }
        #expect(toolFinished && calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.name == "Read.State" && call.argumentsJSON == "{}")
        let continuation = try await capability.chat(
            ChatRequest(
                messages: [
                    prompt, .init(role: .assistant, content: "", toolCalls: calls),
                    .init(role: .tool, content: "Test state is OK. Reply with only OK.", toolCallID: call.id),
                ], maximumOutputTokens: 1024, temperature: 0, tools: [tool]))
        var answer = ""
        var continuationFinished = false
        for try await event in continuation.events {
            if case .text(let delta) = event { answer += delta }
            if case .finished(.stop) = event { continuationFinished = true }
        }
        #expect(continuationFinished && answer.trimmingCharacters(in: .whitespacesAndNewlines) == "OK")
        print("OLLAMA_LIVE native_call_validated=\(toolFinished) continuation_completed=\(continuationFinished)")
        try await context.unload()
    } catch {
        try await context.unload()
        throw error
    }
}

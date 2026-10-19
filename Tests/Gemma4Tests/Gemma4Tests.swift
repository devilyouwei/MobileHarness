import Foundation
@_spi(ModelManagement) import ModelKit
import Testing

@testable import ModelKitGemma4

@Suite(.serialized)
struct Gemma4ProviderTests {
    @Test func promptRetainsRolesAndOpensModelTurn() {
        guard #available(iOS 27, macOS 27, *) else { return }
        #expect(
            GemmaLanguageEngine.render([
                .init(role: "system", content: "instructions"), .init(role: "user", content: "hello"),
                .init(role: "assistant", content: "answer"), .init(role: "user", content: "again"),
            ])
                == "<bos><|turn>system\ninstructions<turn|>\n<|turn>user\nhello<turn|>\n<|turn>model\nanswer<turn|>\n<|turn>user\nagain<turn|>\n<|turn>model\n"
        )
    }

    @Test func promptPreservesConsecutiveUserTurns() {
        guard #available(iOS 27, macOS 27, *) else { return }
        #expect(
            GemmaLanguageEngine.render([
                .init(role: "system", content: "instructions"),
                .init(role: "user", content: "你好"),
                .init(role: "user", content: "补充"),
                .init(role: "user", content: "原有\n换行"),
                .init(role: "assistant", content: "answer"),
                .init(role: "user", content: "again"),
                .init(role: "user", content: "more"),
            ])
                == "<bos><|turn>system\ninstructions<turn|>\n<|turn>user\n你好<turn|>\n<|turn>user\n补充<turn|>\n<|turn>user\n原有\n换行<turn|>\n<|turn>model\nanswer<turn|>\n<|turn>user\nagain<turn|>\n<|turn>user\nmore<turn|>\n<|turn>model\n"
        )
    }

    @Test func reasoningAndPartialChannelMarkersStayPrivate() {
        for text in [
            "<", "<|channel>", "<|channel>thou", "<|channel>thought\nprivate", "<|channel>thought\nprivate<channel|",
        ] {
            #expect(GemmaResponseText.visible(text).isEmpty)
        }
        #expect(GemmaResponseText.visible("<|channel>thought\nprivate<channel|>answer") == "answer")
        #expect(GemmaResponseText.visible("<|channel>thought\nprivate<channel|><|channel>final\nanswer") == "answer")
        #expect(GemmaResponseText.visible("ordinary answer") == "ordinary answer")
        #expect(GemmaResponseText.visible("answer\n<|channel>thought\nprivate<channel|> more") == "answer\n more")
        #expect(GemmaResponseText.visible("answer<|chan") == "answer")
    }

    @Test func invalidRequestsFailBeforeLoading() throws {
        guard #available(iOS 27, macOS 27, *) else { return }
        #expect(throws: CapabilityError.self) {
            try Gemma4Chat.validate(ChatRequest(messages: [.init(role: .assistant, content: "not a user")]))
        }
        #expect(throws: CapabilityError.self) {
            try Gemma4Chat.validate(
                ChatRequest(messages: [.init(role: .system, content: "rules")]))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_TEST_GEMMA4"] == "1"))
    func realInferenceCancellationAndReload() async throws {
        guard #available(iOS 27, macOS 27, *) else { return }
        let path = try #require(ProcessInfo.processInfo.environment["HARNESS_GEMMA4_ROOT"])
        let context = try ModelContext(loadGate: ModelLoadGate(maximumConcurrentLoads: 4), maximumLoadWaiters: 32)
        let model = try Gemma4Chat(context: context, artifacts: URL(fileURLWithPath: path))
        func reply() async throws -> String {
            let session = try await model.chat(
                ChatRequest(messages: [.init(role: .user, content: "只回答：你好")], maximumOutputTokens: 32, temperature: 0))
            var result = ""
            for try await event in session.events { if case .text(let delta) = event { result += delta } }
            return result
        }
        let firstReply = try await reply()
        print("GEMMA_COREAI_REPLY: \(firstReply)")
        #expect(!firstReply.isEmpty)
        #expect(!firstReply.contains("<|channel>"))
        let session = try await model.chat(
            ChatRequest(messages: [.init(role: .user, content: "请详细介绍太阳系。")], maximumOutputTokens: 128, temperature: 0))
        session.cancel()
        await #expect(throws: CancellationError.self) { for try await _ in session.events {} }
        try await context.unload()
        #expect(try await !reply().isEmpty)
        try await context.unload()
    }
}

@Test func localSystemFactsAreOmittedWithoutBecomingUserText() throws {
    guard #available(iOS 27, macOS 27, *) else { return }
    let request = try ChatRequest(messages: [
        .init(role: .system, content: "stable rules"),
        .init(role: .user, content: "earlier"), .init(role: .assistant, content: "reply"),
        .init(role: .system, content: "CURRENT STATE: facts"), .init(role: .user, content: "now"),
    ])
    try Gemma4Chat.validate(request)
    let rendered = Gemma4Chat.renderedMessages(request)
    #expect(rendered == request.messages.filter { $0.role != .system })
    #expect(request.messages[3].role == .system)
}

// Deterministic stand-in counts the entire production template; real tokenizer/device acceptance is separate.
@available(iOS 27, macOS 27, *)
private func budgetTokens(_ messages: [ChatMessage]) -> [Int] {
    Array(
        repeating: 1,
        count: GemmaLanguageEngine.render(messages.map { .init(role: $0.role.rawValue, content: $0.content) }).count)
}

@Test func localWindowResolvesPinnedBackendCapacity() {
    guard #available(iOS 27, macOS 27, *) else { return }
    #expect(GemmaContextBudget.effectiveContextLimit(modelLimit: 32768, isIOS: true) == 1024)
    #expect(GemmaContextBudget.effectiveContextLimit(modelLimit: 32768, isIOS: false) == 4096)
    #expect(GemmaContextBudget.effectiveContextLimit(modelLimit: 512, isIOS: true) == 512)
    #expect(GemmaContextBudget.effectiveContextLimit(modelLimit: 512, isIOS: false) == 512)
}

@Test(arguments: [0, 64, 1024, 4096])
func localWindowFitsIOSCapacityWithLongSystemAndHistory(_ requested: Int) async throws {
    guard #available(iOS 27, macOS 27, *) else { return }
    var messages: [ChatMessage] = [.init(role: .system, content: String(repeating: "rules ", count: 600))]
    for index in 0..<20 {
        messages += [
            .init(role: .user, content: String(repeating: "question \(index) ", count: 25)),
            .init(role: .assistant, content: String(repeating: "answer \(index) ", count: 25)),
        ]
    }
    messages.append(.init(role: .user, content: "current input"))
    let request = try ChatRequest(messages: messages, maximumOutputTokens: requested == 0 ? nil : requested)
    let prepared = try await GemmaContextBudget.prepare(request, contextLimit: 1024) { budgetTokens($0) }
    #expect(prepared.tokens == budgetTokens(prepared.messages))
    #expect(prepared.tokens.count + prepared.maximumOutputTokens <= 1024)
    #expect(prepared.maximumOutputTokens > 0)
    #expect(prepared.messages.last == messages.last)
    #expect(prepared.messages.filter { $0.role != .system }.count <= 5)
    if requested == 0 {
        #expect(prepared.messages.allSatisfy { $0.role != .system })
        #expect(prepared.maximumOutputTokens >= 256)
    } else {
        #expect(prepared.maximumOutputTokens <= requested)
    }
    #expect(request.messages == messages)
}

@Test func localWindowRejectsCurrentInputBeyondActualBackendCapacity() async throws {
    guard #available(iOS 27, macOS 27, *) else { return }
    let request = try ChatRequest(messages: [.init(role: .user, content: String(repeating: "q", count: 1024))])
    await #expect(
        throws: CapabilityError.invalidRequest(
            "Current input alone leaves no generation space in the local 1024-token window")
    ) {
        _ = try await GemmaContextBudget.prepare(request, contextLimit: 1024) { budgetTokens($0) }
    }
}

@Test(arguments: [0, 1, 4097])
func localWindowRejectsInvalidBackendCapacity(_ limit: Int) async throws {
    guard #available(iOS 27, macOS 27, *) else { return }
    let request = try ChatRequest(messages: [.init(role: .user, content: "current input")])
    await #expect(throws: CapabilityError.self) {
        _ = try await GemmaContextBudget.prepare(request, contextLimit: limit) { _ in
            Issue.record("Invalid backend capacity must reject before tokenization")
            return [1]
        }
    }
}

@Test func localWindowNormalizesEmptyHistoryAndTrailingSystemBeforeBudgeting() async throws {
    guard #available(iOS 27, macOS 27, *) else { return }
    let messages: [ChatMessage] = [
        .init(role: .system, content: "rules"), .init(role: .user, content: "failed question"),
        .init(role: .assistant, content: ""), .init(role: .user, content: " \n"),
        .init(role: .assistant, content: "\t"), .init(role: .system, content: "\n"),
        .init(role: .user, content: " current input "), .init(role: .system, content: "latest facts"),
    ]
    let request = try ChatRequest(messages: messages)
    try Gemma4Chat.validate(request)
    let prepared = try await GemmaContextBudget.prepare(request) { budgetTokens($0) }
    #expect(
        prepared.messages == [
            .init(role: .user, content: "failed question"), .init(role: .user, content: " current input "),
        ])
    #expect(prepared.tokens.count + prepared.maximumOutputTokens <= 4096)
    #expect(request.messages == messages)
}

@Test(arguments: ["", " \n\t"])
func localWindowRejectsEmptyCurrentWithoutReusingHistoricalUser(_ current: String) async throws {
    guard #available(iOS 27, macOS 27, *) else { return }
    let request = try ChatRequest(messages: [
        .init(role: .user, content: "old question"), .init(role: .assistant, content: "old answer"),
        .init(role: .user, content: current), .init(role: .system, content: "facts"),
    ])
    await #expect(throws: CapabilityError.invalidRequest("Gemma4 current user input is empty or whitespace")) {
        _ = try await GemmaContextBudget.prepare(request) { _ in
            Issue.record("Empty current input must reject before loading or tokenization")
            return [1]
        }
    }
}

@Test func localWindowRejectsTerminalAssistantEvenWhenItIsEmpty() throws {
    guard #available(iOS 27, macOS 27, *) else { return }
    let request = try ChatRequest(messages: [
        .init(role: .user, content: "old question"), .init(role: .assistant, content: ""),
        .init(role: .system, content: "facts"),
    ])
    #expect(throws: CapabilityError.invalidRequest("Gemma4 requires the last non-system message to be user")) {
        try Gemma4Chat.validate(request)
    }
}

@Test func localWindowKeepsLatestFiveMessagesAndOriginalRequest() async throws {
    guard #available(iOS 27, macOS 27, *) else { return }
    var messages: [ChatMessage] = [.init(role: .system, content: "rules")]
    for index in 0..<20 {
        messages += [
            .init(role: .user, content: "question \(index)"), .init(role: .assistant, content: "answer \(index)"),
        ]
    }
    messages.append(.init(role: .user, content: "current"))
    let request = try ChatRequest(messages: messages)
    let prepared = try await GemmaContextBudget.prepare(request) { budgetTokens($0) }
    #expect(
        Array(prepared.messages.filter { $0.role != .system })
            == Array(messages.filter { $0.role != .system }.suffix(5)))
    #expect(prepared.maximumOutputTokens >= 1024)
    #expect(prepared.tokens.count + prepared.maximumOutputTokens == 4096)
    #expect(prepared.tokens == budgetTokens(prepared.messages))
    #expect(prepared.tokens.count + prepared.maximumOutputTokens <= 4096)
    #expect(request.messages == messages)
}

@Test func localWindowOmitsEverySystemBeforeTokenizationAndPreservesUnicodeInput() async throws {
    guard #available(iOS 27, macOS 27, *) else { return }
    let source = "START " + String(repeating: "汉👨‍👩‍👧‍👦e\u{301}", count: 1300) + " TAIL"
    let current = " 当前问题👨‍👩‍👧‍👦e\u{301} "
    let request = try ChatRequest(messages: [
        .init(role: .system, content: source), .init(role: .user, content: "old"),
        .init(role: .system, content: "middle facts"), .init(role: .assistant, content: "answer"),
        .init(role: .user, content: current), .init(role: .system, content: "trailing facts"),
    ])
    let prepared = try await GemmaContextBudget.prepare(request, contextLimit: 1024) { messages in
        #expect(messages.allSatisfy { $0.role != .system })
        #expect(messages.allSatisfy { !$0.content.contains("facts") && !$0.content.contains("START") })
        return budgetTokens(messages)
    }
    #expect(prepared.messages == request.messages.filter { $0.role != .system })
    #expect(prepared.messages.last?.content == current)
    #expect(prepared.tokens.count + prepared.maximumOutputTokens <= 1024)
    #expect(request.messages.first?.content == source)
    #expect(request.messages.last?.role == .system)
}

@Test(arguments: [1, 64, 1024, 2048, 4096, Int.max])
func localWindowBudgetsExplicitGenerationIncludingTemplate(_ requested: Int) async throws {
    guard #available(iOS 27, macOS 27, *) else { return }
    let request = try ChatRequest(
        messages: [
            .init(role: .system, content: String(repeating: "s", count: 2500)),
            .init(role: .user, content: "question"), .init(role: .assistant, content: "answer"),
            .init(role: .user, content: "current"),
        ], maximumOutputTokens: requested)
    let prepared = try await GemmaContextBudget.prepare(request) { budgetTokens($0) }
    #expect(prepared.tokens.count + prepared.maximumOutputTokens <= 4096)
    #expect(prepared.maximumOutputTokens > 0 && prepared.maximumOutputTokens <= requested)
    #expect(prepared.messages.last == request.messages.last)
    if requested == 64 { #expect(prepared.messages == request.messages.filter { $0.role != .system }) }
}

@Test func localWindowPrunesOldestMessagesBeforeTouchingCurrentInput() async throws {
    guard #available(iOS 27, macOS 27, *) else { return }
    let request = try ChatRequest(messages: [
        .init(role: .system, content: "rules"),
        .init(role: .user, content: String(repeating: "u", count: 1800)),
        .init(role: .assistant, content: String(repeating: "a", count: 1800)),
        .init(role: .user, content: String(repeating: "v", count: 1800)),
        .init(role: .assistant, content: String(repeating: "b", count: 1800)),
        .init(role: .user, content: "current"),
    ])
    let prepared = try await GemmaContextBudget.prepare(request) { budgetTokens($0) }
    let retained = prepared.messages.filter { $0.role != .system }
    #expect(retained.count < 5)
    #expect(retained == Array(request.messages.filter { $0.role != .system }.suffix(retained.count)))
    #expect(prepared.messages.allSatisfy { $0.role != .system })
    #expect(prepared.tokens.count + prepared.maximumOutputTokens <= 4096)
}

@Test func localWindowPreservesLongCurrentInputByReducingOutput() async throws {
    guard #available(iOS 27, macOS 27, *) else { return }
    let current = String(repeating: "q", count: 3500)
    let request = try ChatRequest(messages: [
        .init(role: .system, content: String(repeating: "s", count: 2000)), .init(role: .user, content: current),
    ])
    let prepared = try await GemmaContextBudget.prepare(request) { budgetTokens($0) }
    #expect(prepared.messages.last?.content == current)
    #expect(prepared.maximumOutputTokens < 1024)
    #expect(prepared.tokens.count + prepared.maximumOutputTokens <= 4096)
    let oversized = try ChatRequest(messages: [.init(role: .user, content: String(repeating: "q", count: 4096))])
    await #expect(throws: CapabilityError.self) {
        _ = try await GemmaContextBudget.prepare(oversized) { budgetTokens($0) }
    }
}

@Test(.timeLimit(.minutes(1))) func localWindowCancellationJoinsTokenizationAndSuppressesPreparation() async throws {
    guard #available(iOS 27, macOS 27, *) else { return }
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let request = try ChatRequest(messages: [.init(role: .user, content: "current")])
    let task = Task {
        try await GemmaContextBudget.prepare(request) { messages in
            entered.continuation.yield(())
            for await _ in release.stream { break }
            return budgetTokens(messages)
        }
    }
    for await _ in entered.stream { break }
    task.cancel()
    release.continuation.yield(())
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    entered.continuation.finish()
    release.continuation.finish()
}

@Test func localWindowCannotHideUnsupportedImagesOrToolsInPrunedHistory() async throws {
    guard #available(iOS 27, macOS 27, *) else { return }
    let image = try ChatImage(id: "fixture", data: Data([1]))
    var messages: [ChatMessage] = [.init(role: .user, content: "old image", images: [image])]
    messages += (0..<6).map { .init(role: .user, content: "later \($0)") }
    let imageRequest = try ChatRequest(messages: messages)
    await #expect(throws: CapabilityError.self) {
        _ = try await GemmaContextBudget.prepare(imageRequest) { _ in
            Issue.record("Unsupported images must reject before tokenization")
            return [1]
        }
    }
    let toolRequest = try ChatRequest(messages: [
        .init(role: .assistant, content: "call", toolCalls: [.init(id: "call1", name: "fixture", argumentsJSON: "{}")]),
        .init(role: .tool, content: "result", toolCallID: "call1"),
        .init(role: .user, content: "current"),
    ])
    await #expect(throws: CapabilityError.self) {
        _ = try await GemmaContextBudget.prepare(toolRequest) { _ in
            Issue.record("Unsupported native tool history must reject before tokenization")
            return [1]
        }
    }
}

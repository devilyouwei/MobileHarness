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
                ChatRequest(messages: [.init(role: .user, content: "hi"), .init(role: .system, content: "late")]))
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

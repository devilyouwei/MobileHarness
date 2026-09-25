import Foundation
@_spi(ModelManagement) import ModelKit
import Testing

@testable import ModelKitMLXLanguage
@testable import ModelKitQwen35

@Suite(.serialized)
struct Qwen35ProviderTests {
    var directory: String {
        ProcessInfo.processInfo.environment["HARNESS_QWEN35_SIZE"] == "4B" ? "Qwen35-4B" : "Qwen35"
    }

    @Test func qwenRejectsInvalidRequestsBeforeLoading() throws {
        #expect(throws: CapabilityError.self) {
            try Qwen35Chat.validate(ChatRequest(messages: [.init(role: .assistant, content: "not a user")]))
        }
        #expect(throws: CapabilityError.self) {
            try Qwen35Chat.validate(
                ChatRequest(messages: [.init(role: .user, content: "hi"), .init(role: .system, content: "late")]))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_TEST_QWEN35"] == "1"))
    func qwenRealSmoke() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(
                "MobileHarness/Resources/Models")
        // SwiftPM's standalone Swift Testing runner does not register the XCTest bundle in allBundles.
        // Use MLX's relative metallib lookup inside its compiled resource directory.
        let resources = try #require(Bundle.module.resourceURL)
        let metalBundle = resources.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("mlx-swift_Cmlx.bundle")
        let previousDirectory = FileManager.default.currentDirectoryPath
        let metalResources = try #require(Bundle(url: metalBundle)?.resourceURL)
        try #require(FileManager.default.changeCurrentDirectoryPath(metalResources.path))
        defer { _ = FileManager.default.changeCurrentDirectoryPath(previousDirectory) }
        let modelContext = ModelContext()
        let model = try Qwen35Chat(
            context: modelContext,
            artifacts: root.appendingPathComponent(directory))
        let session = try await model.chat(
            ChatRequest(
                messages: [.init(role: .user, content: "你好，请用一句话介绍你自己。")], maximumOutputTokens: 64, temperature: 0))
        var text = ""
        for try await event in session.events { if case .text(let delta) = event { text += delta } }
        print("QWEN_SMOKE: \(text)")
        #expect(!text.isEmpty)
        #expect(!text.contains("<think>"))
        let cancelled = try await model.chat(
            ChatRequest(messages: [.init(role: .user, content: "请详细介绍太阳系。")], maximumOutputTokens: 128, temperature: 0))
        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            for try await _ in cancelled.events {}
        }
        try await modelContext.unload()
        let reloaded = try await model.chat(
            ChatRequest(messages: [.init(role: .user, content: "只回答：你好")], maximumOutputTokens: 16, temperature: 0))
        var afterReload = ""
        for try await event in reloaded.events { if case .text(let delta) = event { afterReload += delta } }
        #expect(!afterReload.isEmpty)
        try await modelContext.unload()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_TEST_QWEN35"] == "1"))
    func qwenTokenizerMatchesPython() async throws {
        struct Fixture: Decodable {
            let messages: [[String: String]]
            let tokens: [Int]
        }
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(
                "MobileHarness/Resources/Models/" + directory)
        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        let fixtures = try JSONDecoder().decode(
            [Fixture].self,
            from: Data(
                contentsOf: try #require(
                    Bundle.module.url(
                        forResource: "python-tokenization", withExtension: "json", subdirectory: "Fixtures")))
        )
        for fixture in fixtures {
            let tokens = try tokenizer.applyChatTemplate(
                messages: fixture.messages.map { $0.mapValues { $0 as any Sendable } }, tools: nil,
                additionalContext: ["enable_thinking": false])
            #expect(tokens == fixture.tokens)
        }
    }

}

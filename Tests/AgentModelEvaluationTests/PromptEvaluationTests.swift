import AgentCore
import Agents
import Foundation
@_spi(ModelManagement) import ModelKit
import ModelKitQwen35
import Testing

@Suite(.serialized)
struct AgentModelEvaluationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_EVAL_QWEN35"] == "1"))
    func evaluateQwenPromptVariants() async throws {
        struct Fixture: Decodable {
            let scenario: String
            let messages: [[String: String]]
        }
        let resources = try #require(Bundle.module.resourceURL)
        let metalBundle = resources.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("mlx-swift_Cmlx.bundle")
        let previousDirectory = FileManager.default.currentDirectoryPath
        let metalResources = try #require(Bundle(url: metalBundle)?.resourceURL)
        try #require(FileManager.default.changeCurrentDirectoryPath(metalResources.path))
        defer { _ = FileManager.default.changeCurrentDirectoryPath(previousDirectory) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(
                "MobileHarness/Resources/Models")
        let directory = ProcessInfo.processInfo.environment["HARNESS_QWEN35_SIZE"] == "4B" ? "Qwen35-4B" : "Qwen35"
        let modelContext = ModelContext()
        let model = try Qwen35Chat(
            context: modelContext,
            artifacts: root.appendingPathComponent(directory))
        let fixtures = try JSONDecoder().decode(
            [Fixture].self,
            from: Data(
                contentsOf: try #require(
                    Bundle.module.url(
                        forResource: "cases", withExtension: "json", subdirectory: "Scenarios")))
        )
        let configuration = try AgentConfigurations.load(named: "Assistant")
        let clarified = """
            你是手机上的语音助手。使用用户的语言简短回答，不输出思考过程。
            普通聊天直接输出自然文本。不要为了回答而包裹任何 XML 标签。
            只有需要动作时，才插入已注册动作的自闭标签。参数名称和值必须符合下面的说明。不要发明标签。
            channel 是可选作用域，仅当用户明确要求时才使用；普通回答和表情调用不需要 channel。
            channel 标签必须成对闭合，不要重复开启同一个 channel。先关闭作用域，再输出用户要求放在作用域外的文本。
            例如：<channel.main><express emotion="smile"/><express emotion="surprised"/></channel.main>你好。
            自然文本中的 < 和 & 使用 &lt; 和 &amp;。
            """ + "\n"
            + CapabilityContextBuilder.build(configuration.capabilities).split(separator: "\n").dropFirst(3).joined(
                separator: "\n")
        var results: [[String: Any]] = []
        for (variant, system) in [
            ("minimal", "你是中文语音助手，直接简短回答用户问题。"), ("clarified", clarified),
            ("original", fixtures[0].messages[0]["content"] ?? ""),
        ] {
            for fixture in fixtures {
                let messages =
                    [ChatMessage(role: .system, content: system)]
                    + fixture.messages.dropFirst().map {
                        ChatMessage(role: $0["role"] == "assistant" ? .assistant : .user, content: $0["content"] ?? "")
                    }
                let started = Date()
                let session = try await model.chat(
                    ChatRequest(messages: messages, maximumOutputTokens: 256, temperature: 0))
                var answer = ""
                for try await event in session.events { if case .text(let delta) = event { answer += delta } }
                var error = ""
                do {
                    var generator = try AgentGenerator(
                        capabilities: configuration.capabilities, textActions: configuration.textActions)
                    _ = try generator.append(answer) + generator.finish()
                } catch let failure { error = String(describing: failure) }
                results.append([
                    "variant": variant, "scenario": fixture.scenario, "answer": answer, "protocolError": error,
                    "seconds": Date().timeIntervalSince(started), "system": system,
                ])
                try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(
                    to: URL(fileURLWithPath: "/tmp/qwen35-prompt-variants.json"), options: .atomic)
                print("QWEN_VARIANT \(variant)/\(fixture.scenario) \(error) \(answer)")
            }
        }
        try await modelContext.unload()
    }

}

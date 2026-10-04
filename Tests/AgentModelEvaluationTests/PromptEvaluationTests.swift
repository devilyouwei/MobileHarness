import AgentCore
import Agents
import Foundation
@_spi(ModelManagement) import ModelKit
import ModelKitGemma4
import Testing

@Suite(.serialized)
struct AgentModelEvaluationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_EVAL_GEMMA4"] == "1"))
    func evaluateGemmaPromptVariants() async throws {
        guard #available(iOS 27, macOS 27, *) else { return }
        struct Fixture: Decodable {
            let scenario: String
            let messages: [[String: String]]
        }
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HARNESS_GEMMA4_ROOT"]))
        let modelContext = ModelContext()
        let model = try Gemma4Chat(
            context: modelContext,
            artifacts: root)
        let fixtures = try JSONDecoder().decode(
            [Fixture].self,
            from: Data(
                contentsOf: try #require(
                    Bundle.module.url(
                        forResource: "cases", withExtension: "json", subdirectory: "Scenarios")))
        )
        let configuration = try AgentConfigurations.load(named: "Assistant")
        let clarified = try AssistantAgent.systemPrompt(
            capabilities: AssistantAgent.runtimeCapabilities(configuration.capabilities))
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
                    ChatRequest(messages: messages, temperature: 0))
                var answer = ""
                for try await event in session.events { if case .text(let delta) = event { answer += delta } }
                var error = ""
                do {
                    var generator = try AgentGenerator(
                        capabilities: AssistantAgent.runtimeCapabilities(configuration.capabilities),
                        textMapping: AssistantAgent.mapText)
                    _ = try generator.append(answer) + generator.finish()
                } catch let failure { error = String(describing: failure) }
                results.append([
                    "variant": variant, "scenario": fixture.scenario, "answer": answer, "protocolError": error,
                    "seconds": Date().timeIntervalSince(started), "system": system,
                ])
                try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(
                    to: URL(fileURLWithPath: "/tmp/gemma4-prompt-variants.json"), options: .atomic)
                print("GEMMA_VARIANT \(variant)/\(fixture.scenario) \(error) \(answer)")
            }
        }
        try await modelContext.unload()
    }

}

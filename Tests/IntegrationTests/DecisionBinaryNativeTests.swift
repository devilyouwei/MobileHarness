import AgentCore
import Foundation
import ModelKit
import ModelKitDefaults
import Testing

@testable import Agents

/// Actual App noul request, both native Swift adapters; explicit opt-in, no downloads.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MH_BINARY_NATIVE_REPORT"] != nil))
@MainActor func decisionBinaryNativeComparison() async throws {
    guard #available(macOS 27, iOS 27, *) else { throw CapabilityError.unavailable("CoreAI requires OS 27") }
    let env = ProcessInfo.processInfo.environment
    let root = ModelContainer(resources: URL(fileURLWithPath: try #require(env["MH_BINARY_NATIVE_MODELS"])))
    try await root.start()
    try await root.setForeground(true)
    struct Row: Codable {
        let model: String
        let language: String
        let text: String
        let instructions: String
        let expected: Bool
        let value: Bool
        let score: Double?
        let milliseconds: Double
        let choiceValue: Bool
        let choiceScore: Double?
    }
    let cases: [(String, String, Bool)] = [
        ("en", "Stop talking now.", true), ("en", "Pause for a moment.", true),
        ("en", "No, stop that and explain Shanghai instead.", true), ("en", "Cancel what you're doing.", true),
        ("en", "Hello.", false), ("en", "Open the camera.", false),
        ("en", "Don't stop, keep going.", false), ("en", "After that, explain Shanghai.", false),
        ("en", "What does 'stop talking' mean?", false), ("en", "Yes.", false),
        ("en", "Also include the population.", false), ("en", "He told me to stop.", false),
        ("en", "停一下，先别说了。", true), ("en", "讲完以后再说上海。", false),
        ("zh-Hans", "停一下，先别说了。", true), ("zh-Hans", "暂停。", true),
        ("zh-Hans", "别讲北京了，现在改讲上海。", true), ("zh-Hans", "取消当前任务。", true),
        ("zh-Hans", "你好。", false), ("zh-Hans", "打开相机。", false),
        ("zh-Hans", "不用停，继续说。", false), ("zh-Hans", "讲完以后再说上海。", false),
        ("zh-Hans", "解释一下“别说了”的意思。", false), ("zh-Hans", "是的。", false),
        ("zh-Hans", "再加上人口信息。", false), ("zh-Hans", "他昨天让我停下来。", false),
        ("zh-Hans", "Stop talking now.", true), ("zh-Hans", "Don't stop, keep going.", false),
    ]
    var rows: [Row] = []
    do {
        for id in ["d3-edge", "vela3-fast"] {
            let model = try #require(root.language.decisionModel(id))
            try await model.warmup()
            let warm = try NoulRequest(text: "Hello.", instructions: "Does this request an immediate interruption?")
            for _ in 0..<3 {
                let session = try await model.noul(warm)
                try await session.withCleanup { for try await _ in session.events {} }
            }
            for (index, item) in cases.enumerated() {
                let (language, text, expected) = item
                let request = try AgentPrompts.$language.withValue(language) {
                    try InputDecisionSnapshot(
                        input: .init(id: "native-\(index)", sessionID: "benchmark", payload: .text(text)),
                        text: text,
                        currentTurn: .init(
                            user: language == "en" ? "Tell me about Beijing." : "介绍一下北京。",
                            assistant: language == "en" ? "Beijing is the capital of China. It has" : "北京是中国的首都，它有")
                    ).request()
                }
                let start = ContinuousClock.now
                let session = try await model.noul(request)
                let result = try await session.withCleanup {
                    var values: [NoulResult] = []
                    for try await value in session.events { values.append(value) }
                    #expect(values.count == 1)
                    return try #require(values.first)
                }
                let elapsed = start.duration(to: .now).components
                let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
                let candidates = id == "vela3-fast" ? ["no", "yes"] : ["No / false", "Yes / true"]
                let choice = try DecisionRequest(
                    text: request.text, candidates: candidates, instructions: request.instructions)
                let choiceSession = try await model.choice(choice)
                let readout = try await choiceSession.withCleanup {
                    var selected: DecisionResult?
                    for try await value in choiceSession.events { selected = value }
                    return try #require(selected)
                }
                guard case .selected(let label, let score) = readout.decision else {
                    throw CapabilityError.invalidRequest("Native choice abstained")
                }
                let choiceValue = label == candidates[1]
                let choiceScore = score.map { choiceValue ? $0 : 1 - $0 }
                #expect(choiceValue == result.value)
                #expect(abs((choiceScore ?? -1) - (result.score ?? -2)) < 0.00001)
                rows.append(
                    .init(
                        model: id, language: language, text: request.text, instructions: request.instructions,
                        expected: expected, value: result.value, score: result.score, milliseconds: milliseconds,
                        choiceValue: choiceValue, choiceScore: choiceScore))
            }
            try await model.unload()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: try #require(env["MH_BINARY_NATIVE_REPORT"])))
        try await root.stop()
    } catch {
        try await root.stop()
        throw error
    }
}

import Foundation
@_spi(ModelManagement) import ModelKit
import ModelKitGemma4
import Testing

private struct DecisionFixture: Decodable {
    struct Item: Decodable, Sendable {
        let condition: String
        let id: String
        let user: String
        let expected: String

        var instruction: String {
            condition == "current-zh-Hans"
                ? "只输出一个数字：1、2 或 3。"
                : "Output exactly one digit: 1, 2, or 3."
        }
    }

    let cases: [Item]
}

private struct DecisionSample: Encodable {
    let condition: String
    let id: String
    let expected: String
    let prediction: String?
    let output: String
    let finish: String?
    let error: String?
    let elapsedMS: Double
    let inputTokens: Int?
    let outputTokens: Int?
}

private struct DecisionReport: Encodable {
    let model = "Gemma 4 E2B QAT CoreAI via Gemma4Chat"
    let fixture = "docs/measurements/decision-apple-system-m5-2026-11-15.json"
    let profile = "Tests/Gemma4Tests/gemma4-e2b-macos.download.json"
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    let maximumOutputTokens = 16
    let temperature = 0
    var runs: [String: Run] = [:]

    struct Run: Encodable {
        var warmups: [DecisionSample] = []
        var rows: [DecisionSample] = []
    }
}

@available(macOS 27, iOS 27, *)
private func measureDecision(
    _ item: DecisionFixture.Item, model: Gemma4Chat, inlineInstruction: Bool, maximumOutputTokens: Int
) async -> DecisionSample {
    let messages: [ChatMessage] =
        inlineInstruction
        ? [.init(role: .user, content: item.instruction + "\n\n" + item.user)]
        : [.init(role: .system, content: item.instruction), .init(role: .user, content: item.user)]
    let started = ContinuousClock.now
    var output = ""
    var finish: ChatEvent.FinishReason?
    var usage: ChatTokenUsage?
    var errorText: String?
    do {
        let request = try ChatRequest(messages: messages, maximumOutputTokens: maximumOutputTokens, temperature: 0)
        let session = try await model.chat(request)
        do {
            // The timer cancels native work, and session cleanup joins it before the next sample.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Task.sleep(for: .seconds(60))
                    session.cancel()
                    throw CapabilityError.invalidRequest("Gemma Decision generation timeout")
                }
                defer { group.cancelAll() }
                for try await event in session.events {
                    switch event {
                    case .text(let text): output += text
                    case .usage(let value): usage = value
                    case .finished(let reason): finish = reason
                    case .toolCall: throw CapabilityError.invalidRequest("Unexpected tool response in text Decision")
                    }
                }
                guard finish != nil else { throw CapabilityError.invalidRequest("Missing completion event") }
            }
        } catch {
            session.cancel()
            await session.waitForCompletion()
            throw error
        }
        session.cancel()
        await session.waitForCompletion()
    } catch { errorText = String(describing: error) }
    let duration = started.duration(to: .now).components
    let digits = ["1": "interrupt", "2": "discard", "3": "enqueue"]
    return DecisionSample(
        condition: item.condition, id: item.id, expected: item.expected,
        prediction: errorText == nil && finish == .stop
            ? digits[output.trimmingCharacters(in: .whitespacesAndNewlines)] : nil,
        output: output, finish: finish.map { String(describing: $0) }, error: errorText,
        elapsedMS: Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15,
        inputTokens: usage?.input, outputTokens: usage?.generated)
}

@available(macOS 27, iOS 27, *)
@Test(.enabled(if: ProcessInfo.processInfo.environment["GEMMA_DECISION_REPORT"] != nil))
func gemmaDecisionModelEvaluation() async throws {
    let environment = ProcessInfo.processInfo.environment
    let output = URL(fileURLWithPath: try #require(environment["GEMMA_DECISION_REPORT"]))
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let artifacts =
        environment["HARNESS_GEMMA4_ROOT"].map { URL(fileURLWithPath: $0) }
        ?? repository.appendingPathComponent("Tests/Gemma4Tests/.local/Gemma4")
    var report = DecisionReport()
    let fixtures = try JSONDecoder().decode(
        DecisionFixture.self, from: Data(contentsOf: repository.appendingPathComponent(report.fixture)))
    let supportedLanguages = ["current-en", "current-zh-Hans"]
    let languages = environment["GEMMA_DECISION_LANGUAGE"].map { [$0] } ?? supportedLanguages
    let supportedModes = ["production", "inline-instruction"]
    let modes = environment["GEMMA_DECISION_MODE"].map { [$0] } ?? supportedModes
    let offset = try #require(Int(environment["GEMMA_DECISION_OFFSET"] ?? "0"))
    try #require(languages.allSatisfy { supportedLanguages.contains($0) })
    try #require(modes.allSatisfy { supportedModes.contains($0) })
    try #require((0..<27).contains(offset) && (offset == 0 || languages.count == 1))
    let byLanguage = Dictionary(grouping: fixtures.cases, by: \.condition)
    try #require(languages.allSatisfy { byLanguage[$0]?.count == 27 })
    let modelContext = try ModelContext(loadGate: ModelLoadGate(maximumConcurrentLoads: 1), maximumLoadWaiters: 1)
    let model = try Gemma4Chat(context: modelContext, artifacts: artifacts)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    func save(first: Bool = false) throws {
        try (encoder.encode(report) + Data("\n".utf8)).write(to: output, options: first ? .withoutOverwriting : .atomic)
    }
    do {
        try #require(await model.availability == .available)
        try save(first: true)
        let maxTokens = report.maximumOutputTokens
        for mode in modes {
            let inline = mode == "inline-instruction"
            var run = DecisionReport.Run()
            for language in languages {
                let items = try #require(byLanguage[language])
                let first = try #require(items.first)
                for _ in 0..<3 {
                    let warmup = await measureDecision(
                        first, model: model, inlineInstruction: inline,
                        maximumOutputTokens: maxTokens)
                    run.warmups.append(warmup)
                    report.runs[mode] = run
                    try save()
                    try #require(warmup.error == nil)
                }
                for item in items.dropFirst(offset) {
                    try Task.checkCancellation()
                    run.rows.append(
                        await measureDecision(
                            item, model: model, inlineInstruction: inline,
                            maximumOutputTokens: maxTokens))
                    report.runs[mode] = run
                    try save()
                }
            }
        }
    } catch {
        await modelContext.shutdown()
        throw error
    }
    await modelContext.shutdown()
    #expect(report.runs.count == modes.count)
    #expect(report.runs.values.allSatisfy { $0.rows.count == languages.count * (27 - offset) })
    #expect(report.runs.values.flatMap(\.rows).allSatisfy { $0.error == nil })
}

import AgentCore
import Foundation
import ModelKit
import ModelKitDefaults
import ModelKitOpenAI
import Testing

@testable import Agents

private struct ProtocolBenchmarkReport: Encodable {
    let model: String
    let language: String
    let mode: HistoricalAssistantDecisionProtocol.Mode
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    var warmup: [Row] = []
    var rows: [Row] = []

    struct Row: Encodable {
        let id: String
        let expected: HistoricalInputDisposition
        let prediction: HistoricalInputDisposition?
        let error: String?
        let elapsedMS: Double
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MH_DECISION_REPORT"] != nil))
@MainActor
func decisionProtocolBenchmark() async throws {
    let env = ProcessInfo.processInfo.environment
    let modelID = try #require(env["MH_DECISION_MODEL"])
    let language = try #require(env["MH_DECISION_LANGUAGE"])
    let mode = try #require(env["MH_DECISION_MODE"].flatMap(HistoricalAssistantDecisionProtocol.Mode.init(rawValue:)))
    let output = URL(fileURLWithPath: try #require(env["MH_DECISION_REPORT"]))
    try #require(["en", "zh-Hans"].contains(language))
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let input = repository.appendingPathComponent("docs/measurements/decision-language-scenarios-2026-11-14.json")
    let cases = try JSONDecoder().decode([DecisionLanguageScenario].self, from: Data(contentsOf: input))
    try #require(cases.count == 27 && Set(cases.map(\.id)).count == cases.count)
    let offset = try #require(Int(env["MH_DECISION_OFFSET"] ?? "0"))
    let count = try #require(Int(env["MH_DECISION_LIMIT"] ?? "27"))
    try #require((0..<cases.count).contains(offset) && (1...cases.count).contains(count))

    let cloud = ["qwen3.7-flash", "qwen3.8-flash"].contains(modelID)
    let resourceDirectory: String
    switch (modelID, mode) {
    case ("d3-edge", .jev), ("d3-lite", .jev):
        resourceDirectory = "Tests/DecisionBenchmarks/.local/models"
    case ("gemma4-e2b", .text), ("gemma4-e2b", .tool):
        resourceDirectory = "Tests/Gemma4Tests/.local"
    case ("apple-system", .text), ("qwen3.7-flash", .tool), ("qwen3.7-flash", .text),
        ("qwen3.8-flash", .tool), ("qwen3.8-flash", .text):
        resourceDirectory = "Tests"
    default:
        throw CapabilityError.invalidRequest("Unsupported Decision benchmark model and protocol")
    }
    let modelRoot = ModelContainer(resources: repository.appendingPathComponent(resourceDirectory))
    try await modelRoot.start()
    do {
        try await modelRoot.setForeground(true)
        let route: HistoricalAssistantDecisionProtocol
        if mode == .jev {
            let model = try #require(modelRoot.language.decisionModel(modelID))
            try await model.warmup()
            route = .jev(model)
        } else {
            let model: ChatModel
            if cloud {
                // Validate presence without putting credential-bearing expressions in test output.
                guard let apiKey = env["MH_DECISION_CLOUD_KEY"], !apiKey.isEmpty,
                    let configuredURL = env["MH_DECISION_CLOUD_URL"],
                    let url = try? OpenAIChatConfiguration.endpoint(configuredURL),
                    url.scheme == "https"
                else { throw CapabilityError.invalidRequest("Missing HTTPS Decision benchmark provider configuration") }
                let configuration = try OpenAIChatConfiguration(
                    baseURL: url, apiKey: apiKey, model: modelID, timeout: 12, thinking: .minimum)
                model = try await modelRoot.language.chatModel(configuration: configuration)
            } else {
                model = try await modelRoot.language.localChatModel(modelID)
            }
            try #require(await model.capability.availability == .available)
            if mode == .tool { try #require(await model.capability.supportsToolCalls) }
            route = mode == .tool ? .tool(model.capability) : .text(model.capability)
        }

        var report = ProtocolBenchmarkReport(model: modelID, language: language, mode: mode)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        func save(first: Bool = false) throws {
            try (encoder.encode(report) + Data("\n".utf8)).write(
                to: output, options: first ? .withoutOverwriting : .atomic)
        }
        try save(first: true)
        func measure(_ sample: DecisionLanguageScenario) async throws -> ProtocolBenchmarkReport.Row {
            let transcript = language == "en" ? sample.english : sample.chinese
            let input = transcript.snapshot(id: sample.id, scenario: sample)
            let start = ContinuousClock.now
            var prediction: HistoricalInputDisposition?
            var failure: String?
            do {
                prediction = try await AgentPrompts.$language.withValue(language) {
                    try await route.classify(input.prompt())
                }
            } catch let error as OpenAIChatError {
                let fact = error.chatFailure
                failure = "provider:\(fact.reason.rawValue):\(fact.statusCode ?? 0):\(fact.providerCode ?? "")"
            } catch let error as CapabilityError {
                failure = error.localizedDescription
            } catch {
                failure = String(reflecting: type(of: error))
            }
            let time = start.duration(to: .now).components
            return .init(
                id: sample.id, expected: sample.expected, prediction: prediction, error: failure,
                elapsedMS: Double(time.seconds) * 1000 + Double(time.attoseconds) / 1e15)
        }
        let selected = cases.dropFirst(offset).prefix(count)
        let first = try #require(selected.first)
        for _ in 0..<(cloud ? 1 : 3) {
            report.warmup.append(try await measure(first))
            try save()
        }
        for sample in selected {
            try Task.checkCancellation()
            report.rows.append(try await measure(sample))
            try save()
        }
        try await modelRoot.stop()
        #expect(report.rows.count == selected.count)
    } catch {
        try await modelRoot.stop()
        throw error
    }
}

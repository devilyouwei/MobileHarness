import AgentCore
import Foundation
import ModelKit
import ModelKitDefaults
import ModelKitRuntime
import Testing

@testable import Agents

private struct DecisionLanguageScenario: Codable {
    let id: String
    let expected: InputDisposition
    let running: Bool
    let playing: Bool
    let english: Transcript
    let chinese: Transcript

    struct Transcript: Codable {
        let user: String
        let assistant: String
        let question: String?
        let latest: String

        func snapshot(id: String, scenario: DecisionLanguageScenario) -> InputDecisionSnapshot {
            .init(
                input: .init(
                    id: id, sessionID: "decision-language", payload: .observation(.transcript(latest, final: true))),
                text: latest, running: scenario.running, playing: scenario.playing,
                history: .init(user: user, assistant: assistant), question: question)
        }
    }
}

private struct DecisionLanguageReport: Encodable {
    struct Row: Encodable {
        let caseID: String
        let inputLanguage: String
        let prompt: String
        let expected: InputDisposition
        let model: InputDisposition?
        let adopted: InputDisposition
        let route: String
        let reason: String?
        let localFallback: String?
        let measurement: MeasuredD3.Sample?
    }
    let host: String
    let artifactManifest: [String: String]
    let warmupsPerPrompt: Int
    let rows: [Row]
    let contextProbes: [Row]
}

/// Records the real native call and carries its result unchanged to the production classifier.
private actor MeasuredD3: ModelDecisionProviding {
    struct Sample: Encodable {
        let state: String
        let candidates: [String]
        let instructions: String
        let nativeMS: Double
        let score: Double?
        let error: String?
    }

    private let model: any ModelDecisionProviding
    private var sample: Sample?
    nonisolated var availability: CapabilityAvailability { .available }

    init(model: any ModelDecisionProviding) { self.model = model }
    func load() async throws { try await model.load() }
    func warmup() async throws { try await model.warmup() }
    func warmup(reportLoading: @escaping @Sendable (Bool) async -> Void) async throws {
        try await model.warmup(reportLoading: reportLoading)
    }
    func unload() async throws { try await model.unload() }
    func status() async throws -> ModelState { try await model.status() }
    func takeSample() -> Sample? {
        defer { sample = nil }
        return sample
    }
    func decide(_ request: DecisionRequest) async throws -> InferenceSession<DecisionResult> {
        let start = ContinuousClock.now
        func makeSample(score: Double? = nil, error: String? = nil) -> Sample {
            let duration = start.duration(to: .now).components
            return .init(
                state: request.text, candidates: request.candidates, instructions: request.instructions,
                nativeMS: Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15,
                score: score, error: error)
        }
        do {
            let session = try await model.decide(request)
            let result = try await session.withCleanup {
                var values: [DecisionResult] = []
                for try await value in session.events { values.append(value) }
                guard values.count == 1, let result = values.first else {
                    throw CapabilityError.invalidRequest("Expected one D3 result")
                }
                return result
            }
            guard case .selected(_, let score) = result.decision else {
                throw CapabilityError.invalidRequest("Expected a selected D3 candidate")
            }
            sample = makeSample(score: score)
            let pair = InferenceSession<DecisionResult>.make(
                context: request.context, limits: try StreamLimits(capacity: 1), estimatedBytes: { _ in 1024 })
            try pair.emitter.yield(result)
            pair.emitter.finish()
            return pair.session
        } catch {
            sample = makeSample(error: String(describing: error))
            throw error
        }
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["D3_LANGUAGE_REPORT"] != nil))
@MainActor func d3DecisionLanguageEvaluation() async throws {
    guard #available(macOS 27, *) else { throw CapabilityError.unavailable("D3 evaluation requires macOS 27") }
    let env = ProcessInfo.processInfo.environment
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let fixtures = repo.appendingPathComponent("docs/measurements/decision-language-scenarios-2026-11-14.json")
    let scenarios = try JSONDecoder().decode([DecisionLanguageScenario].self, from: Data(contentsOf: fixtures))
    try #require(scenarios.count > 1 && Set(scenarios.map(\.id)).count == scenarios.count)
    let first = scenarios[0]

    let resources = URL(fileURLWithPath: try #require(env["D3_TEST_RESOURCES"]))
    let manifestURL = resources.appendingPathComponent("D3Edge/manifest.json")
    let metadata = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    let root = ModelContainer(resources: resources)
    try await root.start()
    do {
        try await root.setForeground(true)
        let model = root.language.decision
        try await model.warmup()
        var rows: [DecisionLanguageReport.Row] = []
        var probes: [DecisionLanguageReport.Row] = []
        for prompt in ["en", "zh-Hans"] {
            let measured = MeasuredD3(model: model)
            let classifier = AssistantInputDecision(
                local: measured, configuration: { (true, nil) }, language: { prompt })
            for _ in 0..<3 {
                let warmup = await classifier.classify(first.english.snapshot(id: "warmup", scenario: first))
                try #require(warmup.route == .local, Comment(rawValue: warmup.localFallback ?? "Native warm-up failed"))
                _ = await measured.takeSample()
            }
            func evaluate(
                _ input: DecisionLanguageScenario.Transcript, scenario: DecisionLanguageScenario, inputLanguage: String
            ) async -> DecisionLanguageReport.Row {
                let snapshot = input.snapshot(id: scenario.id + "-" + inputLanguage, scenario: scenario)
                let value = await classifier.classify(snapshot)
                return .init(
                    caseID: scenario.id, inputLanguage: inputLanguage, prompt: prompt, expected: scenario.expected,
                    model: value.modelResult, adopted: value.adopted, route: value.route.rawValue, reason: value.reason,
                    localFallback: value.localFallback, measurement: await measured.takeSample())
            }
            for scenario in scenarios {
                rows.append(await evaluate(scenario.english, scenario: scenario, inputLanguage: "en"))
                rows.append(await evaluate(scenario.chinese, scenario: scenario, inputLanguage: "zh-Hans"))
            }
            for (language, sentence) in [
                ("en", "Keep the original version of this message. "), ("zh-Hans", "保存原来的文件，保留完整版本和插图，再复制给我。"),
            ] {
                for repeats in [2, 5, 25] {
                    let context = String(String(repeating: sentence, count: 10).prefix(80))
                    let transcript = DecisionLanguageScenario.Transcript(
                        user: context, assistant: context, question: context,
                        latest: String(repeating: sentence, count: repeats).trimmingCharacters(in: .whitespaces))
                    let scenario = DecisionLanguageScenario(
                        id: "capacity-\(repeats)", expected: .enqueue, running: false, playing: false,
                        english: transcript, chinese: transcript)
                    probes.append(await evaluate(transcript, scenario: scenario, inputLanguage: language))
                }
            }
            await classifier.stop()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let report = DecisionLanguageReport(
            host: ProcessInfo.processInfo.operatingSystemVersionString,
            artifactManifest: metadata.compactMapValues { $0 as? String }, warmupsPerPrompt: 3, rows: rows,
            contextProbes: probes)
        let output = URL(fileURLWithPath: try #require(env["D3_LANGUAGE_REPORT"]))
        try (encoder.encode(report) + Data("\n".utf8)).write(to: output, options: .withoutOverwriting)
        try await root.stop()
    } catch {
        try await root.stop()
        throw error
    }
}

import CryptoKit
import Foundation
import ModelKit
import ModelKitDefaults
import ModelKitRuntime
import Testing

private struct ContinuationReadoutInput: Decodable {
    struct Row: Decodable {
        struct Scenario: Decodable {
            let id: String
            let language: String
            let group: String
            let expected: String
        }
        struct Request: Decodable {
            let text: String
            let instructions: String
            let candidates: [String]
        }
        let scenario: Scenario
        let native: Request
        let inputTokens: Int
    }
    let sourceHashes: [String: String]
    let rows: [Row]
}

private struct ContinuationReadoutReport: Encodable {
    struct Row: Encodable {
        let id: String
        let language: String
        let group: String
        let expected: String
        let inputTokens: Int
        let prediction: String?
        let score: Double?
        let milliseconds: Double
        let error: String?
    }
    let mode = "native-readout-without-Assistant-deadline-or-adoption"
    let model = "d3-edge"
    let inputSHA256: String
    let runnerSHA256: String
    var warmup: [Row] = []
    var rows: [Row] = []
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["D3_CONTINUATION_READOUT_REPORT"] != nil))
@MainActor func d3DecisionContinuationReadout() async throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let input = repo.appendingPathComponent("docs/measurements/decision-continue-listening-d3-edge-2026-11-16.json")
    let data = try Data(contentsOf: input)
    let fixture = try JSONDecoder().decode(ContinuationReadoutInput.self, from: data)
    func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func verifySources() throws {
        for (path, expected) in fixture.sourceHashes {
            try #require(hash(Data(contentsOf: repo.appendingPathComponent(path))) == expected)
        }
    }
    try verifySources()
    var report = ContinuationReadoutReport(
        inputSHA256: hash(data), runnerSHA256: hash(try Data(contentsOf: URL(fileURLWithPath: #filePath))))
    let output = URL(
        fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D3_CONTINUATION_READOUT_REPORT"]))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    func save(first: Bool = false) throws {
        try (encoder.encode(report) + Data("\n".utf8)).write(to: output, options: first ? .withoutOverwriting : .atomic)
    }
    try save(first: true)
    let root = ModelContainer(resources: repo.appendingPathComponent("Tests/DecisionBenchmarks/.local/models"))
    try await root.start()
    do {
        try await root.setForeground(true)
        let model = try #require(root.language.decisionModel("d3-edge"))
        try await model.warmup()
        func measure(_ item: ContinuationReadoutInput.Row) async -> ContinuationReadoutReport.Row {
            let start = ContinuousClock.now
            var prediction: String?
            var score: Double?
            var failure: String?
            do {
                let request = try DecisionRequest(
                    text: item.native.text, candidates: item.native.candidates, instructions: item.native.instructions)
                let session = try await model.choice(request)
                let selection = try await session.withCleanup {
                    var prediction: String?
                    var score: Double?
                    for try await result in session.events {
                        guard prediction == nil, case .selected(let label, let value) = result.decision,
                            let index = request.candidates.firstIndex(of: label), index < 4
                        else { throw CapabilityError.invalidRequest("Invalid D3 readout") }
                        prediction = ["interrupt", "discard", "enqueue", "continue_listening"][index]
                        score = value
                    }
                    guard let prediction else { throw CapabilityError.invalidRequest("Missing D3 readout") }
                    return (prediction, score)
                }
                prediction = selection.0
                score = selection.1
            } catch {
                failure = String(describing: error)
            }
            let elapsed = start.duration(to: .now).components
            return .init(
                id: item.scenario.id, language: item.scenario.language, group: item.scenario.group,
                expected: item.scenario.expected, inputTokens: item.inputTokens, prediction: prediction, score: score,
                milliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15, error: failure)
        }
        for language in ["en", "zh-Hans"] {
            let selected = fixture.rows.filter { $0.scenario.language == language }
            let first = try #require(selected.first { $0.scenario.group == "unfinished" })
            for _ in 0..<3 {
                report.warmup.append(await measure(first))
                try save()
            }
            for item in selected {
                report.rows.append(await measure(item))
                try save()
                print("D3 readout: \(report.rows.count)/\(fixture.rows.count) \(item.scenario.id)")
            }
        }
        try verifySources()
        try await root.stop()
    } catch {
        try await root.stop()
        throw error
    }
}

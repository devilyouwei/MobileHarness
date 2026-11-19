import Foundation
import ModelKit
@_spi(ModelAssembly) import ModelKitRuntime
import Testing
import Tokenizers

@testable import ModelKitD3

private struct AdapterParityInput: Decodable {
    struct Row: Decodable {
        let model: String
        let artifacts: String
        let id: String
        let text: String
        let instructions: String
        let kind: String
        let candidates: [String]
        let prediction: String
        let score: Double
    }
    let rows: [Row]
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["DECISION_ADAPTER_INPUT"] != nil))
func decisionNewAdaptersNativeParity() async throws {
    guard #available(macOS 27, iOS 27, *) else { throw CapabilityError.unavailable("CoreAI requires OS 27") }
    let env = ProcessInfo.processInfo.environment
    let input = try #require(env["DECISION_ADAPTER_INPUT"])
    let output = try #require(env["DECISION_ADAPTER_REPORT"])
    let fixture = try JSONDecoder().decode(AdapterParityInput.self, from: Data(contentsOf: URL(fileURLWithPath: input)))
    struct Row: Encodable {
        let model: String
        let id: String
        let prediction: String
        let score: Double
        let reference: Double
        let delta: Double
        let milliseconds: Double
    }
    var rows: [Row] = []
    for name in ["vela31", "laya"] where env["DECISION_ADAPTER_MODEL"].map({ $0 == name }) ?? true {
        let cases = Array(fixture.rows.filter { $0.model == name }.prefix(3))
        let artifacts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
                try #require(cases.first?.artifacts))
        let manager = try ModelManager()
        let id = ModelID(name)
        try await manager.register(
            ModelRegistration(id: id, capabilities: [.decision]) { context in
                let provider: any DecisionCapability
                if name == "laya" {
                    provider = try LayaDecision(context: context, artifacts: artifacts)
                } else {
                    provider = try Vela31Decision(context: context, artifacts: artifacts)
                }
                return ProvidedCapabilities(decision: provider)
            })
        do {
            let provider = try await manager.get(id, as: .decision)
            for item in cases {
                let start = ContinuousClock.now
                let prediction: String
                let score: Double
                if item.kind == "noul" {
                    let session = try await provider.noul(NoulRequest(text: item.text, instructions: item.instructions))
                    let result = try await session.withCleanup {
                        var items: [NoulResult] = []
                        for try await value in session.events { items.append(value) }
                        try #require(items.count == 1)
                        return try #require(items.first)
                    }
                    prediction = String(result.value)
                    score = try #require(result.score)
                } else {
                    let session = try await provider.choice(
                        DecisionRequest(text: item.text, candidates: item.candidates, instructions: item.instructions))
                    let result = try await session.withCleanup {
                        var items: [DecisionResult] = []
                        for try await value in session.events { items.append(value) }
                        try #require(items.count == 1)
                        return try #require(items.first)
                    }
                    guard case .selected(let label, let probability) = result.decision else {
                        throw CapabilityError.invalidRequest("Unexpected abstention")
                    }
                    prediction = label
                    score = try #require(probability)
                }
                let time = start.duration(to: .now).components
                rows.append(
                    Row(
                        model: name, id: item.id, prediction: prediction, score: score,
                        reference: item.score, delta: abs(score - item.score),
                        milliseconds: Double(time.seconds) * 1000 + Double(time.attoseconds) / 1e15))
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(rows).write(to: URL(fileURLWithPath: output), options: .atomic)
                #expect(prediction == item.prediction, "\(item.id)")
                #expect(abs(score - item.score) <= 0.001, "\(item.id)")
            }
            // Oversize content must fail rather than truncate or fabricate a boolean.
            if name == "laya" {
                let oversized = try NoulRequest(text: String(repeating: "a ", count: 9000), instructions: "Stop?")
                let session = try await provider.noul(oversized)
                await #expect(throws: (any Error).self) {
                    try await session.withCleanup { for try await _ in session.events {} }
                }
            }
            await manager.shutdown()
        } catch {
            await manager.shutdown()
            throw error
        }
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LAYA_TOKEN_INPUT"] != nil))
func layaPublishedTokenizerParity() async throws {
    struct Input: Decodable {
        struct Row: Decodable {
            let text: String
            let ids: [Int]
        }
        let root: String
        let rows: [Row]
    }
    let path = try #require(ProcessInfo.processInfo.environment["LAYA_TOKEN_INPUT"])
    let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let tokenizer = try LayaTokenizer.load(
        at: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
                input.root))
    for row in input.rows {
        #expect(tokenizer.encode(text: row.text, addSpecialTokens: false) == row.ids, "\(row.text)")
    }
}

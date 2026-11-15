import CoreAILanguageModels
import Foundation

private struct Batch: Decodable {
    struct Sample: Decodable {
        let ids: [Int32]
        let maxTokens: Int
    }

    let model: String
    let vocabSize: Int
    let candidates: [Int32]
    let stops: Set<Int32>
    let samples: [Sample]
}

@main
struct DecisionDecoder {
    private struct Result: Encodable {
        let scores: [Float]
        let tokens: [Int32]
        let stopped: Bool
        let elapsedMS: Double
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileReadInvalidFileName) }
        let batchURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let batch = try JSONDecoder().decode(Batch.self, from: Data(contentsOf: batchURL))
        let graph = URL(fileURLWithPath: batch.model, isDirectory: true)
        let config = ModelConfig(
            name: "decision-benchmark", tokenizer: "local", vocabSize: batch.vocabSize,
            maxContextLength: 512, serializedModel: [graph.lastPathComponent], function: "main")
        let engine = try await EngineFactory.createEngine(
            config: JSONEncoder().encode(config), modelURL: graph,
            options: EngineOptions(variant: "coreai-sequential", kvCacheSize: 512))
        let encoder = JSONEncoder()

        // Use the same three discarded requests regardless of sample count.
        guard let first = batch.samples.first else { throw CocoaError(.fileReadCorruptFile) }
        let warmups = Array((batch.samples + [first, first]).prefix(3))
        for (index, sample) in (warmups + batch.samples).enumerated() {
            let start = ContinuousClock.now
            try await engine.reset(to: 0)
            let stream = try await engine.generate(
                with: sample.ids, samplingConfiguration: .greedy,
                inferenceOptions: InferenceOptions(
                    maxTokens: sample.maxTokens, includeLogits: !batch.candidates.isEmpty))
            var tokens: [Int32] = []
            var scores: [Float] = []
            var stopped = false
            for try await step in stream {
                if tokens.isEmpty, let logits = step.logits {
                    scores = batch.candidates.map { Float(logits[Int($0)]) }
                }
                if batch.stops.contains(step.tokenId) {
                    stopped = true
                    try await engine.cancel()
                    break
                }
                tokens.append(step.tokenId)
            }
            let parts = start.duration(to: .now).components
            if index >= warmups.count {
                let result = Result(
                    scores: scores, tokens: tokens, stopped: stopped,
                    elapsedMS: Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)
                print(String(decoding: try encoder.encode(result), as: UTF8.self))
            }
        }
    }
}

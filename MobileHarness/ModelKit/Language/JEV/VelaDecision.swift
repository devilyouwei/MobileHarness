import Foundation
import ModelKit
import ModelKitCoreAI
import Tokenizers

/// Native Vela choice/noul readout. The caller supplies candidate meanings and owns routing policy.
@available(iOS 27, macOS 27, *)
public actor VelaDecision: DecisionCapability {
    private let artifacts: URL
    #if canImport(CoreAI)
        private let resource: ModelResource<VelaGraph>
    #endif
    public init(context: ModelContext, artifacts: URL) throws {
        self.artifacts = artifacts
        #if canImport(CoreAI)
            resource = try context.resource { try await VelaGraph(artifacts: artifacts) }
        #endif
    }
    public var availability: CapabilityAvailability {
        #if canImport(CoreAI)
            FileManager.default.fileExists(atPath: artifacts.appendingPathComponent("model.aimodel").path)
                ? .available : .unavailable(reason: "Vela artifacts are not installed")
        #else
            .unavailable(reason: "Core AI is unavailable on this platform")
        #endif
    }
    public func noul(_ request: NoulRequest) async throws -> InferenceSession<NoulResult> {
        try await booleanReadout(request, candidates: ["no", "yes"])
    }
    public func choice(_ request: DecisionRequest) async throws -> InferenceSession<DecisionResult> {
        #if canImport(CoreAI)
            let lease = try await resource.acquire()
            let control = InferenceTaskControl()
            let pair = InferenceSession<DecisionResult>.make(
                context: request.context, limits: try StreamLimits(capacity: 1), estimatedBytes: { _ in 1024 },
                onTermination: { reason in
                    if case .finished = reason { return }
                    control.cancel()
                }, waitForCompletion: { await control.waitForCompletion() })
            let resource = resource
            let task = Task {
                do {
                    let result = try await lease.model.choice(request)
                    try Task.checkCancellation()
                    try pair.emitter.yield(result)
                    pair.emitter.finish()
                } catch { pair.emitter.fail(error) }
                await resource.release(lease.id)
                control.finish()
            }
            try control.install(task)
            await resource.setCancellation(lease.id) { control.cancel() }
            return pair.session
        #else
            throw CapabilityError.unavailable("Core AI is unavailable on this platform")
        #endif
    }
}

#if canImport(CoreAI)
    @available(iOS 27, macOS 27, *)
    private actor VelaGraph {
        struct Manifest: Decodable {
            enum CodingKeys: String, CodingKey {
                case function, output
                case sequenceLength = "sequence_length"
                case dynamicSequenceLength = "dynamic_sequence_length"
            }
            let function: String
            let output: String
            let sequenceLength: Int
            let dynamicSequenceLength: Bool
        }
        struct Configuration: Decodable {
            enum CodingKeys: String, CodingKey {
                case bosTokenID = "bos_token_id"
                case eosTokenID = "eos_token_id"
                case markerIDs = "marker_ids"
            }
            let bosTokenID: Int
            let eosTokenID: Int
            let markerIDs: [String: Int]
        }
        let graph: GraphModel
        let tokenizer: any Tokenizer
        let manifest: Manifest
        let configuration: Configuration
        init(artifacts: URL) async throws {
            manifest = try JSONDecoder().decode(
                Manifest.self, from: Data(contentsOf: artifacts.appendingPathComponent("manifest.json")))
            configuration = try JSONDecoder().decode(
                Configuration.self, from: Data(contentsOf: artifacts.appendingPathComponent("decision.json")))
            let markers = configuration.markerIDs
            guard manifest.dynamicSequenceLength, manifest.sequenceLength == 32768,
                ["[Q]", "[O]", "[SEP_SCHEMA]", "[SEG_user]"].allSatisfy({ markers[$0] != nil })
            else {
                throw CapabilityError.invalidRequest("Unsupported Vela artifact contract")
            }
            tokenizer = try await AutoTokenizer.from(modelFolder: artifacts)
            graph = try await GraphModel(
                contentsOf: artifacts.appendingPathComponent("model.aimodel"),
                function: manifest.function, computeUnits: .cpuOnly)
            guard Set(await graph.inputNames) == Set(["input_ids", "attention_mask", "option_positions", "pool_mask"]),
                await graph.outputNames.contains(manifest.output)
            else {
                throw CapabilityError.invalidRequest("Unexpected Vela graph interface")
            }
        }
        func choice(_ request: DecisionRequest) async throws -> DecisionResult {
            func marker(_ name: String) throws -> Int {
                guard let value = configuration.markerIDs[name] else {
                    throw CapabilityError.invalidRequest("Missing Vela marker")
                }
                return value
            }
            var ids = [configuration.bosTokenID, try marker("[Q]")]
            ids += tokenizer.encode(text: request.instructions, addSpecialTokens: false)
            var positions: [Int32] = []
            for candidate in request.candidates {
                positions.append(Int32(ids.count))
                ids += [try marker("[O]")] + tokenizer.encode(text: candidate, addSpecialTokens: false)
            }
            ids.append(try marker("[SEP_SCHEMA]"))
            let start = ids.count
            ids += [try marker("[SEG_user]")] + tokenizer.encode(text: request.text, addSpecialTokens: false)
            let end = ids.count
            ids.append(configuration.eosTokenID)
            guard ids.count <= manifest.sequenceLength, ids.allSatisfy({ Int32(exactly: $0) != nil }) else {
                throw CapabilityError.invalidRequest("Vela input exceeds capacity; input was not truncated")
            }
            let shape = [1, ids.count]
            let result = try await graph.run([
                "input_ids": .int32(ids.map(Int32.init), shape: shape),
                "attention_mask": .int32(Array(repeating: 1, count: ids.count), shape: shape),
                "option_positions": .int32(positions, shape: [1, positions.count]),
                "pool_mask": .float32(ids.indices.map { (start..<end).contains($0) ? 1 : 0 }, shape: shape),
            ])
            guard let logits = result[manifest.output]?.floats(), logits.count == request.candidates.count,
                logits.allSatisfy(\.isFinite), let maximum = logits.max(), let index = logits.firstIndex(of: maximum)
            else {
                throw CapabilityError.invalidRequest("Invalid Vela readout")
            }
            let probabilities = logits.map { exp(Double($0) - Double(maximum)) }
            return try DecisionResult(
                decision: .selected(
                    label: request.candidates[index],
                    score: probabilities[index] / probabilities.reduce(0, +)), for: request)
        }
    }
#endif

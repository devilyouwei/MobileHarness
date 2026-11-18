import Foundation
import ModelKit
import ModelKitCoreAI
import Tokenizers

/// Native Vela choice/noul readout. The caller supplies candidate meanings and owns routing policy.
@available(iOS 27, macOS 27, *)
public actor Vela31Decision: DecisionCapability {
    private let artifacts: URL
    #if canImport(CoreAI)
        private let resource: ModelResource<Vela31Graph>
    #endif
    public init(context: ModelContext, artifacts: URL) throws {
        self.artifacts = artifacts
        #if canImport(CoreAI)
            resource = try context.resource { try await Vela31Graph(artifacts: artifacts) }
        #endif
    }
    public var availability: CapabilityAvailability {
        #if canImport(CoreAI)
            FileManager.default.fileExists(
                atPath: artifacts.appendingPathComponent("graphs/decision/model.aimodel").path)
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
    private actor Vela31Graph {
        struct Manifest: Decodable {
            enum CodingKeys: String, CodingKey {
                case format, components
                case weightBinding = "weight_binding"
                case sequenceLength = "sequence_length"
            }
            struct Component: Decodable {
                struct Weight: Decodable {
                    let file: String
                    let tensor: String
                    let shape: [Int]
                }
                let graph: String
                let states: [String: Weight]
            }
            let format: String
            let weightBinding: String
            let sequenceLength: [String: Int]
            let components: [String: Component]
        }
        struct Configuration: Decodable {
            enum CodingKeys: String, CodingKey {
                case decision
                case bosTokenID = "bos_token_id"
                case eosTokenID = "eos_token_id"
            }
            struct Decision: Decodable {
                enum CodingKeys: String, CodingKey { case markerIDs = "marker_ids" }
                let markerIDs: [String: Int]
            }
            let bosTokenID: Int
            let eosTokenID: Int
            let decision: Decision
        }
        let graph: GraphModel
        let tokenizer: any Tokenizer
        let configuration: Configuration
        let capacity: Int
        init(artifacts: URL) async throws {
            let manifest = try JSONDecoder().decode(
                Manifest.self, from: Data(contentsOf: artifacts.appendingPathComponent("manifest.json")))
            let configuration = try JSONDecoder().decode(
                Configuration.self, from: Data(contentsOf: artifacts.appendingPathComponent("config.json")))
            guard manifest.format == "vela-full-coreai/1", manifest.weightBinding == "inputs",
                let component = manifest.components["decision"], component.graph == "graphs/decision",
                let capacity = manifest.sequenceLength["decision"], capacity == 32768,
                ["[Q]", "[O]", "[SEP_SCHEMA]", "[SEG_user]"].allSatisfy({ configuration.decision.markerIDs[$0] != nil }
                ),
                component.states.values.allSatisfy({ $0.file == "model.safetensors" })
            else {
                throw CapabilityError.invalidRequest("Unsupported Vela 3.1 artifact contract")
            }
            self.configuration = configuration
            self.capacity = capacity
            tokenizer = try await AutoTokenizer.from(modelFolder: artifacts)
            let weights = try SafeTensorArchive(
                contentsOf: artifacts.appendingPathComponent("weights/model.safetensors"))
            let constants = try component.states.mapValues { try weights.tensor(named: $0.tensor, shape: $0.shape) }
            graph = try await GraphModel(
                contentsOf: artifacts.appendingPathComponent("graphs/decision/model.aimodel"),
                computeUnits: .cpuOnly, constantInputs: constants)
            guard
                Set(await graph.inputNames)
                    == Set(["input_ids", "attention_mask", "q_index", "opt_index", "unit_index", "ent_index"]),
                await graph.outputNames.contains("logits")
            else {
                throw CapabilityError.invalidRequest("Unexpected Vela 3.1 graph interface")
            }
        }
        func choice(_ request: DecisionRequest) async throws -> DecisionResult {
            func marker(_ name: String) throws -> Int {
                guard let id = configuration.decision.markerIDs[name] else {
                    throw CapabilityError.invalidRequest("Missing Vela marker")
                }
                return id
            }
            var ids = [configuration.bosTokenID, try marker("[Q]")]
            ids += tokenizer.encode(text: request.instructions, addSpecialTokens: false)
            var positions: [Int32] = []
            for candidate in request.candidates {
                positions += [0, Int32(ids.count), 0]
                ids += [try marker("[O]")] + tokenizer.encode(text: candidate, addSpecialTokens: false)
            }
            ids.append(try marker("[SEP_SCHEMA]"))
            let start = ids.count
            ids += [try marker("[SEG_user]")] + tokenizer.encode(text: request.text, addSpecialTokens: false)
            let end = ids.count
            ids.append(configuration.eosTokenID)
            guard ids.count <= capacity, ids.allSatisfy({ Int32(exactly: $0) != nil }) else {
                throw CapabilityError.invalidRequest("Vela 3.1 input exceeds capacity; input was not truncated")
            }
            let result = try await graph.run([
                "input_ids": .int32(ids.map(Int32.init), shape: [1, ids.count]),
                "attention_mask": .int32(Array(repeating: 1, count: ids.count), shape: [1, ids.count]),
                "q_index": .int32([0, 1, Int32(start), Int32(end)], shape: [1, 4]),
                "opt_index": .int32(positions, shape: [request.candidates.count, 3]),
                "unit_index": .int32([0, 0], shape: [1, 2]),
                "ent_index": .int32([0, 0], shape: [1, 2]),
            ])
            guard let logits = result["logits"]?.floats(), logits.count == request.candidates.count,
                logits.allSatisfy(\.isFinite), let maximum = logits.max(), let index = logits.firstIndex(of: maximum)
            else {
                throw CapabilityError.invalidRequest("Invalid Vela 3.1 readout")
            }
            let probabilities = logits.map { exp(Double($0) - Double(maximum)) }
            return try DecisionResult(
                decision: .selected(
                    label: request.candidates[index],
                    score: probabilities[index] / probabilities.reduce(0, +)), for: request)
        }
    }
#endif

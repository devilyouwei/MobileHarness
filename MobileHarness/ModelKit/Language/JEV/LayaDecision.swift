import Foundation
import ModelKit
import ModelKitCoreAI
import Tokenizers

@available(iOS 27, macOS 27, *)
public actor LayaDecision: DecisionCapability {
    private let artifacts: URL
    #if canImport(CoreAI)
        private let resource: ModelResource<LayaGraph>
    #endif
    /// artifacts is the platform-specific bundle root, containing metadata.json and tokenizer/.
    public init(context: ModelContext, artifacts: URL) throws {
        self.artifacts = artifacts
        #if canImport(CoreAI)
            resource = try context.resource { try await LayaGraph(artifacts: artifacts) }
        #endif
    }
    public var availability: CapabilityAvailability {
        #if canImport(CoreAI)
            FileManager.default.fileExists(atPath: artifacts.appendingPathComponent("laya_ml_wfp16_s512.aimodel").path)
                ? .available : .unavailable(reason: "Laya artifacts are not installed")
        #else
            .unavailable(reason: "Core AI is unavailable on this platform")
        #endif
    }
    public func choice(_ request: DecisionRequest) async throws -> InferenceSession<DecisionResult> {
        #if canImport(CoreAI)
            return try await infer(context: request.context) { graph in
                let p = try await graph.probabilities(
                    text: request.text, instructions: request.instructions,
                    candidates: request.candidates, noul: false)
                guard let max = p.max(), let index = p.firstIndex(of: max) else {
                    throw CapabilityError.invalidRequest("Empty Laya readout")
                }
                return try DecisionResult(
                    decision: .selected(label: request.candidates[index], score: Self.round(p[index])), for: request)
            }
        #else
            throw CapabilityError.unavailable("Core AI is unavailable on this platform")
        #endif
    }
    public func noul(_ request: NoulRequest) async throws -> InferenceSession<NoulResult> {
        #if canImport(CoreAI)
            return try await infer(context: request.context) { graph in
                let p = try await graph.probabilities(
                    text: request.text, instructions: request.instructions,
                    candidates: ["false: no, the statement does not hold", "true: yes, the statement holds"], noul: true
                )
                let score = Self.round(p[1])
                return try NoulResult(value: score > 0.5, score: score)
            }
        #else
            throw CapabilityError.unavailable("Core AI is unavailable on this platform")
        #endif
    }
    private static func round(_ value: Float) -> Double {
        (Double(value) * 10000).rounded(.toNearestOrEven) / 10000
    }
    #if canImport(CoreAI)
        private func infer<Result: Sendable>(
            context: InferenceContext, operation: @escaping @Sendable (LayaGraph) async throws -> Result
        ) async throws -> InferenceSession<Result> {
            let lease = try await resource.acquire()
            let control = InferenceTaskControl()
            let pair = InferenceSession<Result>.make(
                context: context, limits: try StreamLimits(capacity: 1), estimatedBytes: { _ in 1024 },
                onTermination: { reason in
                    if case .finished = reason { return }
                    control.cancel()
                }, waitForCompletion: { await control.waitForCompletion() })
            let resource = resource
            let task = Task {
                do {
                    let result = try await operation(lease.model)
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
        }
    #endif
}

#if canImport(CoreAI)
    @available(iOS 27, macOS 27, *)
    private actor LayaGraph {
        struct Metadata: Decodable {
            struct Decision: Decodable {
                enum CodingKeys: String, CodingKey {
                    case window, temperature
                    case headMaxLength = "head_max_len"
                    case optionTextTokens = "option_text_tokens"
                    case clsTokenID = "cls_token_id"
                    case sepTokenID = "sep_token_id"
                    case padTokenID = "pad_token_id"
                    case maskTokenID = "mask_token_id"
                    case temperatureByOptions = "temperature_by_options"
                }
                let window: Int
                let headMaxLength: Int
                let optionTextTokens: Int
                let clsTokenID: Int
                let sepTokenID: Int
                let padTokenID: Int
                let maskTokenID: Int
                let temperature: [Float]
                let temperatureByOptions: [String: Float]
            }
            let decision: Decision
            let assets: [String: String]
        }
        let main: GraphModel
        let act: GraphModel
        let tokenizer: any Tokenizer
        let config: Metadata.Decision
        init(artifacts: URL) async throws {
            let metadata = try JSONDecoder().decode(
                Metadata.self, from: Data(contentsOf: artifacts.appendingPathComponent("metadata.json")))
            config = metadata.decision
            guard config.window == 512, config.headMaxLength == 256, config.optionTextTokens == 48,
                metadata.assets["main"] == "laya_ml_wfp16_s512.aimodel",
                config.temperature.count == 3, config.temperature.allSatisfy({ $0.isFinite && $0 > 0 }),
                config.temperatureByOptions.values.allSatisfy({ $0.isFinite && $0 > 0 })
            else {
                throw CapabilityError.invalidRequest("Unsupported Laya artifact contract")
            }
            tokenizer = try LayaTokenizer.load(at: artifacts.appendingPathComponent("tokenizer"))
            main = try await GraphModel(
                contentsOf: artifacts.appendingPathComponent("laya_ml_wfp16_s512.aimodel"), computeUnits: .gpu)
            act = try await main.function(named: "act")
            guard Set(await main.inputNames) == Set(["input_ids", "attention_mask", "qtype_onehot"]),
                Set(await act.inputNames) == Set(["pooled_cls", "feats"])
            else {
                throw CapabilityError.invalidRequest("Unexpected Laya graph interface")
            }
        }
        func probabilities(text: String, instructions: String, candidates: [String], noul: Bool) async throws -> [Float]
        {
            func encode(_ text: String) -> [Int] {
                tokenizer.encode(text: text.replacingOccurrences(of: "<mask>", with: " "), addSpecialTokens: false)
            }
            let kind = noul ? "noul" : "choice"
            let question = encode("\(kind) question: \(instructions)")
            let options = candidates.map { encode(" " + $0) }
            let optionCount = options.reduce(0) { $0 + $1.count + 1 }
            let budget = config.headMaxLength - optionCount
            // Reject the spans the upstream builder would truncate, instead of changing caller meaning.
            guard options.allSatisfy({ $0.count <= config.optionTextTokens }), budget >= 16,
                question.count <= max(8, budget)
            else {
                throw CapabilityError.invalidRequest(
                    "Laya question or options exceed capacity; input was not truncated")
            }
            var ids = [config.clsTokenID] + question + [config.sepTokenID]
            var markers: [Int] = []
            for option in options {
                markers.append(ids.count)
                ids += [config.maskTokenID] + option
            }
            ids += [config.sepTokenID] + encode(text) + [config.sepTokenID]
            guard ids.count <= config.window, ids.allSatisfy({ Int32(exactly: $0) != nil }) else {
                throw CapabilityError.invalidRequest("Laya input exceeds capacity; input was not truncated")
            }
            let length = ids.count
            ids += Array(repeating: config.padTokenID, count: config.window - length)
            let result = try await main.run([
                "input_ids": .int32(ids.map(Int32.init), shape: [1, config.window]),
                "attention_mask": .int32((0..<config.window).map { $0 < length ? 1 : 0 }, shape: [1, config.window]),
                "qtype_onehot": .float32(noul ? [0, 0, 1] : [1, 0, 0], shape: [1, 3]),
            ])
            guard let logits = result["token_logits"]?.floats(), logits.count == config.window,
                let cls = result["pooled_cls"], logits.allSatisfy(\.isFinite)
            else {
                throw CapabilityError.invalidRequest("Invalid Laya readout")
            }
            let raw = markers.map { logits[$0] }
            let p = softmax(raw)
            let sorted = p.sorted(by: >)
            let k = Float(max(2, p.count))
            let entropy = -p.reduce(Float(0)) { $0 + $1 * log(max($1, 1e-9)) } / log(k)
            let action = try await act.run([
                "pooled_cls": cls,
                "feats": .float32(
                    [sorted[0], sorted[0] - (sorted.count > 1 ? sorted[1] : 0), entropy, k / 255], shape: [1, 4]),
            ])
            guard let actionLogits = action["act_logits"]?.floats(), actionLogits.count == 2,
                actionLogits.allSatisfy(\.isFinite)
            else { throw CapabilityError.invalidRequest("Invalid Laya action readout") }
            let bucket = p.count <= 2 ? "2" : p.count <= 5 ? "3-5" : p.count <= 10 ? "6-10" : "11+"
            let temperature = config.temperatureByOptions["\(kind):\(bucket)"] ?? config.temperature[noul ? 2 : 0]
            return softmax(raw.map { $0 / max(1e-3, temperature) })
        }
        private func softmax(_ logits: [Float]) -> [Float] {
            let maximum = logits.dropFirst().reduce(logits[0], max)
            let values = logits.map { exp($0 - maximum) }
            let sum = values.reduce(0, +)
            return values.map { $0 / sum }
        }
    }
#endif

/// Preserve the publisher's Metaspace prepend semantics in swift-transformers.
enum LayaTokenizer {
    static func load(at root: URL) throws -> any Tokenizer {
        let decoder = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("tokenizer_config.json")))
        let model = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("tokenizer.json")))
        guard let configuration = decoder as? [NSString: Any], var data = model as? [NSString: Any],
            var preTokenizer = data["pre_tokenizer"] as? [NSString: Any],
            preTokenizer["type"] as? String == "Metaspace",
            preTokenizer["prepend_scheme"] as? String == "always"
        else {
            throw CapabilityError.invalidRequest("Unsupported Laya tokenizer contract")
        }
        preTokenizer["add_prefix_space"] = true
        data["pre_tokenizer"] = preTokenizer
        return try AutoTokenizer.from(tokenizerConfig: .init(configuration), tokenizerData: .init(data))
    }
}

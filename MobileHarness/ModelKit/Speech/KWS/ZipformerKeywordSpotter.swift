import CoreML
import Foundation
@_spi(ModelManagement) import ModelKit
import ModelKitCoreML

public struct ZipformerKeywordSpotter: KeywordSpottingCapability {
    public static let modelIdentity = InferenceModelIdentity(
        modelID: "zipformer-kws", displayName: "Zipformer Keyword Spotting")
    private let resource: ModelResource<ZipformerGraphs>
    private let context: ModelContext

    public init(context: ModelContext, artifacts: URL) throws {
        self.context = context
        resource = try context.resource { try await ZipformerGraphs(root: artifacts) }
    }

    public var availability: CapabilityAvailability {
        get async {
            await context.status == .ready ? .available : .unavailable(reason: "Zipformer is not warmed")
        }
    }

    public func openKeywords(_ keywords: [SpeechKeyword]) async throws -> (any KeywordSpottingSession)? {
        guard let lease = try await resource.acquireIfReady() else { return nil }
        let resource = resource
        do {
            let session = try ZipformerSession(model: lease.model, keywords: keywords) {
                await resource.release(lease.id)
            }
            await resource.setCancellation(lease.id) { [weak session] in Task { await session?.cancel() } }
            return session
        } catch {
            await resource.release(lease.id)
            throw error
        }
    }
}

private struct ZipformerGraphs: Sendable {
    struct Graph: Decodable, Sendable {
        struct Input: Decodable, Sendable {
            let name: String
            let shape: [Int]

            func tensor(_ values: [Float]) -> CoreMLTensor { .init(shape: shape, values: values) }
            var zeros: CoreMLTensor { tensor(Array(repeating: 0, count: shape.reduce(1, *))) }
        }
        let inputs: [Input]
        let outputs: [String]
    }

    private struct Manifest: Decodable {
        let graphs: [String: Graph]
    }

    let encoder: CoreMLGraph
    let decoder: CoreMLGraph
    let joiner: CoreMLGraph
    let encoderContract: Graph
    let symbols: [String: Int]

    init(root: URL) async throws {
        let data = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard let contract = manifest.graphs["encoder"], contract.inputs.count == 39,
            contract.outputs.count == 39, Set(contract.outputs).count == 39,
            Set(contract.inputs.map(\.name)).count == 39, contract.inputs.first?.shape == [1, 29, 80],
            contract.inputs.first?.name == "x",
            contract.inputs.dropFirst().allSatisfy({ input in
                !input.shape.isEmpty && input.shape.count <= 4 && input.shape.allSatisfy { (1...512).contains($0) }
                    && input.shape.reduce(1, *) <= 65536
            })
        else { throw CapabilityError.invalidRequest("Invalid Zipformer graph manifest") }
        encoderContract = contract
        let vocabulary = try String(contentsOf: root.appendingPathComponent("tokens.txt"), encoding: .utf8)
        var symbols: [String: Int] = [:]
        for line in vocabulary.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, let id = Int(fields[1]), (0..<263).contains(id),
                symbols.updateValue(id, forKey: String(fields[0])) == nil
            else { throw CapabilityError.invalidRequest("Invalid Zipformer vocabulary") }
        }
        guard symbols.count == 263, Set(symbols.values).count == 263 else {
            throw CapabilityError.invalidRequest("Incomplete Zipformer vocabulary")
        }
        self.symbols = symbols
        encoder = try await Self.load("encoder", root: root)
        decoder = try await Self.load("decoder", root: root)
        joiner = try await Self.load("joiner", root: root)
        let encoded = try await encoder.run(
            Dictionary(uniqueKeysWithValues: contract.inputs.map { ($0.name, $0.zeros) }))
        guard let vector = encoded[contract.outputs[0]], vector.shape == [1, 4, 320] else {
            throw CapabilityError.invalidRequest("Invalid Zipformer encoder output")
        }
        _ = try await join(Array(vector.values.prefix(320)), decode([-1, 0]))
    }

    private static func load(_ name: String, root: URL) async throws -> CoreMLGraph {
        let package = root.appendingPathComponent(name + ".mlpackage")
        let compiled = try await MLModel.compileModel(at: package)
        defer { try? FileManager.default.removeItem(at: compiled) }
        return try await CoreMLGraph(contentsOf: compiled)
    }

    func decode(_ context: [Int]) async throws -> [Float] {
        let result = try await decoder.run(["y": .init(shape: [1, 2], values: context.map(Float.init))])
        guard let vector = result["decoder_out"], vector.shape == [1, 320] else {
            throw CapabilityError.invalidRequest("Invalid Zipformer decoder output")
        }
        return vector.values
    }

    func join(_ encoder: [Float], _ decoder: [Float]) async throws -> [Float] {
        let result = try await joiner.run([
            "encoder_out": .init(shape: [1, 320], values: encoder),
            "decoder_out": .init(shape: [1, 320], values: decoder),
        ])
        guard let logits = result["logit"], logits.shape == [1, 263] else {
            throw CapabilityError.invalidRequest("Invalid Zipformer joiner output")
        }
        return logits.values
    }
}

private actor ZipformerSession: KeywordSpottingSession {
    private let model: ZipformerGraphs
    private let release: @Sendable () async -> Void
    private let frontend: ZipformerFilterbank
    private var decoder: ZipformerKeywordDecoder
    private var frames: [[Float]] = []
    private var caches: [CoreMLTensor]
    private var inferenceDuration: Duration = .zero
    private var busy = false
    private var matched = false
    private var closed = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(model: ZipformerGraphs, keywords: [SpeechKeyword], release: @escaping @Sendable () async -> Void) throws {
        guard (1...32).contains(keywords.count) else {
            throw CapabilityError.invalidRequest("Invalid Zipformer keyword count")
        }
        var labels: [[Int]: SpeechKeyword] = [:]
        for item in keywords {
            let ids = item.tokens.compactMap { model.symbols[$0] }
            guard (1...32).contains(ids.count), ids.count == item.tokens.count,
                !ids.contains(0), !ids.contains(2), !item.label.isEmpty, (0...1).contains(item.threshold),
                labels.updateValue(item, forKey: ids) == nil
            else { throw CapabilityError.invalidRequest("Unknown or duplicate Zipformer keyword") }
        }
        self.model = model
        self.release = release
        frontend = try ZipformerFilterbank()
        decoder = ZipformerKeywordDecoder(keywords: labels)
        caches = model.encoderContract.inputs.dropFirst().map(\.zeros)
    }

    deinit {
        let release = release
        Task { await release() }
    }

    func accept(_ samples: [Float]) async throws -> KeywordSpottingMatch? {
        guard !closed, !matched else { throw CapabilityError.sessionClosed }
        guard !busy else { throw CapabilityError.inputBusy }
        guard (1...4096).contains(samples.count), samples.allSatisfy(\.isFinite) else {
            throw CapabilityError.invalidRequest("Invalid Zipformer PCM packet")
        }
        busy = true
        defer {
            busy = false
            waiter?.resume()
            waiter = nil
        }
        frames.append(contentsOf: frontend.accept(samples))
        while frames.count >= 29 {
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            let started = ContinuousClock.now
            let label = try await decodeWindow()
            inferenceDuration += started.duration(to: .now)
            if let label {
                matched = true
                return .init(
                    label: label,
                    metadata: .init(model: ZipformerKeywordSpotter.modelIdentity, inferenceDuration: inferenceDuration))
            }
            frames.removeFirst(16)
        }
        return nil
    }

    private func decodeWindow() async throws -> String? {
        let contract = model.encoderContract
        let features = contract.inputs[0].tensor(frames.prefix(29).flatMap { $0 })
        let inputs = Dictionary(uniqueKeysWithValues: zip(contract.inputs.map(\.name), [features] + caches))
        let output = try await model.encoder.run(inputs)
        guard let vector = output[contract.outputs[0]], vector.shape == [1, 4, 320] else {
            throw CapabilityError.invalidRequest("Invalid Zipformer encoder output")
        }
        caches = try zip(contract.inputs.dropFirst(), contract.outputs.dropFirst()).map { input, name in
            guard let tensor = output[name], tensor.shape == input.shape else {
                throw CapabilityError.invalidRequest("Invalid Zipformer cache: \(name)")
            }
            return tensor
        }
        var beam = decoder
        for start in stride(from: 0, to: vector.values.count, by: 320) {
            guard !closed else { throw CancellationError() }
            if let hit = try await beam.accept(
                Array(vector.values[start..<(start + 320)]), decode: model.decode, join: model.join)
            {
                return hit
            }
        }
        decoder = beam
        return nil
    }

    func cancel() async {
        guard !closed else { return }
        closed = true
        if busy { await withCheckedContinuation { waiter = $0 } }
        await release()
    }
}

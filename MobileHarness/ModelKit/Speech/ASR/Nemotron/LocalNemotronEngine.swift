@preconcurrency import CoreML
import FluidAudio
import Foundation

/// Locally provisioned multilingual/2240ms Core ML graphs; never invokes SDK download APIs.
public struct LocalNemotronEngine: Sendable {
    public enum Failure: Error, Sendable {
        case missingResource(String)
        case invalidMetadata
        case unknownLanguage(String)
        case busy, limitExceeded
    }
    private let models: SharedNemotronMultilingualModels
    public static let graphNames = ["preprocessor", "encoder", "decoder", "joint", "decoder_joint"]

    public static func validateResources(at root: URL) throws -> [String: Int] {
        for graph in graphNames {
            for file in ["model.mil", "coremldata.bin", "analytics/coremldata.bin", "weights/weight.bin"] {
                try require(root.appendingPathComponent("\(graph).mlmodelc/\(file)"))
            }
        }
        try require(root.appendingPathComponent("tokenizer.json"), maximumBytes: 8 * 1024 * 1024)
        return try validateMetadata(
            Data(contentsOf: require(root.appendingPathComponent("metadata.json"), maximumBytes: 1024 * 1024)))
    }
    /// Reject incompatible exports instead of allowing the SDK's metadata defaults to choose another tier.
    public static func validateMetadata(_ data: Data) throws -> [String: Int] {
        guard data.count <= 1024 * 1024,
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            json["sample_rate"] as? Int == 16000, json["mel_features"] as? Int == 128,
            json["chunk_mel_frames"] as? Int == 224, json["pre_encode_cache"] as? Int == 9,
            json["total_mel_frames"] as? Int == 233, json["vocab_size"] as? Int == 13087,
            json["blank_idx"] as? Int == 13087, json["encoder_dim"] as? Int == 1024,
            json["decoder_hidden"] as? Int == 640, json["decoder_layers"] as? Int == 2,
            json["cache_channel_shape"] as? [Int] == [1, 24, 42, 1024],
            json["cache_time_shape"] as? [Int] == [1, 24, 1024, 8],
            json["num_prompts"] as? Int == 128, json["default_prompt_id"] as? Int == 101,
            let prompts = json["prompt_dictionary"] as? [String: Int],
            !prompts.isEmpty, prompts.count <= 256, prompts["auto"] == 101,
            prompts.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 32 && (0..<128).contains($0.value) })
        else { throw Failure.invalidMetadata }
        return prompts
    }
    @discardableResult private static func require(_ url: URL, maximumBytes: Int = 1024 * 1024 * 1024) throws -> URL {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true,
            let bytes = values?.fileSize, bytes > 0, bytes <= maximumBytes
        else { throw Failure.missingResource(url.lastPathComponent) }
        return url
    }
    public init(artifacts: URL) async throws {
        _ = try Self.validateResources(at: artifacts)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        models = try await StreamingNemotronMultilingualAsrManager.preloadShared(
            from: artifacts, configuration: configuration)
        try Task.checkCancellation()
    }
    public func makeSession(language: String) async throws -> LocalNemotronSession {
        guard let prompt = models.config.promptDictionary[language] else { throw Failure.unknownLanguage(language) }
        let manager = StreamingNemotronMultilingualAsrManager(configuration: models.mlConfiguration)
        try await manager.loadFromShared(models)
        await manager.setPromptId(prompt)
        try Task.checkCancellation()
        return LocalNemotronSession(manager: manager)
    }
}

/// One fresh recurrent state per session. Cancellation joins native work before releasing graph handles.
public actor LocalNemotronSession {
    private var manager: StreamingNemotronMultilingualAsrManager?
    private var inFlight: Task<String, Error>?
    private var closing: Task<Void, Never>?
    private var samplesSeen = 0
    fileprivate init(manager: StreamingNemotronMultilingualAsrManager) { self.manager = manager }
    public func feed(samples: [Float]) async throws -> String {
        guard samples.count <= 16000, samplesSeen <= 4_800_000 - samples.count,
            samples.allSatisfy(\.isFinite)
        else { throw LocalNemotronEngine.Failure.limitExceeded }
        guard inFlight == nil else { throw LocalNemotronEngine.Failure.busy }
        samplesSeen += samples.count
        return try await perform { manager in
            _ = try await manager.process(samples: samples)
            let text = await manager.getPartialTranscript()
            let tokens = await manager.getTokenTimings().count
            try Self.validateOutput(text, tokens: tokens)
            return text
        }
    }
    public func finish() async throws -> String {
        try await perform { manager in
            let text = try await manager.finish()
            let stats = await manager.lastDecodeStats()
            try Self.validateOutput(text, tokens: stats.tokenCount)
            return text
        }
    }
    private nonisolated static func validateOutput(_ text: String, tokens: Int) throws {
        guard tokens <= 16384, text.utf8.count <= 65536 else { throw LocalNemotronEngine.Failure.limitExceeded }
    }
    private func perform(
        _ operation: @escaping @Sendable (StreamingNemotronMultilingualAsrManager) async throws -> String
    ) async throws -> String {
        guard let manager else { throw CancellationError() }
        guard inFlight == nil else { throw LocalNemotronEngine.Failure.busy }
        let task = Task {
            try Task.checkCancellation()
            let result = try await operation(manager)
            try Task.checkCancellation()
            return result
        }
        inFlight = task
        defer { inFlight = nil }
        let text = try await task.value
        guard self.manager != nil else { throw CancellationError() }
        return text
    }
    public func cancel() async {
        if let closing {
            await closing.value
            return
        }
        guard let manager else { return }
        self.manager = nil
        let active = inFlight
        let task = Task {
            active?.cancel()
            if let active { _ = await active.result }
            await manager.cleanup()
        }
        closing = task
        await task.value
        closing = nil
    }
}

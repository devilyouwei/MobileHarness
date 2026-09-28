@preconcurrency import CoreML
import Foundation

/// Locally provisioned graphs. No downloader, global state, or intermediate audio queue.
public actor LocalMossEngine {
    public static let graphNames = [
        "MossNano-Prefill-T512-M1024-fp16", "MossNano-Step-M1024-fp16",
        "MossNano-Frame-fp16", "MossNano-CodecStep-fp16",
    ]
    private let synthesizer: MossTtsNanoSynthesizer
    private let english: MossTtsNanoVoice
    private let chinese: MossTtsNanoVoice

    public static func validateResources(at root: URL) throws {
        var files = ["config.json", "tokenizer.model", "voices/en_2.json", "voices/zh_1.json"]
        for name in graphNames {
            files += ["coremldata.bin", "model.mil", "weights/weight.bin"].map { name + ".mlmodelc/" + $0 }
        }
        for file in files {
            let values = try root.appendingPathComponent(file).resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey,
            ])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
                throw MossTtsNanoError.modelFileNotFound(file)
            }
        }
    }

    public init(root: URL) throws {
        try Self.validateResources(at: root)
        let config = try MossTtsNanoConfig.load(from: root.appendingPathComponent("config.json"))
        guard config.model.nVq == 16, config.model.rowWidth == 17, config.model.sampleRate == 48_000,
            config.model.channels == 2, config.model.samplesPerFramePerChannel == 3840,
            config.coreml.prefillRows == 512, config.coreml.maxLen == 1024
        else { throw MossTtsNanoError.configLoadFailed("Unsupported graph contract") }
        let tokenizer = try MossTtsNanoTokenizer(modelURL: root.appendingPathComponent("tokenizer.model"))
        english = try MossTtsNanoVoice.load(from: root.appendingPathComponent("voices/en_2.json"))
        chinese = try MossTtsNanoVoice.load(from: root.appendingPathComponent("voices/zh_1.json"))
        let options = MLModelConfiguration()
        options.computeUnits = .cpuAndGPU
        func load(_ index: Int) throws -> MLModel {
            try Task.checkCancellation()
            return try MLModel(
                contentsOf: root.appendingPathComponent(Self.graphNames[index] + ".mlmodelc"), configuration: options)
        }
        synthesizer = try MossTtsNanoSynthesizer(
            prefill: load(0), step: load(1), frame: load(2), codecStep: load(3), config: config, tokenizer: tokenizer)
    }

    /// The callback runs serially on this actor; failure stops inference before another graph call.
    public func synthesize(
        text: String, chineseVoice: Bool, seed: UInt64? = nil,
        emit: @Sendable ([Float], [Float]) throws -> Void
    ) throws {
        try Task.checkCancellation()
        let voice = chineseVoice ? chinese : english
        let options = MossTtsNanoSamplingOptions(seed: seed)
        let chunks = try synthesizer.planChunks(text: text, voice: voice, options: options)
        guard !chunks.isEmpty, chunks.count <= 32 else { throw MossTtsNanoError.emptyText }
        var rng = seed.map { MossTtsNanoRandom(seed: $0) } ?? MossTtsNanoRandom()
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let produced = try autoreleasepool {
                try synthesizer.generateChunk(
                    text: chunk, voice: voice, options: options, rng: &rng,
                    chunkIndex: index, chunkCount: chunks.count
                ) { frame in
                    try Task.checkCancellation()
                    try emit(frame.left, frame.right)
                }
            }
            guard produced > 0 else {
                throw MossTtsNanoError.inferenceFailed(stage: "generation", underlying: "No audio generated")
            }
            if index + 1 < chunks.count {
                let count = Int((MossTtsNanoTextChunker.pauseSeconds(after: chunk) * 48_000).rounded())
                let silence = [Float](repeating: 0, count: count)
                try emit(silence, silence)
            }
        }
    }
}

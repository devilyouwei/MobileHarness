@preconcurrency import CoreML
import FluidAudio
import Foundation

/// No high-level SDK manager: it owns global G2P caches and downloads on demand.
/// This backend admits only completely provisioned local resources before calling the SDK store.
public actor LocalKokoroEngine {
    public enum Language: Sendable { case english, mandarin }
    public enum Failure: Error {
        case missingResource(String)
        case incompatibleResource(String)
        case invalidPhonemes
    }

    private let english: KokoroAneModelStore
    private let mandarin: KokoroAneModelStore
    private let chineseFrontend: LocalMandarinFrontend

    public static func validateResources(at root: URL) throws {
        let base = root.appendingPathComponent("kokoro-82m-coreml")
        for variant in ["ANE", "ANE-zh"] {
            let folder = base.appendingPathComponent(variant)
            for bundle in ModelNames.KokoroAne.requiredCoreMLModels {
                for file in ["coremldata.bin", "model.mil", "weights/weight.bin", "analytics/coremldata.bin"] {
                    try require(folder.appendingPathComponent(bundle + "/" + file))
                }
                let mil = try Data(
                    contentsOf: folder.appendingPathComponent(bundle + "/model.mil"), options: .mappedIfSafe)
                guard mil.range(of: Data("[FlexibleShapeInformation =".utf8)) != nil else {
                    throw Failure.incompatibleResource(bundle)
                }
                guard
                    !FileManager.default.fileExists(
                        atPath: folder.appendingPathComponent(bundle + ".pre-flexible-shape-migration").path)
                else {
                    throw Failure.incompatibleResource(bundle)
                }
            }
            try require(folder.appendingPathComponent("vocab.json"))
        }
        for file in [
            "ANE/af_heart.bin", "ANE-zh/voices/zf_001.bin", "us_lexicon_cache.json",
            "ANE-zh/assets/pinyin_phrases.bin", "ANE-zh/assets/pinyin_single.bin",
            "ANE-zh/assets/jieba_hmm_start.bin", "ANE-zh/assets/jieba_hmm_trans.bin",
            "ANE-zh/assets/jieba_hmm_emit.bin",
            "ANE-zh/g2pw/vocab.txt", "ANE-zh/g2pw/POLYPHONIC_CHARS.txt",
        ] {
            try require(base.appendingPathComponent(file))
        }
        for file in ["coremldata.bin", "model.mil", "weights/weight.bin", "analytics/coremldata.bin"] {
            try require(base.appendingPathComponent("ANE-zh/g2pw/g2pw.mlmodelc/" + file))
        }
    }

    private static func require(_ url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, let size = values?.fileSize, size > 0 else {
            throw Failure.missingResource(url.lastPathComponent)
        }
    }

    public init(root: URL) async throws {
        try Self.validateResources(at: root)
        let base = root.appendingPathComponent("kokoro-82m-coreml/ANE-zh")
        chineseFrontend = try LocalMandarinFrontend(base: base)
        english = KokoroAneModelStore(directory: root, computeUnits: .aneTailCpu, variant: .english)
        mandarin = KokoroAneModelStore(directory: root, computeUnits: .aneTailCpu, variant: .mandarin)
        // Both stores are owned by the enclosing ModelResource; no process-global loaded models.
        try await english.loadIfNeeded()
        try Task.checkCancellation()
        try await mandarin.loadIfNeeded()
    }

    public func mandarinPhonemes(_ text: String) async throws -> String {
        try await chineseFrontend.phonemize(text)
    }

    public func synthesize(phonemes: String, language: Language) async throws -> [Float] {
        try Task.checkCancellation()
        let store = language == .english ? english : mandarin
        let vocab = try await store.vocabulary()
        // The SDK encoder drops unknown symbols; reject them here instead of losing speech silently.
        guard !phonemes.isEmpty, phonemes.unicodeScalars.allSatisfy({ vocab.map[Character($0)] != nil }) else {
            throw Failure.invalidPhonemes
        }
        let ids = try vocab.encode(phonemes)
        let voice = language == .english ? "af_heart" : "zf_001"
        let pack = try await store.voicePack(voice)
        let styles = pack.slice(for: KokoroAneVocab.phonemeLength(phonemes))
        let result = try await KokoroAneSynthesizer.synthesize(
            inputIds: ids, styleS: styles.styleS, styleTimbre: styles.styleTimbre, store: store)
        try Task.checkCancellation()
        return result.samples
    }
}

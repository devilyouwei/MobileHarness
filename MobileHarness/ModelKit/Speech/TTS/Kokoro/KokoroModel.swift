import Foundation
import ModelKit

/// Context-owned Core ML engine and local English/Mandarin frontends.
actor KokoroModel {
    private let engine: LocalKokoroEngine
    private let english: KokoroG2P
    private let britishLexicon: URL
    private var british: KokoroG2P?

    init(artifacts: URL) async throws {
        let repository = artifacts.appendingPathComponent("kokoro-82m-coreml")
        english = try KokoroG2P(cacheURL: repository.appendingPathComponent("us_lexicon_cache.json"))
        britishLexicon = repository.appendingPathComponent("gb_lexicon_cache.json")
        engine = try await LocalKokoroEngine(root: artifacts)
    }

    func synthesizeChunks(
        _ segments: [KokoroInput.Segment], preferredVoice: String?, emit: @Sendable ([Float]) async throws -> Void
    )
        async throws
    {
        for segment in segments {
            try Task.checkCancellation()
            let voice = KokoroVoiceCatalog.voice(for: segment.language, preferred: preferredVoice)
            let phonemes: String
            if segment.language == .english {
                phonemes = try englishFrontend(for: voice).phonemize(segment.text)
            } else {
                phonemes = try await engine.mandarinPhonemes(segment.text)
            }
            guard phonemes.unicodeScalars.count <= 510 else {
                throw CapabilityError.invalidRequest("Kokoro phoneme limit exceeded; use shorter text")
            }
            let chunk = try await engine.synthesize(
                phonemes: phonemes, language: segment.language == .english ? .english : .mandarin, voice: voice)
            guard !chunk.isEmpty, chunk.allSatisfy(\.isFinite) else {
                throw CapabilityError.invalidRequest("Invalid Kokoro waveform")
            }
            try await emit(chunk)
        }
    }

    private func englishFrontend(for voice: String) throws -> KokoroG2P {
        guard voice.hasPrefix("b") else { return english }
        if let british { return british }
        let frontend = try KokoroG2P(cacheURL: britishLexicon)
        british = frontend
        return frontend
    }
}

import Foundation
import ModelKit
import ModelKitFluidAudio

/// Context-owned Core ML engine and local English/Mandarin frontends.
actor KokoroModel {
    private let engine: LocalKokoroEngine
    private let english: KokoroG2P

    init(artifacts: URL) async throws {
        english = try KokoroG2P(cacheURL: artifacts.appendingPathComponent("kokoro-82m-coreml/us_lexicon_cache.json"))
        engine = try await LocalKokoroEngine(root: artifacts)
    }

    func synthesizeChunks(_ segments: [KokoroInput.Segment], emit: @Sendable ([Float]) async throws -> Void)
        async throws
    {
        for segment in segments {
            try Task.checkCancellation()
            let phonemes: String
            if segment.language == .english {
                phonemes = english.phonemize(segment.text)
            } else {
                phonemes = try await engine.mandarinPhonemes(segment.text)
            }
            guard phonemes.unicodeScalars.count <= 510 else {
                throw CapabilityError.invalidRequest("Kokoro phoneme limit exceeded; use shorter text")
            }
            let chunk = try await engine.synthesize(
                phonemes: phonemes, language: segment.language == .english ? .english : .mandarin)
            guard !chunk.isEmpty, chunk.allSatisfy(\.isFinite) else {
                throw CapabilityError.invalidRequest("Invalid Kokoro waveform")
            }
            try await emit(chunk)
        }
    }
}

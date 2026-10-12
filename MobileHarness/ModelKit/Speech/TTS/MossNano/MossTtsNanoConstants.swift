// Adapted from FluidInference/FluidAudio PR #917 @ abbde6b9b80c0e7c2c488f35b0b225c0e8cab08f.
// Apache-2.0; see docs/licenses/FluidAudio-Apache-2.0.txt. Local modifications documented in README.md.
import Foundation

/// Compile-time constants for the MOSS-TTS-Nano backend.
///
/// Geometry that is baked into the published CoreML graphs
/// (`FluidInference/moss-tts-nano-coreml`). Tokenizer-derived values (prompt
/// template ids, special token ids) are read from the repo's `config.json`
/// at load time instead — see `MossTtsNanoConfig`.
enum MossTtsNanoConstants {

    // MARK: - Audio

    /// Codec output rate. Native 48 kHz stereo.
    static let sampleRate: Int = 48_000
    static let channels: Int = 2
    /// One LM frame = 80 ms = 3840 samples per channel.
    static let samplesPerFramePerChannel: Int = 3840
    static let frameDuration: Double = 0.08

    // MARK: - Language model

    /// RVQ codebooks per frame (row width is `numCodebooks + 1`).
    static let numCodebooks: Int = 16
    static let rowWidth: Int = 17
    static let hiddenSize: Int = 768
    static let audioCodebookSize: Int = 1024
    /// Fixed prompt capacity of the published prefill graph.
    static let prefillRows: Int = 512
    /// KV-cache capacity of the published step graph (prompt + generated frames).
    static let maxLen: Int = 1024

    // MARK: - Generation defaults (upstream `inference()` defaults)

    static let defaultTextTemperature: Float = 1.5
    static let defaultAudioTemperature: Float = 1.7
    static let defaultAudioTopP: Float = 0.8
    static let defaultRepetitionPenalty: Float = 1.0
    static let defaultMaxNewFrames: Int = 375
    /// Sentence-chunk token budget for voice-clone synthesis
    /// (`DEFAULT_VOICE_CLONE_MAX_TEXT_TOKENS`).
    static let defaultMaxTextTokens: Int = 50
    /// Silence inserted between text chunks: short for ≤ 4-word chunks, long otherwise.
    static let interChunkPauseShort: Float = 0.40
    static let interChunkPauseLong: Float = 0.24
}

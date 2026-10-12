// Adapted from FluidInference/FluidAudio PR #917 @ abbde6b9b80c0e7c2c488f35b0b225c0e8cab08f.
// Apache-2.0; see docs/licenses/FluidAudio-Apache-2.0.txt. Local modifications documented in README.md.
import Foundation

/// Mirror of `config.json` in `FluidInference/moss-tts-nano-coreml`.
///
/// Carries everything the Swift host needs that is derived from the upstream
/// tokenizer / model config rather than baked into the CoreML graphs: special
/// token ids, pre-tokenized prompt template segments, sampling defaults.
struct MossTtsNanoConfig: Codable, Sendable {

    struct Model: Codable, Sendable {
        let nVq: Int
        let rowWidth: Int
        let hiddenSize: Int
        let audioCodebookSize: Int
        let sampleRate: Int
        let channels: Int
        let samplesPerFramePerChannel: Int
    }

    struct CoreML: Codable, Sendable {
        let prefillRows: Int
        let maxLen: Int
    }

    struct Tokens: Codable, Sendable {
        let pad: Int
        let imStart: Int
        let imEnd: Int
        let audioStart: Int
        let audioEnd: Int
        let audioUserSlot: Int
        let audioAssistantSlot: Int
        let audioPad: Int
    }

    /// Pre-tokenized template segments (upstream `prompting.py`).
    struct Prompt: Codable, Sendable {
        /// `<im_start> user … Reference(s): <audio_start>`
        let voiceClonePrefix: [Int]
        /// `<audio_end> … Text:` — sits between the reference rows and the text ids.
        let voiceCloneAfterReference: [Int]
        /// `</user_inst> <im_end> <im_start> assistant <audio_start>`
        let assistantSuffix: [Int]
        /// Plain (no reference) prompt prefix; kept for completeness.
        let plainPrefix: [Int]
    }

    struct SamplingDefaults: Codable, Sendable {
        let textTemperature: Float
        let textTopK: Int
        let textTopP: Float
        let audioTemperature: Float
        let audioTopK: Int
        let audioTopP: Float
        let audioRepetitionPenalty: Float
        let maxNewFrames: Int
    }

    struct Text: Codable, Sendable {
        let voiceCloneMaxTextTokens: Int
    }

    let model: Model
    let coreml: CoreML
    let tokens: Tokens
    let prompt: Prompt
    let samplingDefaults: SamplingDefaults
    let text: Text

    static func load(from url: URL) throws -> MossTtsNanoConfig {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(MossTtsNanoConfig.self, from: data)
    }
}

/// A voice-clone reference: the codec tokens of a short speech clip.
///
/// `codes` is `[frames][16]` (12.5 Hz frames × RVQ codebooks). Built-in voices
/// ship as `voices/<name>.json` in the HF repo; custom voices come from
/// `MossTtsNanoManager.cloneVoice(audioURL:)`.
struct MossTtsNanoVoice: Codable, Sendable, Equatable {
    let name: String
    let sampleRate: Int
    let frames: Int
    let codes: [[Int32]]

    init(name: String, codes: [[Int32]], sampleRate: Int = MossTtsNanoConstants.sampleRate) {
        self.name = name
        self.sampleRate = sampleRate
        self.frames = codes.count
        self.codes = codes
    }

    static func load(from url: URL) throws -> MossTtsNanoVoice {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let voice = try decoder.decode(MossTtsNanoVoice.self, from: data)
            try voice.validate()
            return voice
        } catch let error as MossTtsNanoError {
            throw error
        } catch {
            throw MossTtsNanoError.voiceLoadFailed(path: url.path, underlying: "\(error)")
        }
    }

    func validate() throws {
        guard !codes.isEmpty, frames == codes.count, frames <= 400, sampleRate == 48_000 else {
            throw MossTtsNanoError.invalidVoice("Invalid reference dimensions")
        }
        for (i, row) in codes.enumerated() {
            guard row.count == MossTtsNanoConstants.numCodebooks else {
                throw MossTtsNanoError.invalidVoice(
                    "frame \(i) has \(row.count) codes, expected \(MossTtsNanoConstants.numCodebooks)")
            }
            guard row.allSatisfy({ $0 >= 0 && $0 < Int32(MossTtsNanoConstants.audioCodebookSize) }) else {
                throw MossTtsNanoError.invalidVoice("frame \(i) has a code outside 0..<1024")
            }
        }
    }
}

/// Sampling controls. Defaults mirror upstream `inference()`.
struct MossTtsNanoSamplingOptions: Sendable, Equatable {
    var textTemperature: Float
    var audioTemperature: Float
    var audioTopP: Float
    var repetitionPenalty: Float
    /// Argmax decoding. Deterministic, but upstream greedy decoding never emits the
    /// stop token and runs to `maxNewFrames`; it exists for parity testing only.
    var greedy: Bool
    var maxNewFrames: Int
    /// Seed for the host-side uniform draws that feed the in-graph sampler. `nil`
    /// draws from the system RNG.
    var seed: UInt64?
    /// Token budget per text chunk; `0` disables chunking.
    var maxTextTokens: Int

    init(
        textTemperature: Float = MossTtsNanoConstants.defaultTextTemperature,
        audioTemperature: Float = MossTtsNanoConstants.defaultAudioTemperature,
        audioTopP: Float = MossTtsNanoConstants.defaultAudioTopP,
        repetitionPenalty: Float = MossTtsNanoConstants.defaultRepetitionPenalty,
        greedy: Bool = false,
        maxNewFrames: Int = MossTtsNanoConstants.defaultMaxNewFrames,
        seed: UInt64? = nil,
        maxTextTokens: Int = MossTtsNanoConstants.defaultMaxTextTokens
    ) {
        self.textTemperature = textTemperature
        self.audioTemperature = audioTemperature
        self.audioTopP = audioTopP
        self.repetitionPenalty = repetitionPenalty
        self.greedy = greedy
        self.maxNewFrames = maxNewFrames
        self.seed = seed
        self.maxTextTokens = maxTextTokens
    }

    static let `default` = MossTtsNanoSamplingOptions()
}

/// One decoded 80 ms frame (3840 samples per channel at 48 kHz).
struct MossTtsNanoAudioFrame: Sendable {
    let left: [Float]
    let right: [Float]
    /// Zero-based frame index within the current text chunk.
    let frameIndex: Int
    /// Zero-based text chunk index and total chunk count for the utterance.
    let chunkIndex: Int
    let chunkCount: Int
    /// Silence frame inserted between chunks (not model output).
    let isPause: Bool
    var sampleRate: Int { MossTtsNanoConstants.sampleRate }
}

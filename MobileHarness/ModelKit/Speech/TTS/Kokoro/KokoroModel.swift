// Adapted from john-rocky/coreai-kit @ 7d5403e6e5d75a6f204814e56bbe342034744746.
// Copyright (c) 2026 Daisuke Majima. BSD-3-Clause; see docs/licenses/CoreAIKit-BSD-3-Clause.txt.
#if canImport(CoreAI)
    // KokoroTTS.swift — Kokoro-82M (StyleTTS2 + iSTFTNet) text-to-speech on Core AI.
    //
    // Drives the three exported bundles (predictor / prosody / vocoder) through CoreAIKitVision's
    // GraphModel on the CPU compute unit (the unrolled bi-LSTMs are ~8 ms on the Core AI CPU vs
    // dispatch-bound on the GPU), with the host steps in Swift:
    //
    //   text -> (KokoroG2P) -> phoneme ids
    //     predictor : ids, ref_s, attn_mask -> duration, d, t_en
    //     host      : pred_dur = round(duration); one-hot alignment; frame mask
    //     prosody   : d, t_en, aln, ref_s, frame_mask -> asr, f0, N
    //     host      : har = STFT(SineGen(f0_upsamp(f0)))   — the hn-nsf source
    //     vocoder   : asr, f0, N, har, ref_s, frame_mask -> audio
    //     host      : trim to the real frames
    //
    // The host DSP (alignment + compute_har) mirrors conversion/export_kokoro.py exactly; the
    // engine-vs-torch gate is spectral corr 0.999 (see the model card). The voice is data — a
    // `ref_s` style row indexed by utterance length from a downloaded voice pack.

    import ModelKitCoreAI
    import ModelKit
    import Foundation

    /// Kokoro-82M text-to-speech: non-autoregressive, 24 kHz, English-first.
    @available(iOS 27, macOS 27, *)
    final class KokoroModel: Sendable {
        public static let sampleRate = 24000

        static let tokenBucket = 128  // token bucket
        static let frameBucket = 512  // frame bucket
        static let upsample = 300  // f0 upsample (prod(upsample_rates)*hop)
        static let fftSize = 20, hop = 5, frequencies = 11, harmonics = 9
        static let sampleRateFloat: Float = 24000

        private let predictor: GraphModel
        private let prosody: GraphModel
        private let vocoder: GraphModel
        private let vocab: [String: Int]
        private let llW: [Float]  // l_linear weight[9] + bias[1]
        private let voices: [String: [Float]]  // name -> [N*256] style pack
        private let g2p: KokoroG2P

        // STFT DFT basis (cos/sin * periodic Hann), built once.
        private let basisR: [Float]  // [frequencies*fftSize]
        private let basisI: [Float]

        /// Loads the three graph bundles plus the host glue (vocab, l_linear, lexicons, voices).
        /// `glueDir` is the repo's `kokoro_host_glue/` subtree.
        public init(
            predictorAt predictorURL: URL, prosodyAt prosodyURL: URL, vocoderAt vocoderURL: URL,
            glueDir: URL
        ) async throws {
            predictor = try await GraphModel(contentsOf: predictorURL, computeUnits: .cpuOnly)
            prosody = try await GraphModel(contentsOf: prosodyURL, computeUnits: .cpuOnly)
            vocoder = try await GraphModel(contentsOf: vocoderURL, computeUnits: .cpuOnly)

            let vocabData = try Data(contentsOf: glueDir.appendingPathComponent("vocab.json"))
            vocab = try JSONDecoder().decode([String: Int].self, from: vocabData)
            llW = try Self.readFloats(glueDir.appendingPathComponent("l_linear.bin"))
            g2p = try KokoroG2P(
                goldURL: glueDir.appendingPathComponent("us_gold.json"),
                silverURL: glueDir.appendingPathComponent("us_silver.json"))

            let voicesDir = glueDir.appendingPathComponent("voices")
            var voices: [String: [Float]] = [:]
            for file in try FileManager.default.contentsOfDirectory(
                at: voicesDir, includingPropertiesForKeys: nil)
            where file.pathExtension == "bin" {
                voices[file.deletingPathExtension().lastPathComponent] = try Self.readFloats(file)
            }
            guard llW.count == 10, !voices.isEmpty, voices.values.allSatisfy({ $0.count >= Self.tokenBucket * 256 })
            else {
                throw CapabilityError.invalidRequest("Invalid Kokoro style/DSP data")
            }
            self.voices = voices

            var basisR = [Float]()
            var basisI = [Float]()
            basisR.reserveCapacity(Self.frequencies * Self.fftSize)
            basisI.reserveCapacity(Self.frequencies * Self.fftSize)
            for k in 0..<Self.frequencies {
                for n in 0..<Self.fftSize {
                    let hann = 0.5 - 0.5 * cos(2 * Float.pi * Float(n) / Float(Self.fftSize))
                    let a = 2 * Float.pi * Float(k) * Float(n) / Float(Self.fftSize)
                    basisR.append(cos(a) * hann)
                    basisI.append(-sin(a) * hann)
                }
            }
            self.basisR = basisR
            self.basisI = basisI
        }

        /// The downloaded voice packs, e.g. `["af_heart", "af_bella", …]`.
        public var availableVoices: [String] { voices.keys.sorted() }

        func synthesizeChunks(_ text: String, emit: @Sendable ([Float]) async throws -> Void) async throws {
            let chunks = try KokoroInput.chunks(text) { self.ids(forText: $0).count }
            for sentence in chunks {
                try Task.checkCancellation()
                let ids = ids(forText: sentence)
                guard ids.count > 2 else { throw CapabilityError.invalidRequest("No Kokoro phonemes") }
                let chunk = try await synthesize(ids: ids, voice: "af_heart")
                try Task.checkCancellation()
                try await emit(chunk)
            }
        }

        /// Phonemes for a chunk -> Kokoro token ids (incl. the [0, …, 0] bounds).
        func ids(forText text: String) -> [Int] {
            let phonemes = g2p.phonemize(text)
            return [0] + phonemes.compactMap { vocab[String($0)] } + [0]
        }

        /// Synthesize from already-tokenized phoneme ids (incl. the [0, …, 0] bounds).
        func synthesize(ids rawIds: [Int], voice: String) async throws -> [Float] {
            let tokenCount = rawIds.count
            guard tokenCount >= 2, tokenCount <= Self.tokenBucket else { throw KokoroError.tooLong(tokenCount) }
            guard let pack = voices[voice] else { throw KokoroError.noVoice(voice) }
            let refS = Array(pack[(tokenCount - 1) * 256..<tokenCount * 256])  // ref_s = pack[len-1]

            // pad ids to the token bucket
            let ids = rawIds.map { Int32($0) } + [Int32](repeating: 0, count: Self.tokenBucket - tokenCount)
            let attn =
                [Float](repeating: 1, count: tokenCount) + [Float](repeating: 0, count: Self.tokenBucket - tokenCount)

            let o1 = try await predictor.run([
                "input_ids": .int32(ids, shape: [1, Self.tokenBucket]),
                "ref_s": .float32(refS, shape: [1, 256]),
                "attn_mask": .float32(attn, shape: [1, Self.tokenBucket]),
            ])
            guard let durationTensor = o1["duration"], let d = o1["d"], let tEn = o1["t_en"] else {
                throw CapabilityError.invalidRequest("Missing predictor outputs")
            }
            let duration = durationTensor.floats()
            guard duration.count >= tokenCount else { throw CapabilityError.invalidRequest("Invalid duration shape") }

            let (aln, frameMask, frameCount) = try KokoroInput.alignment(duration: Array(duration[0..<tokenCount]))

            let o2 = try await prosody.run([
                "d": d, "t_en": tEn,
                "aln": .float32(aln, shape: [1, Self.tokenBucket, Self.frameBucket]),
                "ref_s": .float32(refS, shape: [1, 256]),
                "frame_mask": .float32(frameMask, shape: [1, Self.frameBucket]),
            ])
            guard let f0Tensor = o2["F0"], let asr = o2["asr"], let noise = o2["N"] else {
                throw CapabilityError.invalidRequest("Missing prosody outputs")
            }
            let f0 = f0Tensor.floats()
            guard f0.count == 2 * Self.frameBucket, f0.allSatisfy({ $0.isFinite }) else {
                throw CapabilityError.invalidRequest("Invalid f0 output")
            }
            let (har, frames) = try computeHar(f0: f0)

            let o3 = try await vocoder.run([
                "asr": asr, "F0": f0Tensor, "N": noise,
                "har": .float32(har, shape: [1, 2 * Self.frequencies, frames]),
                "ref_s": .float32(refS, shape: [1, 256]),
                "frame_mask": .float32(frameMask, shape: [1, Self.frameBucket]),
            ])
            guard let audioTensor = o3["audio"] else { throw CapabilityError.invalidRequest("Missing waveform") }
            let audio = audioTensor.floats()
            guard audio.count >= frameCount * 600, audio.allSatisfy({ $0.isFinite }) else {
                throw CapabilityError.invalidRequest("Invalid waveform")
            }
            return Array(audio[0..<frameCount * 600])  // trim to real frames
        }

        // host step 2: hn-nsf source -> STFT (mag, phase). Mirrors compute_har.
        private func computeHar(f0: [Float]) throws -> ([Float], Int) {
            let twoL = f0.count  // 2*frameBucket
            let bigL = twoL * Self.upsample
            // f0_upsamp: repeat each value upsample times (nearest)
            // SineGen per harmonic: rad -> downsample(1/upsample) -> cumsum -> upsample(upsample) -> sin
            var harSource = [Float](repeating: 0, count: bigL)
            var radDS = [Float](repeating: 0, count: twoL)
            var phase = [Float](repeating: 0, count: twoL)
            for h in 1...Self.harmonics {
                try Task.checkCancellation()
                // rad on the bigL grid is f0_up*h/sampleRateFloat; its 1/upsample downsample averages each
                // block of upsample constant samples -> ~= f0[j]*h/sampleRateFloat (linear interp of a step).
                for j in 0..<twoL { radDS[j] = f0[j] * Float(h) / Self.sampleRateFloat }
                // cumsum * 2pi
                var acc: Float = 0
                for j in 0..<twoL {
                    acc += radDS[j]
                    phase[j] = acc * 2 * Float.pi
                }
                // upsample (linear, align_corners=false) of phase*upsample back to bigL, then sin
                let weight = llW[h - 1]
                for i in 0..<bigL {
                    let s = max(0, min(Float(twoL - 1), (Float(i) + 0.5) * Float(twoL) / Float(bigL) - 0.5))
                    let lo = Int(s.rounded(.down))
                    let hi = min(lo + 1, twoL - 1)
                    let fr = s - Float(lo)
                    let ph = (phase[lo] * (1 - fr) + phase[hi] * fr) * Float(Self.upsample)
                    let f0u = f0[min(twoL - 1, i / Self.upsample)]  // f0_upsamp value
                    let uv: Float = f0u > 10 ? 1 : 0
                    harSource[i] += sin(ph) * 0.1 * uv * weight  // sine_amp * uv * l_linear[h-1]
                }
            }
            // l_linear bias + tanh
            let bias = llW[Self.harmonics]
            for i in 0..<bigL { harSource[i] = tanh(harSource[i] + bias) }

            // STFT: replicate pad n_fft/2, stride hop, DFT basis -> mag, phase
            let pad = Self.fftSize / 2
            let total = bigL + 2 * pad
            let frames = (total - Self.fftSize) / Self.hop + 1
            var har = [Float](repeating: 0, count: 2 * Self.frequencies * frames)
            func sample(_ idx: Int) -> Float {  // replicate (edge) pad
                if idx < pad { return harSource[0] }
                if idx >= pad + bigL { return harSource[bigL - 1] }
                return harSource[idx - pad]
            }
            for fi in 0..<frames {
                if fi % 256 == 0 { try Task.checkCancellation() }
                let base = fi * Self.hop
                for k in 0..<Self.frequencies {
                    var re: Float = 0
                    var im: Float = 0
                    let bk = k * Self.fftSize
                    for n in 0..<Self.fftSize {
                        let v = sample(base + n)
                        re += basisR[bk + n] * v
                        im += basisI[bk + n] * v
                    }
                    let mag = (re * re + im * im + 1e-14).squareRoot()
                    har[k * frames + fi] = mag
                    har[(Self.frequencies + k) * frames + fi] = atan2(im, re)
                }
            }
            return (har, frames)
        }

        private static func readFloats(_ url: URL) throws -> [Float] {
            let d = try Data(contentsOf: url)
            guard !d.isEmpty, d.count % 4 == 0 else { throw CapabilityError.invalidRequest("Invalid float data") }
            let values = d.withUnsafeBytes { bytes in
                (0..<(d.count / 4)).map {
                    Float(
                        bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)))
                }
            }
            guard values.allSatisfy({ $0.isFinite }) else {
                throw CapabilityError.invalidRequest("Nonfinite float data")
            }
            return values
        }

        /// Kokoro synthesis errors.
        public enum KokoroError: Error {
            /// One sentence phonemized past the 128-token bucket — split the text shorter.
            case tooLong(Int)
            /// The requested voice pack is not among the downloaded `voices/*.bin`.
            case noVoice(String)
        }
    }

#endif

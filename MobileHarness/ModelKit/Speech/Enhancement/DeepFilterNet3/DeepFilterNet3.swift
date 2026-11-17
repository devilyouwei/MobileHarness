// Pipeline adapted from soniqo/speech-swift (Apache-2.0), Copyright 2025 Ivan Digital.
// Modified: managed actor/lease lifecycle, bounded PCM contract, shared CoreMLGraph backend.
// Source b1287a6c963a38b0d4133c656725b2de7ea6bebf; see docs/licenses/Speech-Swift-Apache-2.0.txt.
import Foundation
import ModelKit
import ModelKitCoreML

public actor DeepFilterNet3: SpeechEnhancementCapability {
    private let root: URL
    private let resource: ModelResource<DeepFilterEngine>
    private var busy = false
    public init(context: ModelContext, artifacts: URL) throws {
        root = artifacts
        resource = try context.resource { try await DeepFilterEngine(root: artifacts) }
    }
    public var availability: CapabilityAvailability {
        ["DeepFilterNet3.mlmodelc/model.mil", "DeepFilterNet3.mlmodelc/weights/weight.bin", "auxiliary.npz"]
            .allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
            ? .available : .unavailable(reason: "DeepFilterNet3 artifacts are not installed")
    }
    public func enhance(_ audio: AudioFrame) async throws -> AudioFrame {
        guard audio.format.sampleRate == 48000, audio.format.channels == 1,
            audio.format.encoding == .float32, audio.sampleCount <= 240000
        else {
            throw CapabilityError.invalidRequest("Enhancement requires up to five seconds of 48 kHz mono Float32")
        }
        let samples = audio.data.withUnsafeBytes { bytes in
            (0..<audio.sampleCount).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
        guard samples.allSatisfy(\.isFinite) else { throw CapabilityError.invalidRequest("Nonfinite PCM") }
        try Task.checkCancellation()
        guard !busy else { throw CapabilityError.inputBusy }
        busy = true
        defer { busy = false }
        let lease = try await resource.acquire()
        let task = Task { try await lease.model.enhance(samples) }
        await resource.setCancellation(lease.id) { task.cancel() }
        do {
            let result = try await withTaskCancellationHandler {
                let output = try await task.value
                try Task.checkCancellation()
                return output
            } onCancel: {
                task.cancel()
            }
            await resource.release(lease.id)
            return try AudioFrame(
                data: result.withUnsafeBytes { Data($0) }, format: audio.format,
                sequence: audio.sequence, timestamp: audio.timestamp)
        } catch {
            await resource.release(lease.id)
            throw error
        }
    }
}

private actor DeepFilterEngine {
    private let graph: CoreMLGraph
    private let auxiliary: DeepFilterAuxiliary
    init(root: URL) async throws {
        auxiliary = try DeepFilterAuxiliary(url: root.appendingPathComponent("auxiliary.npz"))
        graph = try await CoreMLGraph(contentsOf: root.appendingPathComponent("DeepFilterNet3.mlmodelc"))
    }
    func enhance(_ samples: [Float]) async throws -> [Float] {
        try Task.checkCancellation()
        let a = auxiliary.arrays
        let stft = try STFTProcessor(fftSize: 960, hopSize: 480, window: a["window"]!)
        var analysis = [Float](repeating: 0, count: 480)
        var synthesis = analysis
        let (real, imag) = stft.forward(
            audio: samples + [Float](repeating: 0, count: max(960, 1440 - samples.count)), analysisMem: &analysis)
        let frames = real.count / 481
        var erb = computeERBFeatures(
            real: real, imag: imag, erbFb: a["erb_fb"]!, freqBins: 481, erbBands: 32, numFrames: frames)
        var mean = a["mean_norm_state"]!
        var unit = a["unit_norm_state"]!
        applyMeanNormalization(&erb, state: &mean, alpha: 0.99, erbBands: 32, numFrames: frames)
        var sr = [Float]()
        var si = [Float]()
        for t in 0..<frames {
            sr.append(contentsOf: real[t * 481..<t * 481 + 96])
            si.append(contentsOf: imag[t * 481..<t * 481 + 96])
        }
        applyUnitNormalization(real: &sr, imag: &si, state: &unit, alpha: 0.99, dfBins: 96, numFrames: frames)
        try Task.checkCancellation()
        let output = try await graph.run([
            "feat_erb": CoreMLTensor(shape: [1, 1, frames, 32], values: erb),
            "feat_spec": CoreMLTensor(shape: [1, 2, frames, 96], values: sr + si),
        ])
        guard let mask = output["erb_mask"], mask.shape == [1, 1, frames, 32],
            let coefficients = output["df_coefs"], coefficients.shape == [1, 5, frames, 96, 2]
        else {
            throw CapabilityError.invalidRequest("Unexpected DeepFilterNet3 output shape")
        }
        var coefs = [Float](repeating: 0, count: coefficients.values.count)
        for t in 0..<frames {
            for f in 0..<96 {
                for o in 0..<5 {
                    let src = ((o * frames + t) * 96 + f) * 2
                    let dst = ((t * 96 + f) * 5 + o) * 2
                    coefs[dst] = coefficients.values[src]
                    coefs[dst + 1] = coefficients.values[src + 1]
                }
            }
        }
        var enhancedReal = real
        var enhancedImag = imag
        applyERBMask(
            specReal: &enhancedReal, specImag: &enhancedImag, erbMask: mask.values,
            erbInvFb: a["erb_inv_fb"]!, erbBands: 32, freqBins: 481, numFrames: frames)
        let filtered = applyDeepFiltering(
            specReal: real, specImag: imag, coefs: coefs,
            dfBins: 96, dfOrder: 5, dfLookahead: 2, numFrames: frames, freqBins: 481)
        for t in 0..<frames {
            for f in 0..<96 {
                enhancedReal[t * 481 + f] = filtered.real[t * 96 + f]
                enhancedImag[t * 481 + f] = filtered.imag[t * 96 + f]
            }
        }
        let pcm = stft.inverse(real: enhancedReal, imag: enhancedImag, synthesisMem: &synthesis)
        try Task.checkCancellation()
        let result = Array(pcm[480..<480 + samples.count])
        guard result.allSatisfy(\.isFinite) else { throw CapabilityError.invalidRequest("Nonfinite enhanced PCM") }
        return result
    }
}

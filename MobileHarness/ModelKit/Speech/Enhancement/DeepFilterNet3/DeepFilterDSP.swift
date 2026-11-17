import Accelerate
// Adapted from soniqo/speech-swift (Apache-2.0), Copyright 2025 Ivan Digital.
// Modified for ModelKit: bounded batch DSP, throwing setup; no MLX dependency.
// Source b1287a6c963a38b0d4133c656725b2de7ea6bebf; see docs/licenses/Speech-Swift-Apache-2.0.txt.
import Foundation
import ModelKit

// MARK: - STFT / iSTFT

/// Forward/inverse STFT using vDSP_DFT (supports non-power-of-2 sizes like 960).
///
/// Uses `vDSP_DFT_zop` for complex-to-complex DFT, handling real signals by
/// setting imaginary input to zero and exploiting conjugate symmetry.
/// This avoids zero-padding to the next power of 2 (1024), which would produce
/// different frequency bin values than the native 960-point DFT that
/// DeepFilterNet3 expects.
final class STFTProcessor {
    let fftSize: Int
    let hopSize: Int
    let freqBins: Int
    let window: [Float]
    let forwardSetup: OpaquePointer
    let inverseSetup: OpaquePointer
    /// libdf normalizes the analysis DFT by 1/fftSize.
    let analysisScale: Float

    init(fftSize: Int, hopSize: Int, window: [Float]) throws {
        self.fftSize = fftSize
        self.hopSize = hopSize
        self.window = window
        self.freqBins = fftSize / 2 + 1  // 481 for 960-point DFT
        self.analysisScale = 1.0 / Float(fftSize)

        guard let fwd = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD) else {
            throw CapabilityError.unavailable("Cannot create forward DFT")
        }
        self.forwardSetup = fwd

        guard let inv = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .INVERSE) else {
            vDSP_DFT_DestroySetup(fwd)
            throw CapabilityError.unavailable("Cannot create inverse DFT")
        }
        self.inverseSetup = inv
    }

    deinit {
        vDSP_DFT_DestroySetup(forwardSetup)
        vDSP_DFT_DestroySetup(inverseSetup)
    }

    /// Analysis STFT: audio → complex spectrum.
    ///
    /// Returns (real, imaginary) arrays each of shape [numFrames * freqBins].
    func forward(audio: [Float], analysisMem: inout [Float]) -> (real: [Float], imag: [Float]) {
        let overlapSize = fftSize - hopSize
        let buffer = analysisMem + audio

        let numFrames = max(0, (buffer.count - fftSize) / hopSize + 1)
        guard numFrames > 0 else {
            analysisMem = Array(buffer.suffix(overlapSize))
            return ([], [])
        }

        var real = [Float](repeating: 0, count: numFrames * freqBins)
        var imag = [Float](repeating: 0, count: numFrames * freqBins)

        var windowedFrame = [Float](repeating: 0, count: fftSize)
        var zeroImag = [Float](repeating: 0, count: fftSize)
        var outReal = [Float](repeating: 0, count: fftSize)
        var outImag = [Float](repeating: 0, count: fftSize)

        for frame in 0..<numFrames {
            let start = frame * hopSize

            // Apply window
            buffer.withUnsafeBufferPointer { buf in
                vDSP_vmul(buf.baseAddress! + start, 1, window, 1, &windowedFrame, 1, vDSP_Length(fftSize))
            }

            // Zero imaginary input (real signal)
            vDSP_vclr(&zeroImag, 1, vDSP_Length(fftSize))

            // Complex DFT
            vDSP_DFT_Execute(
                forwardSetup,
                windowedFrame, zeroImag,
                &outReal, &outImag)

            // vDSP leaves both DFT directions unnormalized. libdf applies
            // 1/N during analysis and expects synthesis to remain unscaled.
            var scale = analysisScale
            vDSP_vsmul(outReal, 1, &scale, &outReal, 1, vDSP_Length(freqBins))
            vDSP_vsmul(outImag, 1, &scale, &outImag, 1, vDSP_Length(freqBins))

            // Copy first freqBins (481) unique bins (conjugate symmetry)
            let baseIdx = frame * freqBins
            for k in 0..<freqBins {
                real[baseIdx + k] = outReal[k]
                imag[baseIdx + k] = outImag[k]
            }
        }

        // Update analysis memory
        let consumed = numFrames * hopSize
        analysisMem = Array(buffer.suffix(buffer.count - consumed))
        if analysisMem.count > overlapSize {
            analysisMem = Array(analysisMem.suffix(overlapSize))
        } else if analysisMem.count < overlapSize {
            analysisMem = [Float](repeating: 0, count: overlapSize - analysisMem.count) + analysisMem
        }

        return (real, imag)
    }

    /// Inverse STFT: complex spectrum → audio via overlap-add.
    func inverse(real: [Float], imag: [Float], synthesisMem: inout [Float]) -> [Float] {
        let numFrames = real.count / freqBins
        guard numFrames > 0 else { return [] }

        let outputLen = numFrames * hopSize
        var output = [Float](repeating: 0, count: outputLen)

        var fullReal = [Float](repeating: 0, count: fftSize)
        var fullImag = [Float](repeating: 0, count: fftSize)
        var outReal = [Float](repeating: 0, count: fftSize)
        var outImag = [Float](repeating: 0, count: fftSize)

        for frame in 0..<numFrames {
            let baseIdx = frame * freqBins

            // Fill first freqBins (481) bins
            for k in 0..<freqBins {
                fullReal[k] = real[baseIdx + k]
                fullImag[k] = imag[baseIdx + k]
            }

            // Reconstruct conjugate symmetric part: X[N-k] = conj(X[k])
            for k in 1..<(fftSize / 2) {
                fullReal[fftSize - k] = fullReal[k]
                fullImag[fftSize - k] = -fullImag[k]
            }

            // Inverse DFT
            vDSP_DFT_Execute(
                inverseSetup,
                fullReal, fullImag,
                &outReal, &outImag)

            // Apply synthesis window
            var windowed = [Float](repeating: 0, count: fftSize)
            vDSP_vmul(outReal, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

            // Overlap-add with synthesis memory
            for i in 0..<min(fftSize, synthesisMem.count) {
                windowed[i] += synthesisMem[i]
            }

            // Copy hop-size samples to output
            let outStart = frame * hopSize
            for i in 0..<hopSize {
                if outStart + i < outputLen {
                    output[outStart + i] = windowed[i]
                }
            }

            // Update synthesis memory
            let overlapSize = fftSize - hopSize
            synthesisMem = Array(windowed[hopSize..<fftSize])
            if synthesisMem.count < overlapSize {
                synthesisMem.append(contentsOf: [Float](repeating: 0, count: overlapSize - synthesisMem.count))
            }
        }

        return output
    }
}

// MARK: - Feature Extraction

/// Compute ERB power features from complex spectrum.
///
/// - Parameters:
///   - real: Real parts [numFrames * freqBins]
///   - imag: Imaginary parts [numFrames * freqBins]
///   - erbFb: Forward ERB filterbank [freqBins, erbBands]
///   - freqBins: Number of frequency bins
///   - erbBands: Number of ERB bands
///   - numFrames: Number of time frames
/// - Returns: ERB features [numFrames * erbBands] in dB, not yet normalized
func computeERBFeatures(
    real: [Float], imag: [Float],
    erbFb: [Float],
    freqBins: Int, erbBands: Int, numFrames: Int
) -> [Float] {
    // Power spectrum: |X|^2
    var power = [Float](repeating: 0, count: numFrames * freqBins)
    for i in 0..<power.count {
        power[i] = real[i] * real[i] + imag[i] * imag[i]
    }

    // ERB compression: power[T, F] @ erbFb[F, B] → erb[T, B]
    var erb = [Float](repeating: 0, count: numFrames * erbBands)
    vDSP_mmul(
        power, 1, erbFb, 1, &erb, 1,
        vDSP_Length(numFrames), vDSP_Length(erbBands), vDSP_Length(freqBins))

    // Convert to dB: 10 * log10(erb + 1e-10)
    var count32 = Int32(erb.count)
    var epsilon: Float = 1e-10
    vDSP_vsadd(erb, 1, &epsilon, &erb, 1, vDSP_Length(erb.count))
    vvlog10f(&erb, erb, &count32)
    var scale: Float = 10.0
    vDSP_vsmul(erb, 1, &scale, &erb, 1, vDSP_Length(erb.count))

    return erb
}

/// Apply exponential mean normalization to ERB features.
///
/// For each ERB band: `state = x * (1 - alpha) + state * alpha; x_norm = (x - state) / 40`
///
/// - Parameters:
///   - erb: ERB features [numFrames * erbBands], modified in place
///   - state: Running mean state [erbBands], modified in place
///   - alpha: Exponential decay factor
///   - erbBands: Number of ERB bands
///   - numFrames: Number of time frames
func applyMeanNormalization(
    _ erb: inout [Float],
    state: inout [Float],
    alpha: Float,
    erbBands: Int,
    numFrames: Int
) {
    let oneMinusAlpha = 1.0 - alpha
    for t in 0..<numFrames {
        let baseIdx = t * erbBands
        for b in 0..<erbBands {
            let x = erb[baseIdx + b]
            state[b] = x * oneMinusAlpha + state[b] * alpha
            erb[baseIdx + b] = (x - state[b]) / 40.0
        }
    }
}

/// Apply exponential unit normalization to complex spec features.
///
/// For each frequency bin: `state = |x| * (1 - alpha) + state * alpha; x_norm = x / sqrt(state)`
///
/// - Parameters:
///   - real: Real parts [numFrames * dfBins], modified in place
///   - imag: Imaginary parts [numFrames * dfBins], modified in place
///   - state: Running magnitude state [dfBins], modified in place
///   - alpha: Exponential decay factor
///   - dfBins: Number of deep filtering bins
///   - numFrames: Number of time frames
func applyUnitNormalization(
    real: inout [Float], imag: inout [Float],
    state: inout [Float],
    alpha: Float,
    dfBins: Int,
    numFrames: Int
) {
    let oneMinusAlpha = 1.0 - alpha
    for t in 0..<numFrames {
        let baseIdx = t * dfBins
        for f in 0..<dfBins {
            let re = real[baseIdx + f]
            let im = imag[baseIdx + f]
            let mag = sqrt(re * re + im * im)
            state[f] = mag * oneMinusAlpha + state[f] * alpha
            let norm = sqrt(max(state[f], 1e-10))
            real[baseIdx + f] = re / norm
            imag[baseIdx + f] = im / norm
        }
    }
}

// MARK: - Deep Filtering

/// Apply deep filtering coefficients to the spectrum.
///
/// For each time `t` and frequency `f` (0..<dfBins):
/// ```
/// Y(t, f) = sum_{n=0}^{order-1} X(t + n - padBefore, f) * W(n, t, f)
/// ```
/// where multiplication is complex.
///
/// - Parameters:
///   - specReal: Full spectrum real [numFrames * freqBins]
///   - specImag: Full spectrum imag [numFrames * freqBins]
///   - coefs: Deep filter coefficients [numFrames * dfBins * dfOrder * 2] (real, imag interleaved per tap)
///   - dfBins: Number of frequency bins to filter
///   - dfOrder: Number of filter taps
///   - dfLookahead: Lookahead in frames
///   - numFrames: Number of time frames
///   - freqBins: Total frequency bins
/// - Returns: Filtered spectrum (real, imag) for the first dfBins, [numFrames * dfBins] each
func applyDeepFiltering(
    specReal: [Float], specImag: [Float],
    coefs: [Float],
    dfBins: Int, dfOrder: Int, dfLookahead: Int,
    numFrames: Int, freqBins: Int
) -> (real: [Float], imag: [Float]) {
    let padBefore = dfOrder - 1 - dfLookahead  // 5-1-2 = 2

    var outReal = [Float](repeating: 0, count: numFrames * dfBins)
    var outImag = [Float](repeating: 0, count: numFrames * dfBins)

    for t in 0..<numFrames {
        for f in 0..<dfBins {
            var sumRe: Float = 0
            var sumIm: Float = 0

            for n in 0..<dfOrder {
                let srcT = t + n - padBefore
                let coefIdx = (t * dfBins * dfOrder + f * dfOrder + n) * 2

                let wRe = coefs[coefIdx]
                let wIm = coefs[coefIdx + 1]

                // libdf pads the time axis with zeros before unfolding.
                // Out-of-range taps therefore contribute nothing; repeating
                // the edge frame changes the first/last filtered frames.
                guard srcT >= 0, srcT < numFrames else { continue }
                let srcIdx = srcT * freqBins + f

                let xRe = specReal[srcIdx]
                let xIm = specImag[srcIdx]

                // Complex multiply: (xRe + j*xIm) * (wRe + j*wIm)
                sumRe += xRe * wRe - xIm * wIm
                sumIm += xIm * wRe + xRe * wIm
            }

            let outIdx = t * dfBins + f
            outReal[outIdx] = sumRe
            outImag[outIdx] = sumIm
        }
    }

    return (outReal, outImag)
}

// MARK: - ERB Mask Application

/// Apply ERB mask to the full spectrum.
///
/// Expands the 32-band ERB mask to 481 frequency bins using the inverse filterbank,
/// then multiplies the spectrum by the mask.
///
/// - Parameters:
///   - specReal: Spectrum real [numFrames * freqBins], modified in place
///   - specImag: Spectrum imag [numFrames * freqBins], modified in place
///   - erbMask: ERB mask [numFrames * erbBands] (sigmoid output, 0..1)
///   - erbInvFb: Inverse ERB filterbank [erbBands, freqBins]
///   - erbBands: Number of ERB bands
///   - freqBins: Number of frequency bins
///   - numFrames: Number of time frames
func applyERBMask(
    specReal: inout [Float], specImag: inout [Float],
    erbMask: [Float],
    erbInvFb: [Float],
    erbBands: Int, freqBins: Int, numFrames: Int
) {
    // Expand mask: mask[T, B] @ invFb[B, F] → fullMask[T, F]
    var fullMask = [Float](repeating: 0, count: numFrames * freqBins)
    vDSP_mmul(
        erbMask, 1, erbInvFb, 1, &fullMask, 1,
        vDSP_Length(numFrames), vDSP_Length(freqBins), vDSP_Length(erbBands))

    // Apply mask to spectrum
    vDSP_vmul(specReal, 1, fullMask, 1, &specReal, 1, vDSP_Length(specReal.count))
    vDSP_vmul(specImag, 1, fullMask, 1, &specImag, 1, vDSP_Length(specImag.count))
}

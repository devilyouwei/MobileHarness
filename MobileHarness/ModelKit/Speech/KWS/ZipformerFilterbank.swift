import Accelerate
import Foundation
import ModelKit

/// Streaming Kaldi log-mel frontend. No right padding is supplied for live input.
final class ZipformerFilterbank {
    static let bins = 80
    private static let frameLength = 400
    private static let frameShift = 160
    private static let fftSize = 512
    private let fft: vDSP_DFT_Setup
    private let window = (0..<frameLength).map { index in
        pow(0.5 - 0.5 * cos(2 * Float.pi * Float(index) / Float(frameLength - 1)), 0.85)
    }
    private let filters: [[(Int, Float)]]
    private var samples: [Float] = []
    private var base = 0
    private var nextStart = -120

    init() throws {
        guard let fft = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.fftSize), .FORWARD) else {
            throw CapabilityError.unavailable("Unable to initialize the Zipformer FFT")
        }
        self.fft = fft
        let low = Self.mel(20)
        let width = (Self.mel(7600) - low) / Float(Self.bins + 1)
        filters = (0..<Self.bins).map { index in
            let left = low + Float(index) * width
            let center = left + width
            let right = center + width
            return (0..<(Self.fftSize / 2)).compactMap { bin in
                let frequency = Self.mel(Float(bin) * 16000 / Float(Self.fftSize))
                guard frequency > left, frequency < right else { return nil }
                return (bin, min((frequency - left) / width, (right - frequency) / width))
            }
        }
    }

    deinit { vDSP_DFT_DestroySetup(fft) }

    func accept(_ packet: [Float]) -> [[Float]] {
        samples.append(contentsOf: packet)
        let end = base + samples.count
        var frames: [[Float]] = []
        while nextStart + Self.frameLength <= end {
            let frame = (nextStart..<(nextStart + Self.frameLength)).map { index in
                samples[(index < 0 ? -index - 1 : index) - base]
            }
            frames.append(features(frame))
            nextStart += Self.frameShift
        }
        let consumed = max(0, nextStart - base)
        samples.removeFirst(consumed)
        base += consumed
        return frames
    }

    private static func mel(_ frequency: Float) -> Float { 1127 * log1p(frequency / 700) }

    private func features(_ input: [Float]) -> [Float] {
        let mean = input.reduce(0, +) / Float(Self.frameLength)
        var real = [Float](repeating: 0, count: Self.fftSize)
        let imaginary = real
        var previous = input[0] - mean
        for index in input.indices {
            let current = input[index] - mean
            real[index] = (current - 0.97 * previous) * window[index]
            previous = current
        }
        var fftReal = imaginary
        var fftImaginary = imaginary
        vDSP_DFT_Execute(fft, real, imaginary, &fftReal, &fftImaginary)
        let power = (0..<(Self.fftSize / 2)).map { index in
            fftReal[index] * fftReal[index] + fftImaginary[index] * fftImaginary[index]
        }
        return filters.map { filter in
            let energy = filter.reduce(Float(0)) { sum, term in sum + power[term.0] * term.1 }
            return log(max(Float.ulpOfOne, energy))
        }
    }
}

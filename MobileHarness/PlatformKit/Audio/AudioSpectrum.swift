import Foundation

/// Bounded PCM telemetry, independent of models and presentation. Frequencies ascend left to right.
public enum AudioSpectrum {
    public static let sampleCount = 2048
    public static let bandCount = 32
    public static let silence = [Float](repeating: 0, count: bandCount)
    private static let window = (0..<sampleCount).map { index in
        0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(sampleCount - 1))
    }

    /// Hann-windowed radix-2 FFT; at most 2048 samples, no retained audio or asynchronous queue.
    public static func measure<C: Collection>(_ samples: C, sampleRate: Int) -> [Float] where C.Element == Float {
        guard sampleRate >= 8000, !samples.isEmpty else { return silence }
        let input = Array(samples.suffix(sampleCount)).map { $0.isFinite ? Double($0) : 0 }
        let mean = input.reduce(0, +) / Double(input.count)
        var real = [Double](repeating: 0, count: sampleCount)
        var imaginary = real
        let start = sampleCount - input.count
        var gain = 0.0
        for index in input.indices {
            let weight = window[start + index]
            real[start + index] = (input[index] - mean) * weight
            gain += weight
        }
        guard gain > 1 else { return silence }
        var reversed = 0
        for index in 1..<sampleCount {
            var bit = sampleCount >> 1
            while reversed & bit != 0 {
                reversed ^= bit
                bit >>= 1
            }
            reversed ^= bit
            if index < reversed {
                real.swapAt(index, reversed)
                imaginary.swapAt(index, reversed)
            }
        }
        var length = 2
        while length <= sampleCount {
            let angle = -2 * Double.pi / Double(length)
            let stepReal = cos(angle)
            let stepImaginary = sin(angle)
            for base in stride(from: 0, to: sampleCount, by: length) {
                var rotationReal = 1.0
                var rotationImaginary = 0.0
                for offset in 0..<(length / 2) {
                    let a = base + offset
                    let b = a + length / 2
                    let r = real[b] * rotationReal - imaginary[b] * rotationImaginary
                    let i = real[b] * rotationImaginary + imaginary[b] * rotationReal
                    real[b] = real[a] - r
                    imaginary[b] = imaginary[a] - i
                    real[a] += r
                    imaginary[a] += i
                    let nextReal = rotationReal * stepReal - rotationImaginary * stepImaginary
                    rotationImaginary = rotationReal * stepImaginary + rotationImaginary * stepReal
                    rotationReal = nextReal
                }
            }
            length *= 2
        }
        let upper = min(8000, Double(sampleRate) / 2)
        return (0..<bandCount).map { band in
            let low = 80 * pow(upper / 80, Double(band) / Double(bandCount))
            let high = 80 * pow(upper / 80, Double(band + 1) / Double(bandCount))
            let first = max(1, Int(ceil(low * Double(sampleCount) / Double(sampleRate))))
            let last = min(sampleCount / 2, max(first, Int(ceil(high * Double(sampleCount) / Double(sampleRate))) - 1))
            var power = 0.0
            for bin in first...last { power += real[bin] * real[bin] + imaginary[bin] * imaginary[bin] }
            let amplitude = 2 * sqrt(power) / gain
            let decibels = 20 * log10(max(amplitude, 0.000_001))
            return Float(min(1, max(0, (decibels + 66) / 60)))
        }
    }

    /// Fast attack, slower release; no periodic modulation or automatic gain normalization.
    public static func smooth(_ next: [Float], previous: [Float]) -> [Float] {
        (0..<bandCount).map { index in
            let target = index < next.count && next[index].isFinite ? min(1, max(0, next[index])) : 0
            let old = index < previous.count && previous[index].isFinite ? min(1, max(0, previous[index])) : 0
            let value = old + (target - old) * (target > old ? 0.78 : 0.32)
            return value < 0.002 ? 0 : value
        }
    }
}

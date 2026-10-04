import AgentCore
import Foundation

/// Cheap image evidence; holds one inference reference and one union mask, each 64x64.
struct FrameMotionAnalyzer: Sendable {
    private var reference: [UInt8]?
    private var referenceTime: TimeInterval?
    private var regions = [Bool](repeating: false, count: 4096)
    private var noise = 1.5

    mutating func measure(_ sample: [UInt8], at time: TimeInterval, learnNoise: Bool) -> Double? {
        guard let reference, let referenceTime else { return nil }
        let oldRange = Self.range(reference)
        let newRange = Self.range(sample)
        // Robust contrast compensation is bounded so scene changes cannot fit an arbitrary transform.
        let gain = oldRange >= 24 && newRange >= 24 ? min(1.25, max(0.8, Double(newRange) / Double(oldRange))) : 1
        let differences = zip(sample, reference).map { Int($0) - Int((Double($1) * gain).rounded()) }
        var signedHistogram = [Int](repeating: 0, count: 641)
        for difference in differences { signedHistogram[difference + 320] += 1 }
        let offset = Self.quantile(signedHistogram, rank: 2048) - 320
        let threshold = min(16, max(3, noise * 3))
        var residualHistogram = [Int](repeating: 0, count: 641)
        var globalChanged = 0
        var globalExcess = 0.0
        var regionPixels = 0
        var regionChanged = 0
        var regionExcess = 0.0
        for index in sample.indices {
            let residual = abs(differences[index] - offset)
            residualHistogram[residual] += 1
            if regions[index] { regionPixels += 1 }
            let excess = max(0, Double(residual) - threshold)
            guard excess > 0 else { continue }
            globalChanged += 1
            globalExcess += excess
            if regions[index] {
                regionChanged += 1
                regionExcess += excess
            }
        }
        // A handful of isolated hot pixels cannot drive cadence; regions give small people more weight.
        let global = globalChanged >= 8 ? globalExcess / 4096 / (0.08 * 16) : 0
        let local =
            regionPixels >= 16 && regionChanged >= 3
            ? regionExcess / Double(regionPixels) / (0.2 * 12) : 0
        let rateScale = min(2, max(0.5, 0.1 / max(0.05, time - referenceTime)))
        let activity = min(1, max(global, local) * rateScale)
        let medianResidual = Self.quantile(residualHistogram, rank: 2048)
        // Only quiet, pose-confirmed samples train the noise floor; never absorb visible motion.
        if learnNoise, activity < 0.1, medianResidual <= 6 {
            let estimate = min(6, max(1, Double(medianResidual) * 1.48))
            noise = noise * 0.9 + estimate * 0.1
        }
        return activity
    }
    mutating func recordInference(_ sample: [UInt8], at time: TimeInterval) {
        reference = sample
        referenceTime = time
    }
    mutating func updateRegions(_ observation: PoseObservation) {
        regions = [Bool](repeating: false, count: 4096)
        for person in observation.people.prefix(6) {
            let joints = person.filter {
                $0.confidence >= 0.45 && $0.x >= 0 && $0.y >= 0
                    && $0.x <= Float(observation.width) && $0.y <= Float(observation.height)
            }
            guard joints.count >= 4 else { continue }
            let xs = joints.map { Double($0.x) / Double(observation.width) * 64 }
            let ys = joints.map { Double($0.y) / Double(observation.height) * 64 }
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { continue }
            let paddingX = max(3, (maxX - minX) * 0.15)
            let paddingY = max(3, (maxY - minY) * 0.15)
            let left = max(0, min(63, Int(floor(minX - paddingX))))
            let right = max(0, min(63, Int(ceil(maxX + paddingX))))
            let top = max(0, min(63, Int(floor(minY - paddingY))))
            let bottom = max(0, min(63, Int(ceil(maxY + paddingY))))
            for y in top...bottom {
                for x in left...right { regions[y * 64 + x] = true }
            }
        }
    }
    static func sample(_ frame: ImageInput) -> [UInt8] {
        switch frame.content {
        case .sampled(let gray, _): return Array(gray)
        case .rgb(let rgb):
            // Match PlatformKit's luminance weights and pixel-center sampling; no image/backend imports.
            var gray = [UInt8](repeating: 0, count: 4096)
            rgb.withUnsafeBytes { bytes in
                let pixels = bytes.bindMemory(to: UInt8.self)
                for y in 0..<64 {
                    let sy = min(frame.height - 1, (2 * y + 1) * frame.height / 128)
                    for x in 0..<64 {
                        let sx = min(frame.width - 1, (2 * x + 1) * frame.width / 128)
                        let offset = (sy * frame.width + sx) * 3
                        gray[y * 64 + x] = UInt8(
                            (77 * Int(pixels[offset]) + 150 * Int(pixels[offset + 1]) + 29 * Int(pixels[offset + 2])
                                + 128) >> 8)
                    }
                }
            }
            return gray
        }
    }
    private static func range(_ values: [UInt8]) -> Int {
        var histogram = [Int](repeating: 0, count: 256)
        for value in values { histogram[Int(value)] += 1 }
        return quantile(histogram, rank: 3686) - quantile(histogram, rank: 410)
    }
    private static func quantile(_ histogram: [Int], rank: Int) -> Int {
        var count = 0
        for (index, value) in histogram.enumerated() {
            count += value
            if count >= rank { return index }
        }
        return histogram.count - 1
    }
}

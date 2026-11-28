import Foundation
import ModelKit

/// Float32 PCM access shared by the speech preparation, segmentation and onset diagnostics.
extension AudioFrame {
    init(floatSamples: [Float], format: AudioFormat, sequence: UInt64, timestamp: TimeInterval) throws {
        try self.init(
            data: floatSamples.withUnsafeBytes { Data($0) }, format: format, sequence: sequence, timestamp: timestamp)
    }

    var floatSamples: [Float] {
        data.withUnsafeBytes { bytes in
            (0..<sampleCount).map { bytes.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self) }
        }
    }

    /// Level of the whole frame in dBFS, floored at -120 for digital silence.
    var rmsDecibels: Float { Self.rmsDecibels(samples: floatSamples) }

    static func rmsDecibels(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -120 }
        let power = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        return Float(10 * log10(max(power, 1e-12)))
    }
}

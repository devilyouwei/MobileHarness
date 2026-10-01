import Foundation
import ModelKit

/// Downmix native 48 kHz stereo to the application's mono PCM without changing sample rate.
struct MossPCMEncoder {
    private var samples = 0
    private var sequence: UInt64 = 0
    mutating func encode(left: [Float], right: [Float]) throws -> [AudioFrame] {
        guard !left.isEmpty, left.count == right.count, left.count <= 19_200,
            left.count <= 48_000 * 60 - samples,
            left.allSatisfy(\.isFinite), right.allSatisfy(\.isFinite)
        else { throw CapabilityError.invalidRequest("Invalid MOSS PCM or 60-second audio limit exceeded") }
        let format = try AudioFormat(sampleRate: 48_000, channels: 1, encoding: .float32)
        var frames: [AudioFrame] = []
        for offset in stride(from: 0, to: left.count, by: 4096) {
            let end = min(left.count, offset + 4096)
            let mono = (offset..<end).map { left[$0] * 0.5 + right[$0] * 0.5 }
            frames.append(
                try AudioFrame(
                    data: mono.withUnsafeBytes { Data($0) }, format: format,
                    sequence: sequence, timestamp: Double(samples) / 48_000))
            samples += mono.count
            sequence += 1
        }
        return frames
    }
}

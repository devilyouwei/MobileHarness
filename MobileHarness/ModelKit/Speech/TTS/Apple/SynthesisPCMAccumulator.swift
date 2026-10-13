import Foundation
import ModelKit

/// Coalesces small system callbacks so the event count budget also reflects actual audio size.
struct SynthesisPCMAccumulator {
    private var pending = Data()
    private var format: AudioFormat?
    private var sequence: UInt64 = 0
    private var timestamp = 0.0
    private let chunkBytes = 16_384
    private var emittedInitialPCM = false

    mutating func append(_ frame: AudioFrame) throws -> [AudioFrame] {
        if let format, format != frame.format { throw CapabilityError.invalidRequest("TTS PCM format changed") }
        format = frame.format
        pending.append(frame.data)
        var result: [AudioFrame] = []
        if !emittedInitialPCM {
            result.append(try take(min(pending.count, chunkBytes)))
            emittedInitialPCM = true
        }
        while pending.count >= chunkBytes {
            result.append(try take(chunkBytes))
        }
        return result
    }
    mutating func finish() throws -> [AudioFrame] {
        guard !pending.isEmpty else { return [] }
        return [try take(pending.count)]
    }
    private mutating func take(_ count: Int) throws -> AudioFrame {
        guard let format else { throw CapabilityError.invalidRequest("Missing TTS audio format") }
        let frame = try AudioFrame(
            data: pending.prefix(count), format: format, sequence: sequence, timestamp: timestamp)
        pending.removeFirst(count)
        sequence += 1
        timestamp += frame.duration
        return frame
    }
}

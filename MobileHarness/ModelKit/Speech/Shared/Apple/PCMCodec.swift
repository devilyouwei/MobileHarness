import AVFAudio
import Foundation
import ModelKit

/// Copies platform buffers into owned mono Float32 PCM before crossing concurrency boundaries.
enum PCMCodec {
    static func encode(_ buffer: AVAudioPCMBuffer, sequence: UInt64) throws -> AudioFrame {
        let count = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard count > 0, count <= 262_144, channels > 0 else {
            throw CapabilityError.invalidRequest("Invalid system speech buffer")
        }
        var samples = [Float](repeating: 0, count: count)
        let interleaved = buffer.format.isInterleaved
        for channel in 0..<channels {
            for index in 0..<count {
                let offset = interleaved ? index * channels + channel : index
                let plane = interleaved ? 0 : channel
                if let data = buffer.floatChannelData {
                    samples[index] += data[plane][offset] / Float(channels)
                } else if let data = buffer.int16ChannelData {
                    samples[index] += Float(data[plane][offset]) / (32768 * Float(channels))
                } else {
                    throw CapabilityError.invalidRequest("Unsupported system PCM encoding")
                }
            }
        }
        let format = try AudioFormat(sampleRate: Int(buffer.format.sampleRate), channels: 1, encoding: .float32)
        return try AudioFrame(
            data: samples.withUnsafeBytes { Data($0) }, format: format, sequence: sequence, timestamp: 0)
    }

    static func decode(_ frame: AudioFrame) throws -> AVAudioPCMBuffer {
        guard frame.format.channels == 1, frame.format.encoding == .float32,
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(frame.format.sampleRate), channels: 1,
                interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frame.sampleCount)),
            let destination = buffer.floatChannelData?[0]
        else { throw CapabilityError.invalidRequest("Apple ASR requires mono Float32 PCM") }
        buffer.frameLength = AVAudioFrameCount(frame.sampleCount)
        frame.data.withUnsafeBytes { bytes in
            for index in 0..<frame.sampleCount {
                destination[index] = bytes.loadUnaligned(fromByteOffset: index * 4, as: Float.self)
            }
        }
        return buffer
    }
}

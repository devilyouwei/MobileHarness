import Foundation
import ModelKit
import PlatformKit

/// Capture-scoped preprocessing; no device activation, playback gating or independent PCM queue.
actor SpeechPCMPreparation {
    private let downsample: StreamingMonoPCMResampler
    private let upsample: StreamingMonoPCMResampler
    private let enhancement: WindowedSpeechEnhancement?
    private var enabled = false
    private var origin: TimeInterval?
    private var highSamples = 0
    private var outputSamples = 0
    private var generation: UInt64 = 0
    private var busy = false
    init(enhancement: (any SpeechEnhancementCapability)?) throws {
        downsample = try StreamingMonoPCMResampler(outputSampleRate: 16000)
        upsample = try StreamingMonoPCMResampler(outputSampleRate: 48000)
        self.enhancement = enhancement.map { WindowedSpeechEnhancement(capability: $0) }
    }
    func configure(enabled: Bool) async throws {
        guard !enabled || enhancement != nil else {
            throw CapabilityError.unavailable("Speech enhancement is unavailable")
        }
        self.enabled = enabled
        await reset()
    }
    func reset() async {
        generation &+= 1
        origin = nil
        highSamples = 0
        outputSamples = 0
        await upsample.reset()
        await downsample.reset()
        await enhancement?.reset()
    }
    func process(_ frame: MicrophoneFrame, timestamp: TimeInterval) async throws -> [AudioFrame] {
        guard !busy else { throw CapabilityError.inputBusy }
        busy = true
        defer { busy = false }
        let epoch = generation
        if origin == nil { origin = timestamp }
        var packets: [MicrophoneFrame] = []
        if enabled, let enhancement {
            for high in try await upsample.process(frame) {
                try check(epoch)
                let input = try AudioFrame(
                    data: high.samples.withUnsafeBytes { Data($0) },
                    format: AudioFormat(sampleRate: 48000, channels: 1, encoding: .float32),
                    sequence: high.sequence, timestamp: (origin ?? timestamp) + Double(highSamples) / 48000)
                highSamples += high.samples.count
                for clean in try await enhancement.process(input) {
                    try check(epoch)
                    let samples = clean.data.withUnsafeBytes { bytes in
                        (0..<clean.sampleCount).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
                    }
                    for offset in stride(from: 0, to: samples.count, by: 8192) {
                        packets += try await downsample.process(
                            MicrophoneFrame(
                                samples: Array(samples[offset..<min(offset + 8192, samples.count)]), sampleRate: 48000,
                                sequence: clean.sequence))
                        try check(epoch)
                    }
                }
            }
        } else {
            packets = try await downsample.process(frame)
        }
        try check(epoch)
        return try packets.map { packet in
            defer { outputSamples += packet.samples.count }
            return try AudioFrame(
                data: packet.samples.withUnsafeBytes { Data($0) },
                format: AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32), sequence: packet.sequence,
                timestamp: (origin ?? timestamp) + Double(outputSamples) / 16000)
        }
    }
    private func check(_ epoch: UInt64) throws {
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
    }
}

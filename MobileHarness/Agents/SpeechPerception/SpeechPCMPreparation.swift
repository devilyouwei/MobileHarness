import Foundation
import ModelKit
import PlatformKit

/// Capture-scoped preprocessing; no device activation, playback gating or independent PCM queue.
actor SpeechPCMPreparation {
    private static let conversionChunk = 8192
    private let enhancementFormat: AudioFormat
    private let modelFormat: AudioFormat
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
        enhancementFormat = try AudioFormat(sampleRate: 48000, channels: 1, encoding: .float32)
        modelFormat = try AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32)
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
        let packets: [MicrophoneFrame]
        if enabled, let enhancement {
            packets = try await enhanced(frame, with: enhancement, epoch: epoch, timestamp: timestamp)
        } else {
            packets = try await downsample.process(frame)
        }
        try check(epoch)
        return try packets.map { packet in
            defer { outputSamples += packet.samples.count }
            return try AudioFrame(
                floatSamples: packet.samples, format: modelFormat, sequence: packet.sequence,
                timestamp: (origin ?? timestamp) + Double(outputSamples) / 16000)
        }
    }
    /// 48 kHz enhancement window; failures propagate, original PCM is never substituted for denoised PCM.
    private func enhanced(
        _ frame: MicrophoneFrame, with enhancement: WindowedSpeechEnhancement, epoch: UInt64, timestamp: TimeInterval
    ) async throws -> [MicrophoneFrame] {
        var packets: [MicrophoneFrame] = []
        for high in try await upsample.process(frame) {
            try check(epoch)
            let input = try AudioFrame(
                floatSamples: high.samples, format: enhancementFormat, sequence: high.sequence,
                timestamp: (origin ?? timestamp) + Double(highSamples) / 48000)
            highSamples += high.samples.count
            for clean in try await enhancement.process(input) {
                try check(epoch)
                packets += try await downsampled(clean.floatSamples, sequence: clean.sequence, epoch: epoch)
            }
        }
        return packets
    }
    private func downsampled(_ samples: [Float], sequence: UInt64, epoch: UInt64) async throws -> [MicrophoneFrame] {
        var packets: [MicrophoneFrame] = []
        for offset in stride(from: 0, to: samples.count, by: Self.conversionChunk) {
            let chunk = Array(samples[offset..<min(offset + Self.conversionChunk, samples.count)])
            packets += try await downsample.process(
                MicrophoneFrame(samples: chunk, sampleRate: 48000, sequence: sequence))
            try check(epoch)
        }
        return packets
    }
    private func check(_ epoch: UInt64) throws {
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
    }
}

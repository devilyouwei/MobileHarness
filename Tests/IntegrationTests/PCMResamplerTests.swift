import Foundation
import PlatformKit
import Testing

@Test(.actionCatalog) func microphoneResamplingPreservesDurationAndPacketContinuity() async throws {
    for rate in [16000, 44100, 48000] {
        let samples = (0..<rate).map { Float(sin(2 * Double.pi * 440 * Double($0) / Double(rate))) * 0.2 }
        let frames = stride(from: 0, to: samples.count, by: 1024).enumerated().map { index, offset in
            MicrophoneFrame(
                samples: Array(samples[offset..<min(offset + 1024, samples.count)]), sampleRate: rate,
                sequence: UInt64(index))
        }
        let resampler = try StreamingMonoPCMResampler(outputSampleRate: 16000)
        var output: [MicrophoneFrame] = []
        for frame in frames { output += try await resampler.process(frame) }
        let values = output.flatMap(\.samples)
        #expect(abs(values.count - 16000) < 128)
        #expect(output.allSatisfy { $0.sampleRate == 16000 && $0.samples.count <= 4000 })
        #expect(output.map(\.sequence) == Array(0..<UInt64(output.count)))
        #expect(values.allSatisfy { $0.isFinite })
        let rms = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 } / Float(values.count))
        #expect(rms > 0.13 && rms < 0.15)
    }
}

@Test(.actionCatalog) func microphoneResamplingRejectsChangingFormats() async throws {
    let frames = [
        MicrophoneFrame(samples: [0.1], sampleRate: 48000, sequence: 0),
        MicrophoneFrame(samples: [0.1], sampleRate: 44100, sequence: 1),
    ]
    let resampler = try StreamingMonoPCMResampler(outputSampleRate: 16000)
    _ = try await resampler.process(frames[0])
    await #expect(throws: StreamingMonoPCMResampler.ConversionError.self) {
        try await resampler.process(frames[1])
    }
}

@Test(.actionCatalog) func microphoneResamplingUsesCallerRateAndResetAcceptsNewHardwareFormat() async throws {
    let converter = try StreamingMonoPCMResampler(outputSampleRate: 24000)
    let first = try await converter.process(
        MicrophoneFrame(samples: Array(repeating: 0.1, count: 4800), sampleRate: 48000, sequence: 0))
    #expect(first.allSatisfy { $0.sampleRate == 24000 })
    // The native converter retains its filter tail until later packets.
    #expect(!first.isEmpty && first.reduce(0) { $0 + $1.samples.count } > 2000)
    await converter.reset()
    let second = try await converter.process(
        MicrophoneFrame(samples: Array(repeating: 0.1, count: 2400), sampleRate: 24000, sequence: 1))
    #expect(second.count == 1 && second[0].sequence == 0 && second[0].samples.count == 2400)
    #expect(throws: StreamingMonoPCMResampler.ConversionError.self) {
        try StreamingMonoPCMResampler(outputSampleRate: 0)
    }
}

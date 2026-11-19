import Foundation
import ModelKit
import PlatformKit
import Testing

@testable import Agents

private actor GainEnhancement: SpeechEnhancementCapability {
    let gain: Float
    var calls = 0
    var failure = false
    var sizes: [Int] = []
    init(_ gain: Float = 1) { self.gain = gain }
    var availability: CapabilityAvailability { .available }
    func fail() { failure = true }
    func enhance(_ audio: AudioFrame) throws -> AudioFrame {
        calls += 1
        sizes.append(audio.sampleCount)
        if failure { throw CapabilityError.unavailable("injected") }
        let samples = decodeEnhancementPCM(audio).map { $0 * gain }
        return try AudioFrame(
            data: samples.withUnsafeBytes { Data($0) }, format: audio.format,
            sequence: audio.sequence, timestamp: audio.timestamp)
    }
}
private func decodeEnhancementPCM(_ frame: AudioFrame) -> [Float] {
    frame.data.withUnsafeBytes { bytes in
        (0..<frame.sampleCount).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
    }
}
private func enhancementPCM(_ samples: [Float], sequence: UInt64, timestamp: Double) throws -> AudioFrame {
    try AudioFrame(
        data: samples.withUnsafeBytes { Data($0) },
        format: AudioFormat(sampleRate: 48000, channels: 1, encoding: .float32), sequence: sequence,
        timestamp: timestamp)
}

@Test func windowedEnhancementPreservesSamplesAndTimelineAcrossSeams() async throws {
    for count in [1, 12345, 65537] {
        let model = GainEnhancement(0.5)
        let stream = WindowedSpeechEnhancement(capability: model)
        let samples = (0..<count).map { Float($0 % 1000) / 1000 }
        var outputs: [AudioFrame] = []
        for offset in stride(from: 0, to: count, by: 4000) {
            outputs += try await stream.process(
                enhancementPCM(
                    Array(samples[offset..<min(count, offset + 4000)]), sequence: UInt64(offset / 4000),
                    timestamp: 2 + Double(offset) / 48000))
            if offset + 4000 < 19200 { #expect(outputs.isEmpty) }
        }
        outputs += try await stream.finish()
        let clean = outputs.flatMap(decodeEnhancementPCM)
        #expect(clean.count == samples.count)
        #expect(zip(clean, samples).allSatisfy { abs($0 - $1 * 0.5) < 0.000001 })
        var emitted = 0
        for (index, frame) in outputs.enumerated() {
            #expect(frame.sequence == UInt64(index))
            #expect(abs(frame.timestamp - (2 + Double(emitted) / 48000)) < 1e-8)
            emitted += frame.sampleCount
        }
        #expect(await model.sizes.allSatisfy { $0 <= 34560 })
        await #expect(throws: CapabilityError.sessionClosed) { try await stream.finish() }
    }
}

@Test func windowedEnhancementFailureClosesAndResetDiscardsOldAudio() async throws {
    let model = GainEnhancement()
    let stream = WindowedSpeechEnhancement(capability: model)
    _ = try await stream.process(enhancementPCM([Float](repeating: 1, count: 4000), sequence: 0, timestamp: 0))
    await stream.reset()
    _ = try await stream.process(enhancementPCM([0.25], sequence: 0, timestamp: 5))
    #expect(try await stream.finish().flatMap(decodeEnhancementPCM) == [0.25])
    await stream.reset()
    await model.fail()
    _ = try await stream.process(enhancementPCM([1], sequence: 0, timestamp: 0))
    await #expect(throws: CapabilityError.self) { try await stream.finish() }
    await #expect(throws: CapabilityError.sessionClosed) {
        try await stream.process(enhancementPCM([1], sequence: 1, timestamp: 1.0 / 48000))
    }
}

@Test func windowedEnhancementRejectsGapsAndOversizedInput() async throws {
    let stream = WindowedSpeechEnhancement(capability: GainEnhancement())
    await #expect(throws: CapabilityError.self) {
        try await stream.process(enhancementPCM([Float](repeating: 0, count: 8193), sequence: 0, timestamp: 0))
    }
    _ = try await stream.process(enhancementPCM([0], sequence: 0, timestamp: 0))
    await #expect(throws: CapabilityError.self) {
        try await stream.process(enhancementPCM([0], sequence: 1, timestamp: 1))
    }
    #expect(try await stream.finish().first?.sampleCount == 1)
}

@Test func speechEnhancementPCMPreparationUsesSameCleanFramesBeforeDetectionAndRecognition() async throws {
    let model = GainEnhancement(0.5)
    let pipeline = try SpeechPCMPreparation(enhancement: model)
    try await pipeline.configure(enabled: true)
    var outputs: [AudioFrame] = []
    for offset in stride(from: 0, to: 48000, by: 4000) {
        outputs += try await pipeline.process(
            MicrophoneFrame(
                samples: [Float](repeating: 0.25, count: 4000), sampleRate: 48000, sequence: UInt64(offset)),
            timestamp: 3 + Double(offset) / 48000)
    }
    #expect(await model.calls > 0)
    #expect(!outputs.isEmpty)
    #expect(outputs.allSatisfy { $0.format.sampleRate == 16000 && $0.format.channels == 1 })
    #expect(outputs.flatMap(decodeEnhancementPCM).dropFirst(100).allSatisfy { abs($0 - 0.125) < 0.002 })
    let calls = await model.calls
    try await pipeline.configure(enabled: false)
    let direct = try await pipeline.process(
        MicrophoneFrame(samples: [0.75, 0.5], sampleRate: 16000, sequence: 0), timestamp: 8)
    #expect(direct.flatMap(decodeEnhancementPCM) == [0.75, 0.5])
    #expect(direct.first?.timestamp == 8)
    #expect(await model.calls == calls)
}

private actor DelayedEnhancement: SpeechEnhancementCapability {
    var availability: CapabilityAvailability { .available }
    var waiting = false
    var continuation: CheckedContinuation<Void, Never>?
    func enhance(_ audio: AudioFrame) async -> AudioFrame {
        waiting = true
        await withCheckedContinuation { continuation = $0 }
        return audio
    }
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@Test func windowedEnhancementResetInvalidatesInFlightResult() async throws {
    let model = DelayedEnhancement()
    let stream = WindowedSpeechEnhancement(capability: model)
    _ = try await stream.process(enhancementPCM([0.5], sequence: 0, timestamp: 0))
    let finishing = Task { try await stream.finish() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await model.waiting), ContinuousClock.now < deadline { await Task.yield() }
    #expect(await model.waiting)
    await stream.reset()
    await #expect(throws: CapabilityError.inputBusy) {
        try await stream.process(enhancementPCM([1], sequence: 0, timestamp: 0))
    }
    await model.resume()
    await #expect(throws: CancellationError.self) { try await finishing.value }
    #expect(try await stream.finish().isEmpty)
}

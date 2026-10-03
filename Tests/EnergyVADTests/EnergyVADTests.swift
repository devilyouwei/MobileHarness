import Foundation
@_spi(ModelManagement) import ModelKit
import ModelKitEnergy
import Testing

private func frame(_ samples: [Float], format: AudioFormat) throws -> AudioFrame {
    try AudioFrame(data: samples.withUnsafeBytes { Data($0) }, format: format, sequence: 0, timestamp: 0)
}
@Test func energyDetectionIsPacketIndependentAndReleasesExclusiveLease() async throws {
    let context = ModelContext()
    let detector = try EnergyVoiceActivity(context: context)
    let format = try AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32)
    let samples =
        Array(repeating: Float(0), count: 1024) + Array(repeating: Float(0.05), count: 2048)
        + Array(repeating: Float(0), count: 1536)
    var variants: [[VoiceActivityScore]] = []
    for size in [137, 512, 4000] {
        let session = try await detector.detectVoiceActivity(format: format)
        await #expect(throws: CapabilityError.inputBusy) { _ = try await detector.detectVoiceActivity(format: format) }
        var scores: [VoiceActivityScore] = []
        for offset in stride(from: 0, to: samples.count, by: size) {
            scores += try await session.process(
                frame(Array(samples[offset..<min(samples.count, offset + size)]), format: format))
        }
        scores += try await session.finish()
        variants.append(scores)
    }
    #expect(variants[0] == variants[1])
    #expect(variants[1] == variants[2])
    #expect(variants[0].map(\.probability) == [0, 0, 1, 1, 1, 1, 0, 0, 0])
    try await context.unload()
    #expect(await context.status == .unloaded)
}
@Test func energyRejectsNonFiniteInputAndResetClearsWindowHistory() async throws {
    let detector = try EnergyVoiceActivity(context: ModelContext())
    let format = try AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32)
    let session = try await detector.detectVoiceActivity(format: format)
    await #expect(throws: CapabilityError.self) { try await session.process(frame([Float.nan], format: format)) }
    _ = try await session.process(frame(Array(repeating: 0.05, count: 100), format: format))
    try await session.reset()
    let values = try await session.process(frame(Array(repeating: 0, count: 512), format: format))
    #expect(values.first?.startSample == 0)
    #expect(values.first?.probability == 0)
    await session.cancel()
}

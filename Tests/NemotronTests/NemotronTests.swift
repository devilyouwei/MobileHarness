import AVFAudio
import Foundation
@_spi(ModelManagement) import ModelKit
import ModelKitFluidAudio
import Testing

@testable import ModelKitNemotron

private var repository: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
private func metadata(chunkFrames: Int = 224) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "sample_rate": 16000, "mel_features": 128, "chunk_mel_frames": chunkFrames,
            "pre_encode_cache": 9, "total_mel_frames": 233, "vocab_size": 13087, "blank_idx": 13087,
            "encoder_dim": 1024, "decoder_hidden": 640, "decoder_layers": 2,
            "cache_channel_shape": [1, 24, 42, 1024], "cache_time_shape": [1, 24, 1024, 8],
            "num_prompts": 128, "default_prompt_id": 101,
            "prompt_dictionary": ["auto": 101, "en-US": 0, "zh-CN": 20],
        ] as [String: Any])
}
@Test func coreMLMetadataSelects2240msMultilingualAndRejectsOtherTiers() throws {
    let prompts = try LocalNemotronEngine.validateMetadata(metadata())
    #expect(prompts["auto"] == 101)
    #expect(prompts["zh-CN"] == 20)
    #expect(throws: LocalNemotronEngine.Failure.self) {
        try LocalNemotronEngine.validateMetadata(metadata(chunkFrames: 112))
    }
    #expect(throws: LocalNemotronEngine.Failure.self) {
        try LocalNemotronEngine.validateMetadata(Data("{}".utf8))
    }
}
@Test func coreMLRecognitionReportsMissingResourcesWithoutLoading() async throws {
    let context = ModelContext()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let provider = try NemotronASR(context: context, artifacts: root)
    if case .available = await provider.availability { Issue.record("Missing files must not report available") }
    #expect(await context.status == .unloaded)
    let format = try AudioFormat(sampleRate: 24000, channels: 1, encoding: .float32)
    await #expect(throws: CapabilityError.self) {
        try await provider.transcribe(SpeechRecognitionRequest(locale: "auto", format: format))
    }
}

@Test func modelLeaseRejectsConcurrentAdmissionAndAllowsUnload() async throws {
    let context = ModelContext()
    let manager = try context.resource { 42 }
    let first = try await manager.acquire()
    #expect(first.model == 42)
    await #expect(throws: CapabilityError.inputBusy) { _ = try await manager.acquire() }
    await manager.release(first.id)
    try await context.unload()
    let next = try await manager.acquire()
    #expect(next.id != first.id)
    await manager.release(next.id)
}

/// Opt-in local Core ML test; uses generated fixture speech, no microphone or network.
@Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_TEST_NEMOTRON"] == "1"))
@available(macOS 15, iOS 18, *)
func realModelStreamingPacketParityAndCancellation() async throws {
    let models = repository.appendingPathComponent("MobileHarness/Resources/Models")
    let providerContext = ModelContext()
    let provider = try NemotronASR(
        context: providerContext,
        artifacts: models.appendingPathComponent("Nemotron"))
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: "/tmp/nemotron-fixture.wav"))
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let data = try #require(buffer.floatChannelData?[0])
    let samples = Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    let format = try AudioFormat(sampleRate: 16_000, channels: 1, encoding: .float32)
    try await provider.warmup()
    var transcripts: [String] = []
    for size in [137, 4000, 16_000] {
        let session = try await provider.transcribe(SpeechRecognitionRequest(locale: "auto", format: format))
        let consumer = Task { () throws -> [TranscriptionEvent] in
            var events: [TranscriptionEvent] = []
            for try await event in session.output.events { events.append(event) }
            return events
        }
        do {
            for offset in stride(from: 0, to: samples.count, by: size) {
                let packet = Array(samples[offset..<min(samples.count, offset + size)])
                try await session.send(
                    AudioFrame(
                        data: packet.withUnsafeBytes { Data($0) }, format: format,
                        sequence: UInt64(offset), timestamp: Double(offset) / 16_000))
            }
            try await session.finishInput()
            let events = try await consumer.value
            #expect(events.filter(\.isFinal).count == 1)
            #expect(events.contains { !$0.isFinal })
            #expect(Set(events.map(\.segmentID)).count == 1)
            #expect(events.map(\.revision) == Array(0..<UInt64(events.count)))
            let text = try #require(events.last?.text)
            print("Nemotron auto English packet=\(size): \(text)")
            #expect(text.lowercased().contains("quick brown fox"))
            transcripts.append(text)
        } catch {
            await session.cancel()
            consumer.cancel()
            throw error
        }
    }
    #expect(Set(transcripts).count == 1)
    let cancelled = try await provider.transcribe(SpeechRecognitionRequest(locale: "auto", format: format))
    await cancelled.cancel()
    try await providerContext.unload()
    let next = try await provider.transcribe(SpeechRecognitionRequest(locale: "auto", format: format))
    try await next.finishInput()
    var finals = 0
    for try await event in next.output.events { if event.isFinal { finals += 1 } }
    #expect(finals == 1)
    try await providerContext.unload()

    let chineseFile = try AVAudioFile(forReading: URL(fileURLWithPath: "/tmp/nemotron-chinese.wav"))
    let chineseBuffer = try #require(
        AVAudioPCMBuffer(
            pcmFormat: chineseFile.processingFormat,
            frameCapacity: AVAudioFrameCount(chineseFile.length)))
    try chineseFile.read(into: chineseBuffer)
    let chineseData = try #require(chineseBuffer.floatChannelData?[0])
    let chineseSamples = Array(UnsafeBufferPointer(start: chineseData, count: Int(chineseBuffer.frameLength)))
    let chinese = try await provider.transcribe(SpeechRecognitionRequest(locale: "auto", format: format))
    let reader = Task { () throws -> String in
        var final = ""
        for try await event in chinese.output.events { if event.isFinal { final = event.text } }
        return final
    }
    for offset in stride(from: 0, to: chineseSamples.count, by: 4000) {
        let packet = Array(chineseSamples[offset..<min(chineseSamples.count, offset + 4000)])
        try await chinese.send(
            AudioFrame(
                data: packet.withUnsafeBytes { Data($0) }, format: format,
                sequence: UInt64(offset), timestamp: Double(offset) / 16_000))
    }
    try await chinese.finishInput()
    let chineseText = try await reader.value
    print("Nemotron auto Chinese: \(chineseText)")
    #expect(chineseText.contains("语音识别"))
    try await providerContext.unload()
}

import AVFAudio
import Foundation
@_spi(ModelManagement) import ModelKit
import Testing

@testable import ModelKitNemotron

private var repository: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
private func melFilters() throws -> [Float] {
    let url = repository.appendingPathComponent("MobileHarness/ModelKit/Speech/ASR/Nemotron/Resources/mel_filters.f32")
    return try Data(contentsOf: url).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

@Test func melIsIndependentOfPacketBoundaries() throws {
    let filters = try melFilters()
    let samples = (0..<16_000).map { Float(sin(Double($0) * 0.037) * 0.2) }
    let whole = NemotronMelStream(melFilters: filters).push(samples)
    let streaming = NemotronMelStream(melFilters: filters)
    var chunked: [[Float]] = []
    for i in stride(from: 0, to: samples.count, by: 137) {
        chunked += streaming.push(Array(samples[i..<min(samples.count, i + 137)]))
    }
    #expect(whole == chunked)
    #expect(whole.first?.count == 25 * 128)
    #expect(whole.dropFirst().allSatisfy { $0.count == 32 * 128 })
    let silence = NemotronMelStream(melFilters: filters).push(Array(repeating: 0, count: 5000))
    #expect(silence[0].allSatisfy { abs($0 - log(pow(2, -24))) < 0.00001 })
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

@Test func tokenizerMetaspacePreservesChineseAndPunctuation() throws {
    var vocab: [String: Int] = [:]
    for i in 0..<13_087 { vocab["unused\(i)"] = i }
    for (id, token) in ["▁hello", "▁world", "!", "你", "好"].enumerated() {
        vocab.removeValue(forKey: "unused\(id)")
        vocab[token] = id
    }
    let file: [String: Any] = [
        "model": ["type": "BPE", "vocab": vocab],
        "decoder": ["type": "Metaspace", "replacement": "▁", "prepend_scheme": "always"],
    ]
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    try JSONSerialization.data(withJSONObject: file).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let tokenizer = try NemotronTokenizer(url: url)
    #expect(tokenizer.decode(tokens: [0, 1, 2]) == "hello world!")
    #expect(tokenizer.decode(tokens: [3, 4, 2]) == "你好!")
}

/// Opt-in local GPU test; uses generated fixture speech, no microphone or network.
@Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_TEST_NEMOTRON"] == "1"))
@available(macOS 27, iOS 27, *)
func realModelStreamingPacketParityAndCancellation() async throws {
    let models = repository.appendingPathComponent("MobileHarness/Resources/Models")
    let providerContext = ModelContext()
    let provider = try NemotronASR(
        context: providerContext,
        artifacts: models.appendingPathComponent("Nemotron-macos"))
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

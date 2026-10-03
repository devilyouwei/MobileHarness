import AVFAudio
import Foundation
@_spi(ModelManagement) import ModelKit
import Testing

@testable import ModelKitAppleSpeech

@Test func modernAppleRecognitionRejectsInvalidPCMWithoutLoading() async throws {
    guard #available(macOS 26, iOS 26, *) else { return }
    let context = ModelContext()
    let provider = try AppleSpeechRecognition(context: context)
    let format = try AudioFormat(sampleRate: 24000, channels: 1, encoding: .float32)
    await #expect(throws: CapabilityError.self) {
        try await provider.transcribe(SpeechRecognitionRequest(locale: "zh-CN", format: format))
    }
    #expect(await context.status == .unloaded)
}

@Test func systemPCMIsCopiedAndDownmixed() throws {
    let format = try #require(
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 2, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
    buffer.frameLength = 2
    let channels = try #require(buffer.floatChannelData)
    channels[0][0] = 0.5
    channels[1][0] = -0.5
    channels[0][1] = 1
    channels[1][1] = 0
    let frame = try PCMCodec.encode(buffer, sequence: 3)
    channels[0][0] = 99
    let samples = frame.data.withUnsafeBytes { bytes in
        [bytes.loadUnaligned(as: Float.self), bytes.loadUnaligned(fromByteOffset: 4, as: Float.self)]
    }
    #expect(samples == [0, 0.5])
    #expect(frame.sequence == 3)
    #expect(frame.format.channels == 1)
    #expect(frame.format.sampleRate == 24_000)
    let decoded = try PCMCodec.decode(frame)
    #expect(decoded.frameLength == 2)
    #expect(decoded.floatChannelData?[0][1] == 0.5)
}

@Test func systemPCMRejectsUnsupportedRecognitionFormat() throws {
    let frame = try AudioFrame(
        data: Data([0, 0]),
        format: AudioFormat(sampleRate: 16_000, channels: 1, encoding: .signedInt16), sequence: 0, timestamp: 0)
    #expect(throws: CapabilityError.self) { _ = try PCMCodec.decode(frame) }
}

/// Opt-in integration test: synthesizes real system audio into memory without opening a speaker or microphone.
@Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_TEST_SYSTEM_TTS"] == "1"))
@MainActor func systemChineseTTSProducesPCM() async throws {
    let provider = try AppleSpeechSynthesis(context: ModelContext())
    let session = try await provider.synthesize(
        SpeechSynthesisRequest(text: "收到，我听到了。这是语音对话测试，暂未接入大语言模型。", locale: "zh-CN"))
    defer { session.cancel() }
    var bytes = 0
    var completed = false
    for try await event in session.events {
        switch event {
        case .audio(let frame):
            #expect(frame.format.encoding == .float32)
            #expect(frame.format.channels == 1)
            bytes += frame.data.count
            // Emulate actual playback speed so a normal reply exercises the bounded output queue.
            try await Task.sleep(for: .seconds(frame.duration))
        case .finished: completed = true
        }
    }
    #expect(completed)
    #expect(bytes > 0)
}

@Test func tinyTTSCallbacksAreCoalescedWithoutDroppingPCM() throws {
    var accumulator = SynthesisPCMAccumulator()
    let format = try AudioFormat(sampleRate: 24_000, channels: 1, encoding: .float32)
    let payload = Data(repeating: 0, count: 512)
    var chunks: [AudioFrame] = []
    for index in 0..<300 {
        chunks += try accumulator.append(
            AudioFrame(data: payload, format: format, sequence: UInt64(index), timestamp: 0))
    }
    chunks += try accumulator.finish()
    #expect(chunks.count == 10)
    #expect(chunks.reduce(0, { $0 + $1.data.count }) == 300 * 512)
    #expect(chunks.allSatisfy { $0.data.count <= 16_384 })
    #expect(chunks.map(\.sequence) == Array(UInt64(0)..<UInt64(10)))
    #expect(chunks.last!.timestamp > chunks.first!.timestamp)
    #expect(try accumulator.finish().isEmpty)
}

/// Real modern on-device ASR; opt-in because Apple may install system language assets.
@Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_TEST_SYSTEM_ASR_WAV"] != nil))
func systemAnalyzerTranscribesFixtureAndReleasesLease() async throws {
    guard #available(macOS 26, iOS 26, *) else { return }
    let path = try #require(ProcessInfo.processInfo.environment["HARNESS_TEST_SYSTEM_ASR_WAV"])
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    #expect(file.processingFormat.sampleRate == 16000)
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let encoded = try PCMCodec.encode(buffer, sequence: 0)
    let frame = try AudioFrame(
        data: encoded.data + Data(repeating: 0, count: 32000 * 4), format: encoded.format, sequence: 0, timestamp: 0)
    let context = ModelContext()
    let provider = try AppleSpeechRecognition(context: context)
    try await provider.warmup()
    let session = try await provider.transcribe(SpeechRecognitionRequest(locale: "zh-CN", format: frame.format))
    let reader = Task { () throws -> String in
        var final = ""
        for try await event in session.output.events { if event.isFinal { final = event.text } }
        return final
    }
    do {
        var offset = 0
        var sequence: UInt64 = 0
        while offset < frame.data.count {
            let end = min(offset + 137 * 4, frame.data.count)
            try await session.send(
                AudioFrame(
                    data: frame.data.subdata(in: offset..<end), format: frame.format, sequence: sequence,
                    timestamp: Double(offset / 4) / 16000))
            offset = end
            sequence += 1
        }
        try await session.finishInput()
        let text = try await reader.value
        print("Apple SpeechAnalyzer fixture: \(text)")
        #expect(!text.isEmpty)
        let again = try await provider.transcribe(SpeechRecognitionRequest(locale: "zh-CN", format: frame.format))
        await again.cancel()
        try await context.unload()
        #expect(await context.status == .unloaded)
    } catch {
        await session.cancel()
        reader.cancel()
        throw error
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_TEST_SYSTEM_TTS"] == "1"))
@MainActor func consecutiveSystemRepliesReleaseAdmissionBeforeNextRequest() async throws {
    let provider = try AppleSpeechSynthesis(context: ModelContext())
    for _ in 0..<4 {
        let session = try await provider.synthesize(SpeechSynthesisRequest(text: "你好。", locale: "auto"))
        var completed = false
        for try await event in session.events { if case .finished = event { completed = true } }
        session.cancel()
        #expect(completed)
    }
}

@Test func systemSpeechAutoLocaleResolvesChineseEnglishAndAliases() {
    #expect(AppleSpeechSynthesis.language(text: "你好，hello。", locale: "auto") == "zh-CN")
    #expect(AppleSpeechSynthesis.language(text: "Hello, 123.", locale: "auto") == "en-US")
    #expect(AppleSpeechSynthesis.language(text: "𠀀", locale: "auto") == "zh-CN")
    #expect(AppleSpeechSynthesis.language(text: "Hello", locale: "zh_Hant") == "zh-TW")
    #expect(AppleSpeechSynthesis.language(text: "你好", locale: "en-GB") == "en-GB")
}

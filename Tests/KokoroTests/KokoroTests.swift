import AVFAudio
import Foundation
@_spi(ModelManagement) import ModelKit
import Testing

@testable import ModelKitKokoro

@Test func rejectsUnsupportedLanguageAndAmbiguousNumbers() throws {
    try KokoroInput.validate(text: "Hello world!", locale: "en-US")
    for (text, locale) in [("こんにちは", "ja-JP"), ("Hello 你好", "en-US"), ("3.14", "en-US"), ("!!!", "en-US")] {
        #expect(throws: CapabilityError.self) { try KokoroInput.validate(text: text, locale: locale) }
    }
}

@Test func routesMandarinEnglishAndMixedTextWithoutLosingWords() throws {
    let zh = try KokoroInput.segments(text: "你好，今天是2026年9月28日。", locale: "auto")
    #expect(zh.allSatisfy { $0.language == .mandarin })
    let mixed = try KokoroInput.segments(text: "你好，Hello world，再见。", locale: "auto")
    #expect(mixed.map(\.language) == [.mandarin, .english, .mandarin])
    #expect(mixed.map(\.text).joined() == "你好，Hello world，再见。")
    let long = String(repeating: "你好", count: 200)
    let parts = try KokoroInput.segments(text: long, locale: "zh-CN")
    #expect(parts.map(\.text).joined() == long)
    #expect(parts.allSatisfy { $0.text.count <= 60 })
    #expect(throws: CapabilityError.self) {
        _ = try KokoroInput.segments(text: String(repeating: "你hi", count: 40), locale: "auto")
    }
    #expect(throws: CapabilityError.self) { try KokoroInput.validate(text: "안녕하세요", locale: "auto") }
}

@Test func chunkingPreservesWordsAndBounds() throws {
    let text = Array(repeating: "hello", count: 60).joined(separator: " ")
    let chunks = try KokoroInput.chunks(text) { $0.count + 2 }
    #expect(chunks.joined(separator: " ") == text)
    #expect(chunks.allSatisfy { $0.count + 2 <= 128 })
    #expect(throws: CapabilityError.self) {
        _ = try KokoroInput.chunks(String(repeating: "x", count: 129)) { $0.count + 2 }
    }
}

@Test func dictionaryPrefersExactCaseNormalizesIntegersAndMixedPunctuation() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let cache = folder.appendingPathComponent("lexicon.json")
    try Data(
        #"{"lower":{"hello":["lower"],"forty":["forty"],"two":["two"]},"caseSensitive":{"hello":["exact"],"X":["eks"]}}"#
            .utf8
    ).write(to: cache)
    let g2p = try KokoroG2P(cacheURL: cache)
    #expect(g2p.phonemize("hello 42 X!") == "exact forty two eks!")
    #expect(g2p.phonemize("hello，X。") == "exact, eks.")
}

#if canImport(CoreML)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_TEST_KOKORO"] == "1"))
    @available(macOS 27, iOS 27, *)
    func realKokoroSynthesis() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["HARNESS_KOKORO_MODEL_ROOT"])
        let models = URL(fileURLWithPath: path)
        let providerContext = ModelContext()
        let provider = try KokoroSpeechSynthesis(
            context: providerContext,
            artifacts: models)
        let clock = ContinuousClock()
        let load = clock.now
        try await providerContext.load()
        print("Kokoro load: \(load.duration(to: clock.now))")
        let texts = [
            "The quick brown fox jumps over the lazy dog.", "你好，今天天气很好。", "你好，Hello world，再见。",
            "今天是2026年9月28日，价格是3.14元。",
        ]
        for (run, text) in texts.enumerated() {
            let start = clock.now
            let session = try await provider.synthesize(
                SpeechSynthesisRequest(
                    text: text, locale: "auto"))
            await #expect(throws: CapabilityError.inputBusy) {
                _ = try await provider.synthesize(SpeechSynthesisRequest(text: "Hello", locale: "en-US"))
            }
            var samples: [Float] = []
            var finished = 0
            var sequence: UInt64 = 0
            for try await event in session.events {
                switch event {
                case .audio(let frame):
                    if samples.isEmpty { print("Kokoro run \(run) first PCM: \(start.duration(to: clock.now))") }
                    #expect(frame.sequence == sequence)
                    #expect(frame.timestamp == Double(samples.count) / 24_000)
                    sequence += 1
                    samples += frame.data.withUnsafeBytes { bytes in
                        (0..<frame.sampleCount).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
                    }
                case .finished: finished += 1
                }
            }
            #expect(finished == 1)
            #expect(samples.count > 24_000 && samples.allSatisfy(\.isFinite))
            #expect(samples.contains { abs($0) > 0.01 })
            print("Kokoro run \(run): total=\(start.duration(to: clock.now)), audio=\(Double(samples.count) / 24_000)s")
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
            let buffer = try #require(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
            buffer.frameLength = buffer.frameCapacity
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
            }
            let file = try AVAudioFile(
                forWriting: URL(fileURLWithPath: "/tmp/mobileharness-kokoro-\(run).wav"), settings: format.settings)
            try file.write(from: buffer)
        }
        let session = try await provider.synthesize(SpeechSynthesisRequest(text: "Hello world.", locale: "en-US"))
        session.cancel()
        do {
            for try await _ in session.events { Issue.record("Cancelled session emitted audio") }
        } catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
        try await providerContext.unload()
        #expect(await providerContext.status == .unloaded)
    }
#endif

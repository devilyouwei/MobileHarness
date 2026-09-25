import AVFAudio
import Foundation
@_spi(ModelManagement) import ModelKit
import Testing

@testable import ModelKitKokoro

@Test func rejectsUnsupportedLanguageAndAmbiguousNumbers() throws {
    try KokoroInput.validate(text: "Hello world!", locale: "en-US")
    for (text, locale) in [("你好", "zh-CN"), ("Hello 你好", "en-US"), ("3.14", "en-US"), ("!!!", "en-US")] {
        #expect(throws: CapabilityError.self) { try KokoroInput.validate(text: text, locale: locale) }
    }
}

@Test func alignmentMatchesTorchRoundingAndRejectsTruncation() throws {
    let (alignment, mask, total) = try KokoroInput.alignment(duration: [2.5, 3.5, 0])
    #expect(total == 7)
    #expect(alignment[0] == 1 && alignment[1] == 1 && alignment[2] == 0)
    #expect(alignment[512 + 2] == 1 && alignment[512 + 5] == 1)
    #expect(mask.reduce(0, +) == 7)
    for duration: [Float] in [[300, 300], [.nan, 1], [.infinity, 1], [-1, 1]] {
        #expect(throws: CapabilityError.self) { _ = try KokoroInput.alignment(duration: duration) }
    }
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

@Test func dictionaryPrefersGoldAndNormalizesIntegers() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let gold = folder.appendingPathComponent("gold.json")
    let silver = folder.appendingPathComponent("silver.json")
    try Data(#"{"hello":"gold","forty":"forty","two":"two","X":"eks"}"#.utf8).write(to: gold)
    try Data(#"{"hello":"silver"}"#.utf8).write(to: silver)
    let g2p = try KokoroG2P(goldURL: gold, silverURL: silver)
    #expect(g2p.phonemize("hello 42 X!") == "gold forty two eks!")
}

#if canImport(CoreAI)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_TEST_KOKORO"] == "1"))
    @available(macOS 27, iOS 27, *)
    func realKokoroSynthesis() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let models = repository.appendingPathComponent("MobileHarness/Resources/Models")
        let providerContext = ModelContext()
        let provider = try KokoroSpeechSynthesis(
            context: providerContext,
            artifacts: models.appendingPathComponent("Kokoro"))
        let clock = ContinuousClock()
        let load = clock.now
        try await providerContext.load()
        print("Kokoro load: \(load.duration(to: clock.now))")
        for run in 0..<2 {
            let start = clock.now
            let session = try await provider.synthesize(
                SpeechSynthesisRequest(
                    text: "The quick brown fox jumps over the lazy dog.", locale: "en-US"))
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
    }
#endif

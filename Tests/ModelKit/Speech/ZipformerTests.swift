import AVFAudio
import Foundation
@_spi(ModelManagement) import ModelKit
import Testing

@testable import ModelKitZipformer

@Test func zipformerFilterbankMatchesKaldiAcrossPacketBoundaries() throws {
    let samples = (0..<1024).map { Float(($0 * 37) % 127 - 63) / 256 }
    let split = try ZipformerFilterbank()
    let frames = split.accept(Array(samples.prefix(223))) + split.accept(Array(samples.dropFirst(223)))
    let single = try ZipformerFilterbank().accept(samples)
    #expect(frames == single)
    #expect(frames.count == 5)
    let bins = [0, 7, 25, 44, 64, 79]
    let expected: [Float] = [-11.706858, -6.218102, -2.865175, 2.142111, 2.692550, 4.204828]
    let first = try #require(frames.first)
    for (bin, reference) in zip(bins, expected) {
        #expect(abs(first[bin] - reference) < 0.001)
    }
}

@Test func zipformerColdModelDoesNotOpenOrTryLoading() async throws {
    let context = try ModelContext(loadGate: ModelLoadGate(maximumConcurrentLoads: 1), maximumLoadWaiters: 2)
    let model = try ZipformerKeywordSpotter(
        context: context, artifacts: URL(fileURLWithPath: "/unused-zipformer-fixture"))
    let session = try await model.openKeywords([.init(label: "stop", tokens: ["S", "T", "AA1", "P"])])
    #expect(session == nil)
}

@Test(arguments: [
    ([4, 5, 0], nil),
    ([4, 5, 0, 0], "stop"),
    ([4, 5, 0, 6, 0], "stop-talking"),
    ([7, 4, 5, 0, 0, 0, 0], nil),
])
func zipformerStandaloneCommandDoesNotStealAPrefixOrSuffix(_ tokens: [Int], _ expected: String?) async throws {
    var decoder = ZipformerKeywordDecoder(keywords: [
        [4, 5]: .init(label: "stop", tokens: ["stop"], standalone: true),
        [4, 5, 6]: .init(label: "stop-talking", tokens: ["stop", "talking"]),
    ])
    var hit: String?
    for token in tokens where hit == nil {
        hit = try await decoder.accept(
            [], decode: { _ in [] },
            join: { _, _ in
                var logits = Array(repeating: Float(-100), count: 263)
                logits[token] = 10
                return logits
            })
    }
    #expect(hit == expected)
}

@Test(arguments: [Float(0.20), Float(0.25)])
func zipformerUsesTheConfiguredKeywordConfidence(_ threshold: Float) async throws {
    var decoder = ZipformerKeywordDecoder(keywords: [
        [4]: .init(label: "keyword", tokens: ["word"], threshold: threshold)
    ])
    let first = try await decoder.accept(
        [], decode: { _ in [] },
        join: { _, _ in
            var logits = Array(repeating: Float(-100), count: 263)
            logits[4] = log(0.22)
            for token in 5...7 { logits[token] = log(0.26) }
            return logits
        })
    #expect(first == nil)
    let hit = try await decoder.accept(
        [], decode: { _ in [] },
        join: { _, _ in
            var logits = Array(repeating: Float(-100), count: 263)
            logits[0] = 10
            return logits
        })
    #expect(hit == (threshold == 0.20 ? "keyword" : nil))
}

@Test(
    .enabled(
        if:
            ProcessInfo.processInfo.environment["HARNESS_TEST_ZIPFORMER_MODEL"] != nil
            && ProcessInfo.processInfo.environment["HARNESS_TEST_ZIPFORMER_WAV"] != nil))
func zipformerPublishedArtifactSmoke() async throws {
    let environment = ProcessInfo.processInfo.environment
    let path = try #require(environment["HARNESS_TEST_ZIPFORMER_MODEL"])
    let audio = try #require(environment["HARNESS_TEST_ZIPFORMER_WAV"])
    let expected = environment["HARNESS_TEST_ZIPFORMER_LABEL"] ?? "en-please-stop"

    let context = try ModelContext(loadGate: ModelLoadGate(maximumConcurrentLoads: 1), maximumLoadWaiters: 2)
    let model = try ZipformerKeywordSpotter(context: context, artifacts: URL(fileURLWithPath: path))
    try await context.load()
    let session = try #require(
        try await model.openKeywords([
            .init(label: "zh-stop-talking", tokens: ["x", "iān", "b", "ié", "sh", "uō", "l", "e"]),
            .init(label: "zh-stop-playback", tokens: ["t", "íng", "zh", "ǐ", "b", "ō", "b", "ào"]),
            .init(label: "en-please-stop", tokens: ["P", "L", "IY1", "Z", "S", "T", "AA1", "P"]),
            .init(label: "en-stop-talking", tokens: ["S", "T", "AA1", "P", "T", "AO1", "K", "IH0", "NG"]),
            .init(label: "en-stop", tokens: ["S", "T", "AA1", "P"], standalone: true),
            .init(label: "zh-stop", tokens: ["t", "íng", "x", "ià"], standalone: true),
        ]))
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: audio))
    #expect(file.processingFormat.sampleRate == 16000)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 512))
    var match: KeywordSpottingMatch?
    while file.framePosition < file.length, match == nil {
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?.pointee)
        match = try await session.accept(Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
    }
    for _ in 0..<16 where match == nil { match = try await session.accept(Array(repeating: 0, count: 512)) }
    await session.cancel()
    #expect(match?.label == (expected.isEmpty ? nil : expected))
    if let match {
        #expect(match.metadata.model == ZipformerKeywordSpotter.modelIdentity)
        #expect(match.metadata.inferenceDuration > .zero)
    }
}

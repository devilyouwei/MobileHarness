import Foundation
@_spi(ModelManagement) import ModelKit
import Testing

@testable import ModelKitMossCoreML
@testable import ModelKitMossNano

@Test func mossVoiceSelectionAndInputBounds() throws {
    #expect(try MossInput.chineseVoice(text: "你好 Hello", locale: "auto"))
    #expect(try !MossInput.chineseVoice(text: "Hello", locale: "auto"))
    #expect(try MossInput.chineseVoice(text: "123", locale: "zh_CN"))
    #expect(throws: CapabilityError.self) { try MossInput.chineseVoice(text: "hello", locale: "fr") }
    #expect(throws: CapabilityError.self) {
        try MossInput.chineseVoice(text: String(repeating: "中", count: 683), locale: "auto")
    }
}

@Test func mossPCMDownmixTimingAndLimits() throws {
    var encoder = MossPCMEncoder()
    let frames = try encoder.encode(
        left: [Float](repeating: 1, count: 3840), right: [Float](repeating: -0.5, count: 3840))
    #expect(frames.count == 1)
    #expect(frames[0].format.sampleRate == 48_000)
    #expect(frames[0].format.channels == 1)
    #expect(frames[0].duration == 0.08)
    #expect(frames[0].data.withUnsafeBytes { $0.loadUnaligned(as: Float.self) } == 0.25)
    let pause = [Float](repeating: 0, count: 19_200)
    let next = try encoder.encode(left: pause, right: pause)
    #expect(next.count == 5)
    #expect(next[0].timestamp == 0.08)
    #expect(next.map(\.sequence) == [1, 2, 3, 4, 5])
    #expect(next.reduce(0) { $0 + $1.sampleCount } == 19_200)
    #expect(next.allSatisfy { $0.data.count <= 16_384 })
    #expect(throws: CapabilityError.self) { try encoder.encode(left: [.nan], right: [0]) }
    #expect(throws: CapabilityError.self) { try encoder.encode(left: [0, 1], right: [0]) }
    var bounded = MossPCMEncoder()
    for _ in 0..<150 { _ = try bounded.encode(left: pause, right: pause) }
    #expect(throws: CapabilityError.self) { try bounded.encode(left: [0], right: [0]) }
}

@Test func mossTokenizerNormalizationAndMalformedResource() throws {
    #expect(MossTtsNanoTokenizer.normalize("  ｈｅｌｌｏ\t世界  ") == "▁hello▁世界")
    #expect(throws: (any Error).self) { try MossTtsNanoTokenizer(modelData: Data()) }
}

@Test func mossMissingResourcesFailWithoutFallback() async throws {
    guard #available(macOS 27, iOS 27, *) else { return }
    let context = ModelContext()
    let provider = try MossSpeechSynthesis(context: context, artifacts: URL(fileURLWithPath: "/missing-moss-models"))
    if case .available = await provider.availability { Issue.record("Missing resources must be unavailable") }
    let session = try await provider.synthesize(SpeechSynthesisRequest(text: "你好", locale: "auto"))
    await #expect(throws: (any Error).self) {
        for try await _ in session.events {}
    }
    await context.shutdown()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_TEST_MOSS"] == "1"))
func realMossChineseEnglishAndLifecycle() async throws {
    guard #available(macOS 27, iOS 27, *) else { return }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("MobileHarness/Resources/Models/MossTTSNano")
    let tokenizer = try MossTtsNanoTokenizer(modelURL: root.appendingPathComponent("tokenizer.model"))
    #expect(
        tokenizer.encode("欢迎关注模思智能、上海创智学院与复旦大学自然语言处理实验室。") == [
            8651, 2691, 11099, 10670, 7669, 10508, 4627, 11074, 11315, 6439, 10617, 10859, 11643, 2957, 1531, 4139,
            2305, 4146, 11255, 10382,
        ])
    let context = ModelContext()
    let provider = try MossSpeechSynthesis(context: context, artifacts: root)
    try await provider.warmup()
    for text in ["你好，欢迎使用语音助手。", "Hello, welcome to our voice assistant.", "今天是九月二十八日，Hello world。"] {
        let clock = ContinuousClock()
        let started = clock.now
        let session = try await provider.synthesize(SpeechSynthesisRequest(text: text, locale: "auto"))
        await #expect(throws: CapabilityError.inputBusy) {
            _ = try await provider.synthesize(SpeechSynthesisRequest(text: "Busy", locale: "en-US"))
        }
        var bytes = 0
        var finished = false
        var first: Duration?
        var nonzero = false
        for try await event in session.events {
            switch event {
            case .audio(let frame):
                if first == nil { first = started.duration(to: clock.now) }
                #expect(frame.format.sampleRate == 48_000)
                bytes += frame.data.count
                let values = frame.data.withUnsafeBytes { raw in
                    (0..<frame.sampleCount).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
                }
                #expect(values.allSatisfy { $0.isFinite })
                nonzero = nonzero || values.contains { abs($0) > 0.0001 }
            case .finished: finished = true
            }
        }
        #expect(finished && bytes > 0 && nonzero)
        print(
            "MOSS smoke: first=\(String(describing: first)), elapsed=\(started.duration(to: clock.now)), audioSeconds=\(Double(bytes)/192_000)"
        )
    }
    let pending = try await provider.synthesize(SpeechSynthesisRequest(text: "取消这段语音。", locale: "auto"))
    pending.cancel()
    try await context.unload()
    try await context.load()
    await context.shutdown()
    let closed = try await provider.synthesize(SpeechSynthesisRequest(text: "你好", locale: "auto"))
    await #expect(throws: CapabilityError.sessionClosed) { for try await _ in closed.events {} }
}

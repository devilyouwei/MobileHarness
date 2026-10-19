import Foundation
import Testing

@testable import UI

@Test func finalTranscriptPromotesTheCompleteRecognitionEvenDuringSuffixFade() {
    let recognized = "把摄像头关了。"
    let partial = CaptionPresentation(previous: "把摄像", text: recognized)
    #expect(partial.text == recognized && partial.stableUTF16Count == 3 && partial.animatesSuffix)
    let promoted = CaptionPresentation(previous: partial.text, text: recognized, finalized: true)
    #expect(promoted.text == recognized)
    #expect(promoted.revisedRange.length == 0 && promoted.stableUTF16Count == recognized.utf16.count)
    #expect(!promoted.animatesSuffix)
}

@Test func finalCaptionCorrectionNeverRetainsThePartialOrAnAnimationDependentTail() {
    let final = "把摄像头关了。"
    let corrected = CaptionPresentation(previous: "把摄像头打开", text: final, finalized: true)
    #expect(corrected.text == final && corrected.revisedRange.length == 0 && !corrected.animatesSuffix)
    let empty = CaptionPresentation(previous: final, text: "", finalized: true)
    #expect(empty.text.isEmpty && empty.revisedRange == NSRange(location: 0, length: 0))
}

@Test func captionRangesNeverSplitUnicodeGraphemes() {
    let prefix = "👨‍👩‍👧‍👦e\u{301}把摄"
    let next = prefix + "像头关了。"
    let value = CaptionPresentation(previous: prefix, text: next)
    #expect(value.stableUTF16Count == prefix.utf16.count)
    #expect((value.text as NSString).substring(with: value.revisedRange) == "像头关了。")
    #expect(value.text == next)
}

@Test func captionAlwaysRendersTheLatestBoundedValueAcrossRapidReplacements() {
    var current = CaptionPresentation(previous: "", text: "把")
    for text in ["把摄", "把摄像", "把摄像头打开", "把摄像头关了。"] {
        current = CaptionPresentation(previous: current.text, text: text)
        #expect(current.text == text)
    }
    let repeated = CaptionPresentation(previous: current.text, text: current.text)
    #expect(repeated.revisedRange.length == 0 && !repeated.animatesSuffix)
}

@Test func captionLimitRetainsWholeCharactersAndReduceMotionShowsEverythingImmediately() {
    let original = "前缀" + String(repeating: "👨‍👩‍👧‍👦", count: 319) + "关"
    let value = CaptionPresentation(previous: "", text: original, reduceMotion: true)
    #expect(value.text.count == 320 && value.text == String(original.suffix(320)))
    #expect(value.revisedRange.length == 0 && !value.animatesSuffix)
    #expect(original.hasPrefix("前缀") && original.count == 322)
}

@Test func captionRendererPreservesExistingFadeProgressAcrossAppendAndCorrection() throws {
    let start = ContinuousClock.now
    var state = CaptionRenderState()
    state.update("把摄", at: start)
    state.update("把摄像头", at: start.advanced(by: .milliseconds(100)))
    #expect(state.text == "把摄像头" && state.runs.count == 2)
    #expect(state.runs.first?.appearedAt == start)
    #expect(state.runs.last?.appearedAt == start.advanced(by: .milliseconds(100)))
    let early = CaptionRenderRun.opacity(
        appearedAt: state.runs.first?.appearedAt, at: start.advanced(by: .milliseconds(100)))
    #expect(early > 0.15 && early < 1)
    state.update("把摄像头关了", at: start.advanced(by: .milliseconds(300)))
    #expect(state.runs.first?.text == "把摄")
    #expect(state.runs.first?.appearedAt == nil)
    #expect(state.runs.map(\.text).joined() == state.text)
    state.update("把摄像头开了", finalized: true, at: start.advanced(by: .milliseconds(310)))
    #expect(state.text == "把摄像头开了" && state.runs.count == 1)
    #expect(!state.isAnimating(at: start.advanced(by: .milliseconds(310))))
}

@Test func captionRendererWindowShiftPreservesOldGlyphsAndRecognizesIdenticalNewCharacters() {
    let start = ContinuousClock.now
    var state = CaptionRenderState()
    let initial = String(repeating: "字", count: 320)
    state.update(initial, at: start)
    state.settle()
    state.update(initial + "字", at: start.advanced(by: .milliseconds(100)))
    #expect(state.text.count == 320 && state.runs.count == 2)
    #expect(state.runs.first?.text.count == 319 && state.runs.first?.appearedAt == nil)
    #expect(state.runs.last?.text == "字" && state.runs.last?.appearedAt != nil)
    state.update(initial + "字新", at: start.advanced(by: .milliseconds(150)))
    #expect(state.runs.map(\.text).joined() == String((initial + "字新").suffix(320)))
    #expect(state.runs.dropFirst().first?.appearedAt == start.advanced(by: .milliseconds(100)))
    state.update(initial + String(repeating: "全", count: 400), at: start.advanced(by: .milliseconds(200)))
    #expect(state.text == String(repeating: "全", count: 320))
    #expect(state.runs.count == 1 && state.runs.first?.appearedAt == start.advanced(by: .milliseconds(200)))
}

@Test func captionRendererCombiningAppendAndUnicodeRevisionNeverSplitGraphemes() {
    let start = ContinuousClock.now
    var state = CaptionRenderState()
    let initial = String(repeating: "👨‍👩‍👧‍👦", count: 319) + "e"
    state.update(initial, animated: false, at: start)
    state.update(initial + "\u{301}", at: start)
    #expect(state.text.count == 320)
    #expect(state.runs.first?.text.count == 319 && state.runs.first?.appearedAt == nil)
    #expect(state.runs.last?.text == "e\u{301}")
    #expect(state.runs.map(\.text).joined() == state.text)
    state.update("中文\n👩🏽‍💻完成", at: start)
    #expect(state.runs.map(\.text).joined() == "中文\n👩🏽‍💻完成")
}

@Test func captionRendererClearSettlementAndReducedMotionDoNotReplayOldFades() {
    let start = ContinuousClock.now
    var state = CaptionRenderState()
    state.update("回复", at: start)
    #expect(state.isAnimating(at: start))
    #expect(!state.isAnimating(at: start.advanced(by: .milliseconds(250))))
    #expect(CaptionRenderRun.opacity(appearedAt: start, at: start.advanced(by: .milliseconds(250))) == 1)
    state.settle()
    state.update("回复", at: start.advanced(by: .seconds(1)))
    #expect(state.runs.first?.appearedAt == nil)
    state.update("回复新增", animated: false, at: start)
    #expect(state.runs.count == 1 && !state.isAnimating(at: start))
    state.update("", at: start)
    #expect(state.text.isEmpty && state.runs.isEmpty && !state.isAnimating(at: start))
    state.update("新会话", at: start)
    #expect(state.isAnimating(at: start) && state.text == "新会话")
}

#if os(iOS) || os(macOS)
    import CoreGraphics
    import SwiftUI

    @MainActor private func renderedCaptionAlpha(
        _ runs: [CaptionRenderRun], time: ContinuousClock.Instant, forceVisible: Bool = false, prefixWidth: Int? = nil
    ) throws -> UInt64 {
        let content = captionText(runs)
            .font(.system(size: 32, design: .monospaced))
            .foregroundStyle(.white)
            .textRenderer(CaptionTextRenderer(time: time, forceVisible: forceVisible))
            .frame(width: 200, height: 80, alignment: .topLeading)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        return try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(
                CGContext(
                    data: bytes.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let width = min(prefixWidth ?? image.width, image.width)
            var total: UInt64 = 0
            for y in 0..<image.height {
                for x in 0..<width { total += UInt64(bytes[y * image.width * 4 + x * 4 + 3]) }
            }
            return total
        }
    }

    @Test @MainActor func captionTextRendererActuallyFadesOnlyNewRunsAndFinalTextRemainsVisible() throws {
        let start = ContinuousClock.now
        var state = CaptionRenderState()
        state.update("A", animated: false, at: start)
        state.update("AB", at: start)
        let fullTime = start.advanced(by: .milliseconds(250))
        let early = try renderedCaptionAlpha(state.runs, time: start)
        let full = try renderedCaptionAlpha(state.runs, time: fullTime)
        let forced = try renderedCaptionAlpha(state.runs, time: start, forceVisible: true)
        #expect(early > 0 && full > early && forced == full)
        let stableEarly = try renderedCaptionAlpha(state.runs, time: start, prefixWidth: 18)
        let stableFull = try renderedCaptionAlpha(state.runs, time: fullTime, prefixWidth: 18)
        #expect(stableEarly > 0 && stableEarly == stableFull)
    }
#endif

@Test @MainActor func homePreparationGatePreservesActiveStopAndVoicePresentation() async throws {
    let root = UIContainer()
    try root.start()
    try root.setForeground(true)
    let state = root.home.conversation
    state.isReady = true
    state.voicePhase = .idle
    root.home.presentModelPreparation(.preparing("language"))
    #expect(state.showsModelPreparation && !state.allowsHomeInteraction)
    #expect(state.voicePhase == .idle)
    state.isVoiceActive = true
    state.voicePhase = .listening
    #expect(!state.showsModelPreparation && state.allowsHomeInteraction)
    root.home.presentModelPreparation(.failed(component: "language", message: "fixture"))
    #expect(state.allowsHomeInteraction && state.voicePhase == .listening)
    state.isVoiceActive = false
    #expect(!state.allowsHomeInteraction)
    root.home.presentModelPreparation(.ready)
    #expect(state.allowsHomeInteraction && !state.showsModelPreparation)
    await root.stop()
}

@Test @MainActor func homePreparationPresentationRejectsInactiveAndStoppedRoots() async throws {
    let root = UIContainer()
    root.home.presentModelPreparation(.ready)
    #expect(root.home.conversation.modelPreparation == .inactive)
    try root.start()
    try root.setForeground(true)
    root.home.presentModelPreparation(.ready)
    root.invalidate()
    root.home.presentModelPreparation(.ready)
    #expect(root.home.conversation.modelPreparation == .inactive)
    await root.stop()
    root.home.presentModelPreparation(.preparing("language"))
    #expect(root.home.conversation.modelPreparation == .inactive)
    let next = UIContainer()
    try next.start()
    try next.setForeground(true)
    next.home.presentModelPreparation(.ready)
    root.home.presentModelPreparation(.cancelled)
    #expect(next.home.conversation.modelPreparation == .ready)
    await next.stop()
}

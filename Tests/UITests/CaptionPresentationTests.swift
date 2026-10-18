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

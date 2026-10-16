import Actions
import Foundation
import PlatformKit
import StorageCore
import Testing

@Test func photoFeedbackReceiptsDecodeOlderDataAndKeepActualSaveSeparateFromIssues() throws {
    let id = UUID().uuidString
    let old = Data("{\"mediaID\":\"\(id)\",\"state\":\"saved\",\"alreadySaved\":true}".utf8)
    let receipt = try JSONDecoder().decode(CameraPhotoCommandReceipt.self, from: old)
    #expect(receipt.mediaID == id && receipt.alreadySaved && receipt.feedbackIssues == nil)
    let committed = CameraPhotoCommandReceipt(mediaID: id, state: .saved, feedbackIssues: ["sound: failed"])
    #expect(
        try JSONDecoder().decode(CameraPhotoCommandReceipt.self, from: JSONEncoder().encode(committed)) == committed)
    #expect(committed.state == .saved)
}

@Test func shortCueWAVRetainsHeaderRateAndActualSignedSamples() throws {
    let data = try PCMClipEncoding.wav16(samples: [-1, 0, 1], sampleRate: 48000)
    #expect(data.count == 50)
    #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
    #expect(String(decoding: data[8..<16], as: UTF8.self) == "WAVEfmt ")
    #expect(Array(data[24..<28]) == [0x80, 0xbb, 0, 0])
    #expect(Array(data[44..<50]) == [1, 0x80, 0, 0, 0xff, 0x7f])
}

@Test(arguments: [[Float](), [Float.nan], [Float.infinity], [1.01], Array(repeating: Float(0), count: 48001)])
func invalidShortCuePCMNeverProducesPlayableBytes(_ samples: [Float]) async {
    #expect(throws: PCMClipEncoding.Failure.self) { try PCMClipEncoding.wav16(samples: samples, sampleRate: 48000) }
}

@Test(arguments: [0, 7999, 192001, Int.max]) func invalidShortCueRateRejectsBeforeHeaderArithmetic(_ rate: Int) {
    #expect(throws: PCMClipEncoding.Failure.self) { try PCMClipEncoding.wav16(samples: [0], sampleRate: rate) }
}

@Test func saveAndDiscardHaveDistinctBoundedNativeCuePayloads() throws {
    let saved = try FeedbackTone.samples(for: .init(cue: .save))
    let discarded = try FeedbackTone.samples(for: .init(cue: .discard))
    let saveWAV = try PCMClipEncoding.wav16(samples: saved, sampleRate: FeedbackTone.sampleRate)
    let discardWAV = try PCMClipEncoding.wav16(samples: discarded, sampleRate: FeedbackTone.sampleRate)
    #expect(saveWAV != discardWAV && saved.count == 29760 && discarded.count == 27840)
}

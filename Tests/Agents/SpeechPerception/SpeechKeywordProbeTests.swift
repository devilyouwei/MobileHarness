import Foundation
import ModelKit
import Testing

@testable import Agents

private actor MatchingKeywordModel: KeywordSpottingCapability, KeywordSpottingSession {
    var received = 0
    var cancelled = false
    private(set) var thresholds: [Float] = []
    let label: String?
    var availability: CapabilityAvailability { .available }
    init(label: String? = "zh-stop") { self.label = label }

    func openKeywords(_ keywords: [SpeechKeyword]) -> (any KeywordSpottingSession)? {
        thresholds = keywords.map(\.threshold)
        return keywords.isEmpty ? nil : self
    }

    func accept(_ samples: [Float]) throws -> String? {
        received += samples.count
        return received >= 2560 ? label : nil
    }

    func cancel() { cancelled = true }
}

@Test(arguments: [false, true]) func keywordTestReportsRawHitIrrespectiveOfTail(silent: Bool) async throws {
    let model = MatchingKeywordModel()
    let session = try #require(await model.openKeywords(SpeechKeywordProbe.keywords))
    let trial = SpeechKeywordTest(session: session, reopen: { model })
    let packet = Array(repeating: Float(silent ? 0 : 0.01), count: 512)
    for _ in 0..<4 { #expect(try await trial.accept(packet).hit == nil) }
    let update = try await trial.accept(packet)
    let hit = try #require(update.hit)
    #expect(hit.phrase == "停下")
    #expect(hit.silentTail == silent)
    #expect(update.audio?.samples == 2560)
    #expect(await model.cancelled)
    #expect(try await trial.accept(packet).hit == nil)
}

@Test func keywordTestReopensOnSpeechAfterAQuietGap() async throws {
    let initial = MatchingKeywordModel(label: nil)
    let next = MatchingKeywordModel()
    let trial = SpeechKeywordTest(session: initial, reopen: { next })
    let audible = [Float](repeating: 0.03, count: 512)
    let quiet = [Float](repeating: 0, count: 512)
    _ = try await trial.accept(audible)
    for _ in 0..<19 { _ = try await trial.accept(quiet) }
    #expect(await !initial.cancelled)
    _ = try await trial.accept(audible)
    #expect(await initial.cancelled)
    #expect(await next.received == 1600 + 512)
    let update = try await trial.accept(quiet)
    #expect(update.hit?.phrase == "停下")
    #expect(update.audio?.samples == 22 * 512)
}

@Test func keywordProbeAppliesSilentTailAtFirstMatch() async {
    for silent in [false, true] {
        let capability = MatchingKeywordModel()
        let reply = UUID()
        let capture = UUID()
        let events = AsyncStream.makeStream(of: UUID.self)
        let probe = SpeechKeywordProbe(capability: capability, replyID: reply, captureID: capture, threshold: 0.20) {
            match in
            events.continuation.yield(match)
            events.continuation.finish()
        }
        #expect(probe.replyID == reply)
        #expect(probe.captureID == capture)
        #expect(probe.submit(Array(repeating: silent ? 0 : 0.01, count: 2560)))
        await probe.finished()
        events.continuation.finish()
        var iterator = events.stream.makeAsyncIterator()
        #expect(await iterator.next() == (silent ? probe.id : nil))
        #expect(await capability.cancelled)
        #expect(await capability.thresholds == Array(repeating: Float(0.20), count: 6))
    }
}

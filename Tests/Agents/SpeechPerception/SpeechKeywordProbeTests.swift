import AgentCore
import Foundation
import ModelKit
import Testing

@testable import Agents

actor MatchingKeywordModel: KeywordSpottingCapability, KeywordSpottingSession {
    static let metadata = KeywordSpottingMatch.Metadata(
        model: .init(modelID: "fixture-kws", displayName: "Keyword Fixture"), inferenceDuration: .milliseconds(12))
    var received = 0
    var cancelled = false
    private(set) var thresholds: [Float] = []
    let label: String?
    let minimumSamples: Int
    var availability: CapabilityAvailability { .available }
    init(label: String? = "zh-stop", minimumSamples: Int = 2560) {
        self.label = label
        self.minimumSamples = minimumSamples
    }

    func openKeywords(_ keywords: [SpeechKeyword]) -> (any KeywordSpottingSession)? {
        thresholds = keywords.map(\.threshold)
        return keywords.isEmpty ? nil : self
    }

    func accept(_ samples: [Float]) throws -> KeywordSpottingMatch? {
        received += samples.count
        guard received >= minimumSamples, let label else { return nil }
        return .init(label: label, metadata: Self.metadata)
    }

    func cancel() { cancelled = true }
}

@Test(arguments: [false, true]) func keywordTestReportsRawHitIrrespectiveOfTail(silent: Bool) async throws {
    let model = MatchingKeywordModel()
    let session = try #require(await model.openKeywords(try SpeechKeywordLexicon.load().keywords()))
    let trial = SpeechKeywordTest(session: session, lexicon: try SpeechKeywordLexicon.load(), reopen: { model })
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
    let trial = SpeechKeywordTest(session: initial, lexicon: try SpeechKeywordLexicon.load(), reopen: { next })
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

@Test func keywordProbeAppliesSilentTailAtFirstMatch() async throws {
    let keywords = try SpeechKeywordLexicon.load().keywords(threshold: 0.20)
    for silent in [false, true] {
        let capability = MatchingKeywordModel()
        let capture = UUID().uuidString
        let events = AsyncStream.makeStream(of: (UUID, SpeechKeywordProbe.Hit).self)
        let probe = SpeechKeywordProbe(capability: capability, generation: capture, onset: .zero, keywords: keywords) {
            id, hit in
            events.continuation.yield((id, hit))
            events.continuation.finish()
        }
        #expect(probe.generation == capture)
        #expect(probe.submit(Array(repeating: silent ? 0 : 0.01, count: 2560), capturedAt: .zero))
        await probe.finished()
        events.continuation.finish()
        var iterator = events.stream.makeAsyncIterator()
        let match = await iterator.next()
        #expect(match?.0 == (silent ? probe.id : nil))
        if silent {
            #expect(match?.1.result.label == "zh-stop" && match?.1.audioEnd == .milliseconds(160))
            #expect(match?.1.result.metadata == MatchingKeywordModel.metadata)
        }
        #expect(await capability.cancelled)
        #expect(await capability.thresholds == Array(repeating: Float(0.20), count: keywords.count))
    }
}

@Test func interruptionKeywordResourcesUseStableZipformerLabels() throws {
    let lexicon = try SpeechKeywordLexicon.load()
    let labels = Set(lexicon.keywords().map(\.label))
    #expect(try InterruptionKeywordPolicy.load().isSubset(of: labels))
    #expect(lexicon.phrase(for: "zh-stop") == "停下")
    #expect(lexicon.phrase(for: "en-stop") == "stop")
    #expect(throws: AgentConfigurationError.self) {
        try SpeechKeywordLexicon.decode(Data(#"{"version":1,"keywords":[]}"#.utf8))
    }
}

import AgentCore
import Foundation
import FunctionContracts
import ModelKit
import OSLog
import PlatformKit
import StorageCore
import UI

extension SpeechPerceptionAgent {
    // MARK: - Streaming keyword probe

    private func retireKeywordProbe() {
        guard let probe = keywordProbe else { return }
        keywordProbe = nil
        probe.cancel()
        keywordRetirement = Task { [weak self] in
            await probe.finished()
            await self?.finishKeywordRetirement()
        }
    }

    private func finishKeywordRetirement() { keywordRetirement = nil }

    func resetKeywordProbe() {
        retireKeywordProbe()
        keywordPreRoll.removeAll(keepingCapacity: true)
        keywordSawSpeech = false
    }

    func updateKeywordProbe(
        _ windows: [VoiceSegmentation.Window], capturedAt: ContinuousClock.Instant
    ) async {
        guard lifecycle == .running, captureOpen, keywordDetectionEnabled, listeningPolicy.fullDuplex,
            let keywordSpotting, let keywordLexicon, let generation = vadGeneration, interactionSessionID != nil
        else { return }
        for window in windows {
            let time = SpeechSignalClock.offset(at: capturedAt + .nanoseconds(window.offset * 62_500))
            let voiced = window.onsetCandidate || window.speaking
            if !voiced {
                if keywordSawSpeech {
                    retireKeywordProbe()
                    keywordPreRoll.removeAll(keepingCapacity: true)
                }
                keywordSawSpeech = false
                keywordPreRoll = Array((keywordPreRoll + window.pcm).suffix(1600))
                continue
            }
            if !keywordSawSpeech {
                keywordSawSpeech = true
                if keywordRetirement == nil {
                    keywordProbe = SpeechKeywordProbe(
                        capability: keywordSpotting, generation: generation, onset: time,
                        keywords: keywordLexicon.keywords(threshold: keywordThreshold)
                    ) { [weak self] id, hit in
                        await self?.receiveKeywordMatch(id, hit: hit)
                    }
                    if !keywordPreRoll.isEmpty,
                        keywordProbe?.submit(
                            keywordPreRoll, capturedAt: time - .nanoseconds(keywordPreRoll.count * 62_500)) == false
                    {
                        retireKeywordProbe()
                    }
                }
                keywordPreRoll.removeAll(keepingCapacity: true)
            }
            if keywordProbe?.submit(window.pcm, capturedAt: time) == false { retireKeywordProbe() }
        }
        await publishKeywordIfReady()
    }

    private func receiveKeywordMatch(_ id: UUID, hit: SpeechKeywordProbe.Hit) async {
        guard keywordProbe?.id == id else { return }
        keywordProbe?.match = hit
        await publishKeywordIfReady()
    }

    private func publishKeywordIfReady() async {
        guard lifecycle == .running, captureOpen, var probe = keywordProbe, let match = probe.match, !probe.delivered,
            probe.generation == vadGeneration, let turn = currentTurn, let interactionSessionID,
            let phrase = keywordLexicon?.phrase(for: match.result.label)
        else { return }
        probe.delivered = true
        keywordProbe = probe
        let metadata = match.result.metadata
        let observation = SpeechKeywordMatch(
            generation: probe.generation, utterance: turn.id, label: match.result.label,
            keyword: phrase, onset: probe.onset, matchedAt: match.audioEnd,
            detection: .init(
                modelID: metadata.model.modelID, modelName: metadata.model.displayName,
                inferenceDuration: metadata.inferenceDuration, completedAt: SpeechSignalClock.offset(at: .now)))
        let parent = AgentInput(
            id: UUID().uuidString, sessionID: interactionSessionID, payload: .event("speech.keyword"), turn: turn)
        do { try await communicate(observation.message(), parent: parent) } catch {
            Logger(subsystem: "dev.mobileharness", category: "SpeechKeyword").error(
                "Keyword match not published: \(String(describing: error), privacy: .public)")
        }
    }
}

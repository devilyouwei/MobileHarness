import Foundation
import ModelKit

/// Segmentation policy is independent of neural VAD state. Endpoint silence counts consecutive VAD windows.
struct SpeechBoundaryPolicy {
    private static let preRollSamples = 4096
    private static let longSilenceWindows = 25
    private static let shortSilenceWindows = 16
    private static let maximumSegmentSamples = 192000
    // VAD normally emits 512-sample windows; preserve padding by samples, not window count.
    private static let endpointPaddingSamples = 3072

    private(set) var isSpeaking = false
    private(set) var streamEvents: [VoiceStreamEvent] = []
    private var preRoll: [AudioFrame] = []
    private var holdback: [AudioFrame] = []
    private var candidate = 0
    private var silentWindows = 0
    private var duration = 0
    private var hasSpeech = false
    mutating func consume(
        _ frame: AudioFrame, probability: Float, threshold: Float, onsetWindows: Int = 8,
        useShortEndpoint: Bool = false,
        onsetThreshold: Float? = nil
    ) -> VoiceSegmentEnd? {
        streamEvents = []
        let threshold = isSpeaking ? threshold : (onsetThreshold ?? threshold)
        if probability >= threshold { hasSpeech = true }
        if !isSpeaking {
            preRoll.append(frame)
            while preRoll.count > 1
                && preRoll.reduce(0, { $0 + $1.sampleCount }) > max(Self.preRollSamples, onsetWindows * 512)
            {
                preRoll.removeFirst()
            }
            candidate = probability >= threshold ? candidate + frame.sampleCount : 0
            guard candidate >= onsetWindows * 512 else { return nil }
            isSpeaking = true
            streamEvents.append(.audio(preRoll))
            duration = preRoll.reduce(0) { $0 + $1.sampleCount }
            preRoll.removeAll()
        } else {
            duration += frame.sampleCount
            if probability >= threshold {
                streamEvents.append(.audio(holdback + [frame]))
                holdback.removeAll(keepingCapacity: true)
            } else {
                holdback.append(frame)
            }
        }
        silentWindows = probability >= threshold ? 0 : silentWindows + 1
        let silenceLimit = useShortEndpoint ? Self.shortSilenceWindows : Self.longSilenceWindows
        if silentWindows >= silenceLimit {
            // Keep 192 ms of endpoint padding; retain in-sentence silence in full.
            if hasSpeech {
                streamEvents.append(.audio(Self.prefix(holdback, sampleLimit: Self.endpointPaddingSamples)))
            }
            streamEvents.append(.end(.silence))
            let nextPreRoll = Self.suffix(holdback, sampleLimit: Self.preRollSamples)
            reset()
            preRoll = nextPreRoll
            return .silence
        }
        if duration >= Self.maximumSegmentSamples {
            streamEvents.append(.audio(holdback))
            streamEvents.append(.end(.maximumDuration))
            holdback.removeAll(keepingCapacity: true)
            duration = 0
            hasSpeech = false
            // Keep speaking and endpoint hysteresis across a model-sized chunk boundary.
            return .maximumDuration
        }
        return nil
    }
    private static func prefix(_ frames: [AudioFrame], sampleLimit: Int) -> [AudioFrame] {
        var result: [AudioFrame] = []
        var samples = 0
        for frame in frames {
            guard samples + frame.sampleCount <= sampleLimit else { break }
            result.append(frame)
            samples += frame.sampleCount
        }
        return result
    }
    private static func suffix(_ frames: [AudioFrame], sampleLimit: Int) -> [AudioFrame] {
        Array(prefix(Array(frames.reversed()), sampleLimit: sampleLimit).reversed())
    }
    var uncommittedFrames: [AudioFrame] { isSpeaking ? holdback : [] }
    mutating func reset() {
        preRoll.removeAll(keepingCapacity: true)
        holdback.removeAll(keepingCapacity: true)
        candidate = 0
        silentWindows = 0
        duration = 0
        hasSpeech = false
        isSpeaking = false
    }
}

/// Bounded playback facts shared by the two speech roles; times describe native scheduling, not acoustic arrival.
public struct SpeechPlaybackSnapshot: Sendable {
    struct Period: Sendable {
        let id: String
        let sessionID: String
        let start: ContinuousClock.Instant
        var end: ContinuousClock.Instant?
    }
    var periods: [Period] = []
    var retainedSince: ContinuousClock.Instant?
    public init() {}

    func state(at time: ContinuousClock.Instant) -> (playing: Bool, known: Bool) {
        if let retainedSince, time < retainedSince { return (false, false) }
        for period in periods.reversed() where time >= period.start {
            if let end = period.end,
                time >= end.advanced(by: .milliseconds(200))
            {
                continue
            }
            return (true, true)
        }
        return (false, true)
    }
}

struct SpeechPlaybackHistory: Sendable {
    private var snapshot = SpeechPlaybackSnapshot()
    mutating func started(id: String, sessionID: String, at time: ContinuousClock.Instant) {
        if snapshot.periods.last?.id == id { return }
        if let last = snapshot.periods.last, time < last.start { return }
        if let index = snapshot.periods.indices.last, snapshot.periods[index].end == nil {
            snapshot.periods[index].end = time
        }
        snapshot.periods.append(.init(id: id, sessionID: sessionID, start: time))
        if snapshot.periods.count > 32 {
            snapshot.periods.removeFirst()
            snapshot.retainedSince = snapshot.periods.first?.start
        }
    }
    mutating func ended(id: String, at time: ContinuousClock.Instant) {
        guard let index = snapshot.periods.indices.last, snapshot.periods[index].id == id,
            snapshot.periods[index].end == nil, time >= snapshot.periods[index].start
        else { return }
        snapshot.periods[index].end = time
    }
    func read(sessionID: String) -> SpeechPlaybackSnapshot {
        var result = snapshot
        result.periods = result.periods.filter { $0.sessionID == sessionID }
        return result
    }
}

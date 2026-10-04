import ModelKit

/// Segmentation policy is independent of neural VAD state. Durations use integer sample counts.
struct SpeechBoundaryPolicy {
    private static let onsetSamples = 1536
    private static let preRollSamples = 4096
    private static let silenceSamples = 12800
    private static let maximumSegmentSamples = 192000
    // VAD normally emits 512-sample windows; preserve padding by samples, not window count.
    private static let endpointPaddingSamples = 3072

    private(set) var isSpeaking = false
    private(set) var streamEvents: [VoiceStreamEvent] = []
    private var preRoll: [AudioFrame] = []
    private var holdback: [AudioFrame] = []
    private var candidate = 0
    private var silence = 0
    private var duration = 0
    private var hasSpeech = false
    mutating func consume(_ frame: AudioFrame, probability: Float, threshold: Float) -> VoiceSegmentEnd? {
        streamEvents = []
        if probability >= threshold { hasSpeech = true }
        if !isSpeaking {
            preRoll.append(frame)
            while preRoll.count > 1 && preRoll.reduce(0, { $0 + $1.sampleCount }) > Self.preRollSamples {
                preRoll.removeFirst()
            }
            candidate = probability >= threshold ? candidate + frame.sampleCount : 0
            guard candidate >= Self.onsetSamples else { return nil }
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
        silence = probability >= threshold ? 0 : silence + frame.sampleCount
        if silence >= Self.silenceSamples {
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
        silence = 0
        duration = 0
        hasSpeech = false
        isSpeaking = false
    }
}

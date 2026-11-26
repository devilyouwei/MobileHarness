import Foundation
import ModelKit

/// Segmentation policy is independent of neural VAD state. Endpoint silence counts consecutive VAD windows.
struct SpeechBoundaryPolicy {
    private static let preRollSamples = 4096
    private static let longSilenceWindows = 25
    private static let shortSilenceWindows = 16
    private static let maximumEndpointSilenceSamples = 32000
    private static let maximumSegmentSamples = 192000
    private static let rearmSilenceSamples = 2560
    // VAD normally emits 512-sample windows; preserve padding by samples, not window count.
    private static let endpointPaddingSamples = 3072

    private(set) var isSpeaking = false
    private(set) var streamEvents: [VoiceStreamEvent] = []
    private var preRoll: [AudioFrame] = []
    private var holdback: [AudioFrame] = []
    private var candidate = 0
    var hasOnsetCandidate: Bool { !isSpeaking && candidate > 0 }
    private var silentWindows = 0
    private var silentSamples = 0
    private(set) var endpointConfirmationPending = false
    private var endpointDeferred = false
    private var duration = 0
    private var hasSpeech = false
    private var rearmSilence: Int?
    mutating func consume(
        _ frame: AudioFrame, probability: Float, threshold: Float, onsetWindows: Int = 8,
        useShortEndpoint: Bool = false,
        onsetThreshold: Float? = nil, confirmEndpoint: Bool = false
    ) -> VoiceSegmentEnd? {
        streamEvents = []
        if let quiet = rearmSilence {
            let quietSamples = probability < threshold ? quiet + frame.sampleCount : 0
            rearmSilence = quietSamples >= Self.rearmSilenceSamples ? nil : quietSamples
            return nil
        }
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
        silentSamples = probability >= threshold ? 0 : silentSamples + frame.sampleCount
        if silentWindows == 0 { endpointDeferred = false }
        let silenceLimit = useShortEndpoint ? Self.shortSilenceWindows : Self.longSilenceWindows
        if endpointDeferred {
            if silentSamples >= Self.maximumEndpointSilenceSamples {
                endAtSilence()
                return .silence
            }
        } else if silentWindows >= silenceLimit {
            if confirmEndpoint, silentSamples < Self.maximumEndpointSilenceSamples {
                endpointConfirmationPending = true
                return nil
            }
            endAtSilence()
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

    mutating func resolveEndpoint(complete: Bool) {
        endpointConfirmationPending = false
        if complete {
            endAtSilence()
        } else {
            endpointDeferred = true
        }
    }

    private mutating func endAtSilence() {
        // Keep 192 ms of endpoint padding; retain in-sentence silence in full.
        if hasSpeech {
            streamEvents.append(.audio(Self.prefix(holdback, sampleLimit: Self.endpointPaddingSamples)))
        }
        streamEvents.append(.end(.silence))
        let nextPreRoll = Self.suffix(holdback, sampleLimit: Self.preRollSamples)
        reset()
        preRoll = nextPreRoll
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
    mutating func reset(requireFreshOnset: Bool = false) {
        preRoll.removeAll(keepingCapacity: true)
        holdback.removeAll(keepingCapacity: true)
        candidate = 0
        silentWindows = 0
        silentSamples = 0
        endpointConfirmationPending = false
        endpointDeferred = false
        duration = 0
        hasSpeech = false
        isSpeaking = false
        rearmSilence = requireFreshOnset ? 0 : nil
    }
}

/// VAD gates for one window. Playback raises only the onset gate; confirmed speech keeps the base probability.
struct SpeechOnsetPolicy: Equatable {
    static let playbackProbabilityIncrease: Float = 0.15
    static let playbackWindowIncrease = 2
    static let maximumProbability: Float = 0.95
    static let maximumWindows = 16

    let threshold: Float
    let onsetThreshold: Float
    let onsetWindows: Int

    init(windows: Int, threshold: Double, playing: Bool) {
        self.threshold = Float(threshold)
        let increase = playing ? Self.playbackProbabilityIncrease : 0
        onsetThreshold = min(Self.maximumProbability, Float(threshold) + increase)
        let raised = (1...Self.maximumWindows).contains(windows) && playing
        onsetWindows = raised ? min(Self.maximumWindows, windows + Self.playbackWindowIncrease) : windows
    }
}

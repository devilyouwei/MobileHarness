import Foundation
import ModelKit

/// Hysteresis over PCM windows after confirmed onset. Initial calibration thresholds are in dBFS.
struct SpeechEnergyBands {
    // The segmentation path supplies 16 kHz PCM, with 16 samples per millisecond.
    private static let duckReleaseSamples = 600 * 16
    private static let pauseReleaseSamples = 1_000 * 16

    private(set) var energy: SpeechActivity.Energy = .low
    private var candidate: SpeechActivity.Energy = .low
    private var windows = 0
    private var loudWindows = 0
    private var releaseSamples = 0
    var isQuiet: Bool { energy == .low && candidate == .low }

    mutating func observe(_ samples: [Float]) -> SpeechActivity.Energy? {
        guard !samples.isEmpty else { return nil }
        let power = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        let level = 10 * log10(max(power, 1e-12))
        loudWindows = level >= -20 ? min(6, loudWindows + 1) : 0
        let high = loudWindows == 6 || (energy == .high && level > -25)
        let medium = level >= -34 || (energy != .low && level > -39)
        let next: SpeechActivity.Energy = high ? .high : medium ? .medium : .low
        if candidate != next {
            candidate = next
            windows = 0
        }
        guard next != energy else {
            releaseSamples = 0
            return nil
        }
        if next == .high || energy == .low {
            windows += 1
            guard next == .high || windows >= 2 else { return nil }
        } else {
            // Any level below the current band counts toward its release.
            releaseSamples += samples.count
            let required = energy == .high ? Self.pauseReleaseSamples : Self.duckReleaseSamples
            guard releaseSamples >= required else { return nil }
        }
        energy = next
        windows = 0
        releaseSamples = 0
        return next
    }
}

/// Capture-scoped calibration over the same prepared PCM used by VAD and ASR.
struct SpeechLevelAdmission {
    struct Gates: Sendable {
        let noiseFloor: Float
        let onset: Float
        let continuation: Float
    }

    private var noiseFloor: Float = -70
    private var speakerLevel: Float?
    private var turnLevels: [Float] = []
    private var overlapsPlayback = false
    private var completedLevel: Float?

    var gates: Gates {
        Gates(
            noiseFloor: noiseFloor,
            onset: max(-58, min(-32, noiseFloor + 8), speakerLevel.map { min(-44, $0 - 12) } ?? -58),
            continuation: max(-66, min(-40, noiseFloor + 3), speakerLevel.map { min(-54, $0 - 20) } ?? -66))
    }

    mutating func observeBackground(level: Float, samples: Int) {
        let bounded = min(-32, max(-78, level))
        noiseFloor += (bounded - noiseFloor) * min(1, Float(samples) / 16_000)
    }

    mutating func observeSpeech(level: Float, probability: Float, playing: Bool) {
        overlapsPlayback = overlapsPlayback || playing
        guard !overlapsPlayback, probability >= 0.8, level >= max(-48, noiseFloor + 12), turnLevels.count < 32
        else { return }
        turnLevels.append(level)
    }

    mutating func clearCandidate() {
        turnLevels.removeAll(keepingCapacity: true)
        overlapsPlayback = false
    }

    mutating func completeTurn() {
        if !overlapsPlayback, turnLevels.count >= 8 {
            let sorted = turnLevels.sorted()
            completedLevel = (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
        }
        clearCandidate()
    }

    mutating func resetTurn(acceptedTranscript: Bool) {
        if acceptedTranscript, let completedLevel {
            if let previous = speakerLevel {
                speakerLevel = previous + min(2, max(-2, 0.25 * (completedLevel - previous)))
            } else {
                speakerLevel = completedLevel
            }
        }
        completedLevel = nil
        clearCandidate()
    }
}

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
    private var levelAdmission = SpeechLevelAdmission()
    var levelGates: SpeechLevelAdmission.Gates { levelAdmission.gates }

    mutating func resetLevelCalibration() { levelAdmission = SpeechLevelAdmission() }

    mutating func resetLevelTurn(acceptedTranscript: Bool) {
        levelAdmission.resetTurn(acceptedTranscript: acceptedTranscript)
    }

    mutating func consume(
        _ frame: AudioFrame, level: Float, probability: Float, threshold: Float, onsetWindows: Int = 8,
        playing: Bool = false, useShortEndpoint: Bool = false,
        onsetThreshold: Float? = nil, confirmEndpoint: Bool = false
    ) -> VoiceSegmentEnd? {
        streamEvents = []
        let gates = levelGates
        let continuesSpeech = probability >= threshold && level >= gates.continuation
        if let quiet = rearmSilence {
            let quietSamples = continuesSpeech ? 0 : quiet + frame.sampleCount
            rearmSilence = quietSamples >= Self.rearmSilenceSamples ? nil : quietSamples
            return nil
        }
        let startsSpeech = probability >= (onsetThreshold ?? threshold) && level >= gates.onset
        let voiced = isSpeaking ? continuesSpeech : startsSpeech
        if voiced { hasSpeech = true }
        if isSpeaking || startsSpeech {
            levelAdmission.observeSpeech(level: level, probability: voiced ? probability : 0, playing: playing)
        } else {
            if candidate == 0, !playing, probability < min(0.3, threshold) {
                levelAdmission.observeBackground(level: level, samples: frame.sampleCount)
            }
            levelAdmission.clearCandidate()
        }
        if !isSpeaking {
            preRoll.append(frame)
            while preRoll.count > 1
                && preRoll.reduce(0, { $0 + $1.sampleCount }) > max(Self.preRollSamples, onsetWindows * 512)
            {
                preRoll.removeFirst()
            }
            candidate = voiced ? candidate + frame.sampleCount : 0
            guard candidate >= onsetWindows * 512 else { return nil }
            isSpeaking = true
            streamEvents.append(.audio(preRoll))
            duration = preRoll.reduce(0) { $0 + $1.sampleCount }
            preRoll.removeAll()
        } else {
            duration += frame.sampleCount
            if voiced {
                streamEvents.append(.audio(holdback + [frame]))
                holdback.removeAll(keepingCapacity: true)
            } else {
                holdback.append(frame)
            }
        }
        silentWindows = voiced ? 0 : silentWindows + 1
        silentSamples = voiced ? 0 : silentSamples + frame.sampleCount
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
        levelAdmission.completeTurn()
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

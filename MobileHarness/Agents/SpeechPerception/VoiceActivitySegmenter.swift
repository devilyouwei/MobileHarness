import Foundation
import ModelKit

public struct VoiceSegmentation: Sendable {
    public let streamEvents: [VoiceStreamEvent]
    public let isSpeaking: Bool
    public let probability: Float
}

/// Bounded input policy around an abstract VAD session. Never imports a concrete model or audio hardware.
public actor VoiceActivitySegmenter {
    private let session: any VoiceActivitySession
    private var pending: [Float] = []
    private var position: Int64 = 0
    private var policy = SpeechBoundaryPolicy()
    private var busy = false
    private var closed = false
    private var probability: Float = 0
    private var turnSamples = 0
    public init(session: any VoiceActivitySession) { self.session = session }

    public func process(_ frame: AudioFrame, threshold: Float = 0.5) async throws -> VoiceSegmentation {
        guard !closed else { throw CapabilityError.sessionClosed }
        guard !busy else { throw CapabilityError.inputBusy }
        guard frame.format.sampleRate == 16000, frame.format.channels == 1, frame.format.encoding == .float32,
            frame.sampleCount <= 16000, pending.count + frame.sampleCount <= 32000,
            threshold.isFinite, (0.05...0.95).contains(threshold)
        else { throw CapabilityError.invalidRequest("Invalid VAD segmentation input") }
        busy = true
        defer { busy = false }
        do {
            let samples = frame.data.withUnsafeBytes { bytes in
                (0..<frame.sampleCount).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
            }
            guard samples.allSatisfy(\.isFinite) else { throw CapabilityError.invalidRequest("Non-finite PCM") }
            pending.append(contentsOf: samples)
            let scores = try await session.process(frame)
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            guard scores.count <= 64 else { throw CapabilityError.bufferOverflow }
            var streamEvents: [VoiceStreamEvent] = []
            var consumed = 0
            for score in scores {
                guard score.startSample == position, score.sampleCount <= pending.count - consumed else {
                    throw CapabilityError.invalidRequest("VAD scores do not cover contiguous input")
                }
                let slice = Array(pending[consumed..<consumed + score.sampleCount])
                let window = try AudioFrame(
                    data: slice.withUnsafeBytes { Data($0) }, format: frame.format,
                    sequence: UInt64(position), timestamp: Double(position) / 16000)
                let wasSpeaking = policy.isSpeaking
                let end = policy.consume(window, probability: score.probability, threshold: threshold)
                streamEvents += policy.streamEvents
                if wasSpeaking || policy.isSpeaking { turnSamples += score.sampleCount }
                guard turnSamples <= 960000 else { throw CapabilityError.bufferOverflow }
                if end == .silence { turnSamples = 0 }
                consumed += score.sampleCount
                position += Int64(score.sampleCount)
                probability = score.probability
            }
            pending.removeFirst(consumed)
            return VoiceSegmentation(
                streamEvents: streamEvents, isSpeaking: policy.isSpeaking, probability: probability
            )
        } catch {
            closed = true
            await session.cancel()
            pending.removeAll()
            policy.reset()
            throw error
        }
    }
    public func finishStreaming() async throws -> [VoiceStreamEvent] {
        guard !closed else { throw CapabilityError.sessionClosed }
        guard !busy else { throw CapabilityError.inputBusy }
        var tail = policy.uncommittedFrames
        if policy.isSpeaking, !pending.isEmpty {
            tail.append(
                try AudioFrame(
                    data: pending.withUnsafeBytes { Data($0) },
                    format: AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32),
                    sequence: UInt64(position), timestamp: Double(position) / 16000))
        }
        await cancel()
        return [.audio(tail), .end(.inputFinished)]
    }

    public func reset() async throws {
        guard !closed else { throw CapabilityError.sessionClosed }
        guard !busy else { throw CapabilityError.inputBusy }
        busy = true
        defer { busy = false }
        try await session.reset()
        pending.removeAll(keepingCapacity: true)
        position = 0
        turnSamples = 0
        probability = 0
        policy.reset()
    }
    public func cancel() async {
        closed = true
        await session.cancel()
        pending.removeAll()
        policy.reset()
    }
}

public enum VoiceStreamEvent: Sendable {
    case audio([AudioFrame])
    case end(VoiceSegmentEnd)
}

public enum VoiceSegmentEnd: String, Sendable {
    case silence, maximumDuration, inputFinished
}

/// Segmentation policy is independent of neural VAD state. Durations use integer sample counts.
struct SpeechBoundaryPolicy {
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
            while preRoll.count > 1 && preRoll.reduce(0, { $0 + $1.sampleCount }) > 4096 {
                preRoll.removeFirst()
            }
            candidate = probability >= threshold ? candidate + frame.sampleCount : 0
            guard candidate >= 1536 else { return nil }
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
        if silence >= 12800 {
            // Keep 192 ms of endpoint padding; retain in-sentence silence in full.
            if hasSpeech { streamEvents.append(.audio(Array(holdback.prefix(6)))) }
            streamEvents.append(.end(.silence))
            let nextPreRoll = Array(holdback.suffix(8))
            reset()
            preRoll = nextPreRoll
            return .silence
        }
        if duration >= 192000 {
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

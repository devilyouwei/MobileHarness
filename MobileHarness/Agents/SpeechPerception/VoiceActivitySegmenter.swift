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
                _ = policy.consume(window, probability: score.probability, threshold: threshold)
                streamEvents += policy.streamEvents
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

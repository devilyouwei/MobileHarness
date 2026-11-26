import Foundation
import ModelKit
import OSLog

public struct VoiceSegmentation: Sendable {
    public struct Window: Sendable {
        public let offset: Int
        public let sampleCount: Int
        public let onsetCandidate: Bool
        let speaking: Bool
        let pcm: [Float]
    }
    public let streamEvents: [VoiceStreamEvent]
    public let isSpeaking: Bool
    public let probability: Float
    public let windows: [Window]
}

/// Bounded input policy around an abstract VAD session. Never imports a concrete model or audio hardware.
public actor VoiceActivitySegmenter {
    private static let endpointWindowSamples = 128_000
    private static let logger = Logger(subsystem: "dev.mobileharness", category: "SpeechEndpoint")
    private let session: any VoiceActivitySession
    private let endpointConfirmation: (any SpeechEndpointCapability)?
    private var turnAudio: [[Float]] = []
    private var turnAudioSamples = 0
    private var pending: [Float] = []
    private var position: Int64 = 0
    private var policy = SpeechBoundaryPolicy()
    private var busy = false
    private var closed = false
    private var probability: Float = 0
    public init(session: any VoiceActivitySession, endpointConfirmation: (any SpeechEndpointCapability)? = nil) {
        self.session = session
        self.endpointConfirmation = endpointConfirmation
    }

    public func process(
        _ frame: AudioFrame, threshold: Float = 0.65, onsetWindows: Int = 8, useShortEndpoint: Bool = false,
        onsetThreshold: Float? = nil
    ) async throws -> VoiceSegmentation {
        guard !closed else { throw CapabilityError.sessionClosed }
        guard !busy else { throw CapabilityError.inputBusy }
        guard frame.format.sampleRate == 16000, frame.format.channels == 1, frame.format.encoding == .float32,
            frame.sampleCount <= 16000, pending.count + frame.sampleCount <= 32000,
            threshold.isFinite, (0.05...0.95).contains(threshold), (1...16).contains(onsetWindows),
            onsetThreshold.map({ $0.isFinite && (0.05...0.95).contains($0) }) ?? true
        else { throw CapabilityError.invalidRequest("Invalid VAD segmentation input") }
        busy = true
        defer { busy = false }
        do {
            let samples = frame.floatSamples
            guard samples.allSatisfy(\.isFinite) else { throw CapabilityError.invalidRequest("Non-finite PCM") }
            let frameStart = position + Int64(pending.count)
            pending.append(contentsOf: samples)
            let scores = try await session.process(frame)
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            guard scores.count <= 64 else { throw CapabilityError.bufferOverflow }
            var streamEvents: [VoiceStreamEvent] = []
            var windows: [VoiceSegmentation.Window] = []
            var consumed = 0
            for score in scores {
                guard score.startSample == position, score.sampleCount <= pending.count - consumed else {
                    throw CapabilityError.invalidRequest("VAD scores do not cover contiguous input")
                }
                let slice = Array(pending[consumed..<consumed + score.sampleCount])
                let window = try AudioFrame(
                    floatSamples: slice, format: frame.format,
                    sequence: UInt64(position), timestamp: Double(position) / 16000)
                let wasSpeaking = policy.isSpeaking
                _ = policy.consume(
                    window, probability: score.probability, threshold: threshold, onsetWindows: onsetWindows,
                    useShortEndpoint: useShortEndpoint, onsetThreshold: onsetThreshold,
                    confirmEndpoint: endpointConfirmation != nil)
                if let endpointConfirmation {
                    if wasSpeaking {
                        rememberTurnAudio(slice)
                    } else if policy.isSpeaking, case .audio(let onset)? = policy.streamEvents.first {
                        for frame in onset { rememberTurnAudio(frame.floatSamples) }
                    }
                    if policy.endpointConfirmationPending {
                        let complete = await confirmEndpoint(using: endpointConfirmation)
                        try Task.checkCancellation()
                        guard !closed else { throw CancellationError() }
                        policy.resolveEndpoint(complete: complete)
                    }
                    if !policy.isSpeaking { clearTurnAudio() }
                }
                windows.append(
                    .init(
                        offset: Int(score.startSample - frameStart), sampleCount: score.sampleCount,
                        onsetCandidate: policy.hasOnsetCandidate, speaking: policy.isSpeaking, pcm: slice))
                streamEvents += policy.streamEvents
                consumed += score.sampleCount
                position += Int64(score.sampleCount)
                probability = score.probability
            }
            pending.removeFirst(consumed)
            return VoiceSegmentation(
                streamEvents: streamEvents, isSpeaking: policy.isSpeaking, probability: probability, windows: windows
            )
        } catch {
            closed = true
            await session.cancel()
            pending.removeAll()
            policy.reset()
            clearTurnAudio()
            throw error
        }
    }

    private func rememberTurnAudio(_ samples: [Float]) {
        turnAudio.append(samples)
        turnAudioSamples += samples.count
        while let first = turnAudio.first, turnAudioSamples > Self.endpointWindowSamples {
            let excess = turnAudioSamples - Self.endpointWindowSamples
            if excess < first.count {
                turnAudio[0] = Array(first.dropFirst(excess))
                turnAudioSamples -= excess
            } else {
                turnAudioSamples -= turnAudio.removeFirst().count
            }
        }
    }

    private func clearTurnAudio() {
        turnAudio.removeAll()
        turnAudioSamples = 0
    }

    private func confirmEndpoint(using capability: any SpeechEndpointCapability) async -> Bool {
        do {
            guard let probability = try await capability.completionProbability(for: turnAudio.flatMap({ $0 })) else {
                return true
            }
            return probability > 0.5
        } catch {
            if !Task.isCancelled {
                Self.logger.error("Endpoint confirmation failed: \(String(describing: error), privacy: .public)")
            }
            return true
        }
    }
    public func finishStreaming() async throws -> [VoiceStreamEvent] {
        guard !closed else { throw CapabilityError.sessionClosed }
        guard !busy else { throw CapabilityError.inputBusy }
        var tail = policy.uncommittedFrames
        if policy.isSpeaking, !pending.isEmpty {
            tail.append(
                try AudioFrame(
                    floatSamples: pending, format: AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32),
                    sequence: UInt64(position), timestamp: Double(position) / 16000))
        }
        await cancel()
        return [.audio(tail), .end(.inputFinished)]
    }

    public func reset() async throws { try await reset(requireFreshOnset: false) }

    func reset(requireFreshOnset: Bool) async throws {
        guard !closed else { throw CapabilityError.sessionClosed }
        guard !busy else { throw CapabilityError.inputBusy }
        busy = true
        defer { busy = false }
        try await session.reset()
        pending.removeAll(keepingCapacity: true)
        position = 0
        probability = 0
        policy.reset(requireFreshOnset: requireFreshOnset)
        clearTurnAudio()
    }
    public func cancel() async {
        closed = true
        await session.cancel()
        pending.removeAll()
        policy.reset()
        clearTurnAudio()
    }
}

public enum VoiceStreamEvent: Sendable {
    case audio([AudioFrame])
    case end(VoiceSegmentEnd)
}

public enum VoiceSegmentEnd: String, Sendable {
    case silence, maximumDuration, inputFinished
}

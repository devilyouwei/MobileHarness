import Foundation
import Synchronization

/// Single-consumer control for one playback stream. Intermediate adjustments can be coalesced.
public final class AudioPlaybackControl: Sendable {
    public enum Adjustment: Equatable, Sendable {
        case playing(volume: Float)
        case paused
    }

    private struct PlaybackState {
        var adjustment: Adjustment = .playing(volume: 1)
        var isPlaying: Bool?
        var closed = false
        var failure: AudioIOError?
    }

    private let state = Mutex(PlaybackState())
    private let notifications = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var changes: AsyncStream<Void> { notifications.stream }
    public var adjustment: Adjustment { state.withLock { $0.adjustment } }

    public init() {}

    public func set(_ value: Adjustment) {
        let changed = state.withLock { current in
            guard !current.closed, current.adjustment != value else { return false }
            current.adjustment = value
            return true
        }
        if changed { notifications.continuation.yield(()) }
    }

    func confirmPlaying(_ isPlaying: Bool) {
        state.withLock { playback in
            guard !playback.closed else { return }
            playback.isPlaying = isPlaying
        }
    }

    public func waitUntilPlaying(_ isPlaying: Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while true {
            try Task.checkCancellation()
            let (closed, confirmed) = state.withLock { ($0.closed, $0.isPlaying == isPlaying) }
            guard !closed else { throw CancellationError() }
            if confirmed { return }
            guard ContinuousClock.now < deadline else {
                let failure = AudioIOError.playbackControlTimeout
                state.withLock { $0.failure = failure }
                notifications.continuation.yield(())
                throw failure
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    var failure: AudioIOError? { state.withLock { $0.failure } }

    public func close() {
        state.withLock { $0.closed = true }
        notifications.continuation.finish()
    }

    deinit { notifications.continuation.finish() }
}

enum AudioPlaybackRamp {
    static let steps = 24
    static let stepMilliseconds = 5

    static func volume(from start: Float, to target: Float, step: Int) -> Float {
        if step >= steps { return target }
        return start + (target - start) * Float(step) / Float(steps)
    }
}

public enum MicrophoneChannelLayout: Sendable, Equatable {
    case mono
    case firstOrderAmbisonicsACNSN3D
    public var channelCount: Int { self == .mono ? 1 : 4 }
}

/// Native-rate interleaved device PCM. The first FOA channel is omnidirectional W.
public struct MicrophoneFrame: Sendable {
    public let samples: [Float]
    public let sampleRate: Int
    public let layout: MicrophoneChannelLayout
    public let timestamp: TimeInterval
    public let capturedAt: ContinuousClock.Instant
    public let sequence: UInt64
    public init(
        samples: [Float], sampleRate: Int, sequence: UInt64,
        layout: MicrophoneChannelLayout = .mono, timestamp: TimeInterval = 0,
        capturedAt: ContinuousClock.Instant = .now
    ) {
        self.layout = layout
        self.timestamp = timestamp
        self.capturedAt = capturedAt
        self.samples = samples
        self.sampleRate = sampleRate
        self.sequence = sequence
    }
    public var duration: Double { Double(samples.count / layout.channelCount) / Double(max(sampleRate, 1)) }
    public var omnidirectionalSamples: [Float] {
        if layout == .mono { return samples }
        return stride(from: 0, to: samples.count, by: layout.channelCount).map { samples[$0] }
    }
    public var rms: Float {
        let values = omnidirectionalSamples
        guard !values.isEmpty else { return 0 }
        return sqrt(values.reduce(Float(0)) { $0 + $1 * $1 } / Float(values.count))
    }
}

/// Native timeline evidence, distinct from the bounded stream queue becoming full.
public struct AudioCaptureDiscontinuity: Error, Sendable, Equatable {
    public let expectedTimestamp: Double
    public let actualTimestamp: Double
    public let previousSampleRate: Double
    public let actualSampleRate: Double
    public var gapSeconds: Double { actualTimestamp - expectedTimestamp }
}

enum AudioPCMContinuityError: Error { case invalidFrame }
struct AudioPCMContinuity: Sendable {
    private var end: Double?
    private var rate: Double?
    mutating func accept(timestamp: Double, frameCount: Int, sampleRate: Double) throws {
        guard timestamp.isFinite, timestamp >= 0, frameCount > 0, sampleRate.isFinite, sampleRate > 0 else {
            throw AudioPCMContinuityError.invalidFrame
        }
        if let end, let rate, rate != sampleRate || abs(timestamp - end) > 2 / sampleRate {
            throw AudioCaptureDiscontinuity(
                expectedTimestamp: end, actualTimestamp: timestamp,
                previousSampleRate: rate, actualSampleRate: sampleRate)
        }
        end = timestamp + Double(frameCount) / sampleRate
        rate = sampleRate
    }
}

/// Read-only current capture. Subscription never requests permission or starts hardware.
public protocol AudioCaptureObserving: Sendable {
    func listenCapture() async throws -> MicrophoneCaptureInput
    func playbackSnapshot() async -> AudioPlaybackSnapshot
}

/// Explicit capture execution. Read-only observers receive AudioCaptureObserving instead.
@MainActor public protocol AudioCaptureControlling: AudioCaptureObserving {
    var captureContext: AudioCaptureContext { get }
    var cleanupFailure: (any Error)? { get }
    func requestPermissions() async throws
    func listenEvents() throws -> StateSignalListener<NativeAudioEvent>
    func startCapture(preferSpatial: Bool) async throws
    func stopCapture() async
    func stop() async
}

public enum AudioIOError: Error, Equatable {
    case microphoneDenied, invalidFormat, overflow, busy, interrupted, startFailed, runtimeFailed,
        playbackControlTimeout
}

/// The native generation and its single ordered source; no forwarding queue.
public struct MicrophoneCaptureInput: Sendable {
    public let generation: String
    public let supportsFullDuplex: Bool
    public let frames: MediaSignalListener<MicrophoneFrame>
    public let meterFrames: AsyncStream<MicrophoneFrame>?
    public init(
        generation: String, frames: AsyncThrowingStream<MicrophoneFrame, any Error>, supportsFullDuplex: Bool = false,
        meterFrames: AsyncStream<MicrophoneFrame>? = nil, detach: @escaping @Sendable () async -> Void
    ) {
        self.generation = generation
        self.supportsFullDuplex = supportsFullDuplex
        self.meterFrames = meterFrames
        self.frames = MediaSignalListener(
            source: .init(
                producer: "platform.audio.microphone", generation: generation, delivery: .ordered(capacity: 64)),
            stream: frames, detach: detach)
    }
}

/// One native callback generation, one 64-packet queue and one business consumer.
final class MicrophoneCapture: Sendable {
    let generation = UUID().uuidString
    private let frames: AsyncThrowingStream<MicrophoneFrame, any Error>
    private let continuation: AsyncThrowingStream<MicrophoneFrame, any Error>.Continuation
    private struct State {
        var active = true
        var subscribed = false
    }
    private let state = Mutex(State())
    private let meter = AsyncStream<MicrophoneFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let supportsFullDuplex: Bool
    init(supportsFullDuplex: Bool = false) {
        self.supportsFullDuplex = supportsFullDuplex
        let pair = AsyncThrowingStream<MicrophoneFrame, any Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        frames = pair.stream
        continuation = pair.continuation
    }
    var isActive: Bool { state.withLock { $0.active } }
    func subscribe() throws -> MicrophoneCaptureInput {
        try state.withLock {
            guard !$0.subscribed else { throw AudioIOError.busy }
            $0.subscribed = true
            return MicrophoneCaptureInput(
                generation: generation, frames: frames, supportsFullDuplex: supportsFullDuplex,
                meterFrames: meter.stream, detach: { [weak self] in self?.finish() })
        }
    }
    @discardableResult func send(_ frame: MicrophoneFrame) throws -> Bool {
        try state.withLock {
            guard $0.active else { return false }
            switch continuation.yield(frame) {
            case .enqueued:
                meter.continuation.yield(frame)
                return true
            case .dropped:
                $0.active = false
                meter.continuation.finish()
                continuation.finish(throwing: AudioIOError.overflow)
                throw AudioIOError.overflow
            case .terminated:
                $0.active = false
                meter.continuation.finish()
                return false
            @unknown default:
                $0.active = false
                meter.continuation.finish()
                continuation.finish(throwing: AudioIOError.invalidFormat)
                throw AudioIOError.invalidFormat
            }
        }
    }
    func finish(throwing error: (any Error)? = nil) {
        state.withLock {
            guard $0.active else { return }
            $0.active = false
            meter.continuation.finish()
            continuation.finish(throwing: error)
        }
    }
    deinit {
        meter.continuation.finish()
        continuation.finish()
    }
}

/// Bounded native playback history for capture-time policy. Ended periods can supply a short onset tail.
public struct AudioPlaybackSnapshot: Sendable {
    public struct Period: Sendable {
        public let start: ContinuousClock.Instant
        public let end: ContinuousClock.Instant?

        public init(start: ContinuousClock.Instant, end: ContinuousClock.Instant? = nil) {
            self.start = start
            self.end = end
        }
    }

    private let periods: [Period]

    public init(periods: [Period] = []) { self.periods = Array(periods.suffix(32)) }

    public func isPlaying(at time: ContinuousClock.Instant, tail: Duration = .zero) -> Bool {
        periods.contains { period in
            time >= period.start && period.end.map { time < $0 + tail } != false
        }
    }
}

extension AudioCaptureObserving {
    public func playbackSnapshot() async -> AudioPlaybackSnapshot { .init() }
}

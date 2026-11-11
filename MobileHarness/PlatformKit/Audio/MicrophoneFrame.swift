import Foundation
import Synchronization

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
    func subscribeCapture() async throws -> MicrophoneCaptureInput
}

/// Explicit capture execution. Read-only observers receive AudioCaptureObserving instead.
@MainActor public protocol AudioCaptureControlling: AudioCaptureObserving {
    var captureContext: AudioCaptureContext { get }
    var cleanupFailure: (any Error)? { get }
    func requestPermissions() async throws
    func subscribeEvents() throws -> AsyncThrowingStream<NativeAudioEvent, any Error>
    func startCapture(preferSpatial: Bool) async throws
    func stopCapture() async
    func stop() async
}

public enum AudioIOError: Error, Equatable {
    case microphoneDenied, invalidFormat, overflow, busy, interrupted, startFailed, runtimeFailed
}

/// The native generation and its single ordered source; no forwarding queue.
public struct MicrophoneCaptureInput: Sendable {
    public let generation: String
    public let supportsFullDuplex: Bool
    public let frames: AsyncThrowingStream<MicrophoneFrame, any Error>
    public init(
        generation: String, frames: AsyncThrowingStream<MicrophoneFrame, any Error>, supportsFullDuplex: Bool = false
    ) {
        self.generation = generation
        self.supportsFullDuplex = supportsFullDuplex
        self.frames = frames
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
                generation: generation, frames: frames, supportsFullDuplex: supportsFullDuplex)
        }
    }
    @discardableResult func send(_ frame: MicrophoneFrame) throws -> Bool {
        try state.withLock {
            guard $0.active else { return false }
            switch continuation.yield(frame) {
            case .enqueued: return true
            case .dropped:
                $0.active = false
                continuation.finish(throwing: AudioIOError.overflow)
                throw AudioIOError.overflow
            case .terminated:
                $0.active = false
                return false
            @unknown default:
                $0.active = false
                continuation.finish(throwing: AudioIOError.invalidFormat)
                throw AudioIOError.invalidFormat
            }
        }
    }
    func finish(throwing error: (any Error)? = nil) {
        state.withLock {
            guard $0.active else { return }
            $0.active = false
            continuation.finish(throwing: error)
        }
    }
    deinit { continuation.finish() }
}

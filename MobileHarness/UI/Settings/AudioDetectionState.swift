import Foundation
import Observation

/// Display-only values; the App maps native capture facts and Agent observations here.
public struct AudioDetectionSnapshot: Sendable, Equatable {
    public enum Input: Sendable { case unknown, builtInMicrophone, headset, external }
    public enum Support: Sendable { case unknown, supported, unsupported, inputUnavailable }
    public enum Capture: Sendable { case waiting, spatial, mono }
    public enum Fallback: Sendable { case inputUnavailable, unsupported, startupFailed }
    public enum Signal: Sendable { case waiting, receiving, noAudio }
    public enum Direction: Sendable { case waiting, active, inactive, uncertain, unavailable }
    public var permissionGranted: Bool?
    public var input: Input = .unknown
    public var support: Support = .unknown
    public var capture: Capture = .waiting
    public var fallback: Fallback?
    public var sampleRate = 0
    public var signal: Signal = .waiting
    public var level = 0.0
    public var direction: Direction = .waiting
    public var azimuthDegrees: Double?
    public var elevationDegrees: Double?
    public var capturedAt: ContinuousClock.Instant?
    public var directionExpiresAt: ContinuousClock.Instant?
    public init() {}
}

@MainActor @Observable
public final class AudioDetectionState {
    public enum Phase { case idle, preparing, running, stopping, finished, stopped, failed }
    public var phase: Phase = .idle
    public var snapshot = AudioDetectionSnapshot()
    public var error: String?
    public var isActive: Bool { phase == .preparing || phase == .running || phase == .stopping }
    public init() {}
    public func refresh(at now: ContinuousClock.Instant = .now) {
        if let capturedAt = snapshot.capturedAt, capturedAt.duration(to: now) > .seconds(1) {
            snapshot.signal = .noAudio
            snapshot.level = 0
        }
        if let deadline = snapshot.directionExpiresAt, deadline <= now {
            if snapshot.direction == .active { clearDirection() } else { snapshot.directionExpiresAt = nil }
        }
    }
    public func clearDirection() {
        if snapshot.direction != .unavailable { snapshot.direction = .waiting }
        snapshot.azimuthDegrees = nil
        snapshot.elevationDegrees = nil
        snapshot.directionExpiresAt = nil
    }
}

@MainActor public protocol AudioDetectionControlling: AnyObject {
    func start()
    func stop()
}

/// Whole diagnostic endpoint supplied by App; neither UI nor the workflow constructs an Agent/device.
@MainActor public protocol AudioDetectionRunning: AnyObject {
    func run(update: @escaping @MainActor @Sendable (AudioDetectionSnapshot) -> Void) async throws
}

import Foundation
import PlatformKit

/// Photographer-owned tracking state; no device effects or runtime scheduling.
struct PhotographerTrackingPolicy {
    private var lastAim: (base: Double, pitch: Double, time: TimeInterval)?
    private var lastSampleTime: TimeInterval?
    private var filteredBase = 0.0
    private var filteredPitch = 0.0
    private var commandedBase = 0.0
    private var commandedPitch = 0.0

    /// Advance the commanded target only after the actor admits its output.
    mutating func commit(base: Double, pitch: Double, timestamp: TimeInterval) {
        commandedBase = base
        commandedPitch = pitch
        lastAim = (base, pitch, timestamp)
    }

    mutating func reset() {
        lastAim = nil
        lastSampleTime = nil
        filteredBase = 0
        filteredPitch = 0
        commandedBase = 0
        commandedPitch = 0
    }

    /// First published person. Nose at confidence ≥ 0.3 inside the image, otherwise the midpoint of such joints.
    /// `base` turns the base; `pitch` tips the wrist. Both advance in limited steps from the last command.
    mutating func nextAim(_ pose: PoseObservation) -> (base: Double, pitch: Double)? {
        guard pose.timestamp.isFinite, lastSampleTime.map({ pose.timestamp > $0 }) ?? true else { return nil }
        guard let person = pose.people.first else { return nil }
        guard let point = Self.aimPoint(person, width: pose.width, height: pose.height) else { return nil }
        let interval = NexArmDeviceLimits.positionUpdateIntervalSeconds
        let sampleDt = lastSampleTime.map { min(0.2, pose.timestamp - $0) } ?? interval
        lastSampleTime = pose.timestamp
        let errorX = point.x / Double(pose.width) - 0.5
        let errorY = point.y / Double(pose.height) - 0.5
        let baseError = Self.track(&filteredBase, error: errorX, dt: sampleDt)
        let pitchError = Self.track(&filteredPitch, error: errorY, dt: sampleDt)
        // No catch-up bursts: only the current sample can produce one new target.
        if let lastAim, pose.timestamp - lastAim.time < interval - 1e-9 { return nil }
        let dt = lastAim.map { min(0.2, pose.timestamp - $0.time) } ?? interval
        let baseStep = rateStep(baseError, gain: 1.15, limit: 0.55, dt: dt)
        let pitchStep = rateStep(pitchError, gain: 0.85, limit: 0.40, dt: dt)
        guard abs(baseStep) >= 0.001 || abs(pitchStep) >= 0.001 else { return nil }
        let base = min(1, max(-1, commandedBase + baseStep))
        let pitch = min(0.7, max(-0.7, commandedPitch + pitchStep))
        guard base != commandedBase || pitch != commandedPitch else { return nil }
        return (base, pitch)
    }

    /// Time-based filtering gives the same response at different observation rates.
    /// Reversing clears the old direction; centered samples stop accumulating immediately.
    private static func track(_ filtered: inout Double, error: Double, dt: TimeInterval) -> Double {
        let zone = 0.04
        let magnitude = abs(error)
        let shaped: Double
        if magnitude <= zone {
            shaped = 0
        } else {
            let extra = magnitude - zone
            shaped = copysign(extra * min(1, extra / zone), error)
        }
        if shaped == 0 {
            filtered = 0
        } else if filtered * shaped < 0 {
            filtered = shaped * (1 - exp(-dt / 0.12))
        } else if filtered == 0 {
            filtered = shaped
        } else {
            filtered += (1 - exp(-dt / 0.12)) * (shaped - filtered)
        }
        return filtered
    }

    private func rateStep(_ error: Double, gain: Double, limit: Double, dt: TimeInterval) -> Double {
        let rate = min(limit, max(-limit, gain * error))
        return rate * dt
    }

    static func aimPoint(_ person: [PoseObservation.Joint], width: Int, height: Int) -> (x: Double, y: Double)? {
        func usable(_ joint: PoseObservation.Joint) -> Bool {
            joint.confidence >= 0.3 && joint.x.isFinite && joint.y.isFinite && joint.x >= 0 && joint.y >= 0
                && Double(joint.x) <= Double(width) && Double(joint.y) <= Double(height)
        }
        if usable(person[0]) { return (Double(person[0].x), Double(person[0].y)) }
        let visible = person.filter(usable)
        guard !visible.isEmpty else { return nil }
        let count = Double(visible.count)
        let x = visible.reduce(0.0) { $0 + Double($1.x) } / count
        let y = visible.reduce(0.0) { $0 + Double($1.y) } / count
        return (x, y)
    }

}

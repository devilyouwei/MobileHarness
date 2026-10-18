import Foundation

/// Photographer-owned tracking state; no device effects or runtime scheduling.
struct PhotographerTrackingPolicy {
    private var lastAim: (base: Double, pitch: Double, time: TimeInterval)?
    private var filteredBase = 0.0
    private var filteredPitch = 0.0
    private var commandedBase = 0.0
    private var commandedPitch = 0.0
    private var resume = false

    /// Advance the commanded target only after the actor admits its output.
    mutating func commit(base: Double, pitch: Double, timestamp: TimeInterval) {
        commandedBase = base
        commandedPitch = pitch
        lastAim = (base, pitch, timestamp)
    }

    mutating func reset() {
        lastAim = nil
        filteredBase = 0
        filteredPitch = 0
        commandedBase = 0
        commandedPitch = 0
        resume = false
    }

    /// Keep the last command after the person leaves. The next pose only re-anchors time.
    mutating func holdForResume() {
        filteredBase = 0
        filteredPitch = 0
        guard lastAim != nil else { return }
        resume = true
    }

    private static let minimumInterval = 0.02
    private static let maximumInterval = 0.4
    private static let nominalInterval = 0.2

    /// First published person. Nose at confidence ≥ 0.3 inside the image, otherwise the midpoint of such joints.
    /// `base` turns the base; `pitch` tips the wrist. Both advance in limited steps from the last command.
    /// Each pose with an aim point can publish. `dt` is that pose's timestamp interval, clamped to
    /// 0.02...0.4 seconds, so the step uses the same interval as the publication. The first aim uses 0.2 seconds.
    /// After the person leaves, the next pose re-anchors the clock and does not add a catch-up step.
    mutating func nextAim(_ pose: PoseObservation) -> (base: Double, pitch: Double)? {
        guard let person = pose.people.first else {
            holdForResume()
            return nil
        }
        guard let point = Self.aimPoint(person, width: pose.width, height: pose.height) else {
            holdForResume()
            return nil
        }
        let errorX = point.x / Double(pose.width) - 0.5
        let errorY = point.y / Double(pose.height) - 0.5
        let baseError = Self.track(&filteredBase, error: errorX)
        let pitchError = Self.track(&filteredPitch, error: errorY)
        if resume {
            resume = false
            lastAim = (commandedBase, commandedPitch, pose.timestamp)
            return nil
        }
        let dt: TimeInterval
        if let lastAim {
            let elapsed = pose.timestamp - lastAim.time
            if elapsed < Self.minimumInterval { return nil }
            dt = min(Self.maximumInterval, elapsed)
        } else {
            dt = Self.nominalInterval
        }
        let baseStep = rateStep(baseError, gain: 1.15, limit: 0.55, dt: dt)
        let pitchStep = rateStep(pitchError, gain: 0.85, limit: 0.40, dt: dt)
        let base = min(1, max(-1, commandedBase + baseStep))
        let pitch = min(0.7, max(-0.7, commandedPitch + pitchStep))
        guard base != commandedBase || pitch != commandedPitch else { return nil }
        return (base, pitch)
    }

    /// Soft dead zone, then a smoothed error. A direction change starts from half the new error.
    private static func track(_ filtered: inout Double, error: Double) -> Double {
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
            filtered = shaped * 0.5
        } else if filtered == 0 {
            filtered = shaped
        } else {
            filtered += 0.55 * (shaped - filtered)
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

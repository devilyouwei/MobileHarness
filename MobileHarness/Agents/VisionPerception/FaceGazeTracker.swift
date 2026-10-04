import AgentCore
import Foundation
import Types

/// Bounded, identity-free attention policy. Coordinates are already upright; mirror only once.
struct FaceGazeTracker: Sendable {
    struct Target: Sendable, Equatable {
        var x = 0.0
        var y = 0.0
    }
    private struct Face {
        let center: Target
        let span: Double
        let quality: Double
    }
    let mirrored: Bool
    private var locked: Face?
    private var lastSeen: Double?
    private var lastTime: Double?
    private var rotation: Int?
    private var filtered = Target()

    init(mirrored: Bool) { self.mirrored = mirrored }

    mutating func update(_ observation: PoseObservation) -> Target {
        let now = observation.timestamp
        if rotation != observation.rotation {
            locked = nil
            lastSeen = nil
            lastTime = nil
            rotation = observation.rotation
        }
        let dt = min(0.25, max(0.001, now - (lastTime ?? (now - 0.1))))
        lastTime = now
        let candidates = observation.people.compactMap { face($0, observation: observation) }
        var selected: Face?
        if let locked, let lastSeen, now - lastSeen < 0.55 {
            selected = candidates.min { distance($0.center, locked.center) < distance($1.center, locked.center) }
            if let candidate = selected,
                distance(candidate.center, locked.center) > max(0.16, min(0.35, locked.span * 2.5))
            {
                selected = nil
            }
        } else {
            // Prefer a nearby, clearly observed face; array order never decides a lock.
            selected = candidates.max { score($0) < score($1) }
        }
        var desired = filtered
        if let selected {
            locked = selected
            lastSeen = now
            desired = Target(
                x: min(1, max(-1, (selected.center.x - 0.5) * 2.4 * (mirrored ? -1 : 1))),
                y: min(1, max(-1, (selected.center.y - 0.5) * 2.4)))
        } else if lastSeen.map({ now - $0 >= 0.35 }) ?? true {
            desired = Target()
            if lastSeen.map({ now - $0 >= 0.55 }) ?? true { locked = nil }
        }
        let displacement = distance(desired, filtered)
        // Small landmark noise stays still; real motion increases responsiveness.
        if displacement > 0.018 || desired == Target() {
            let response = selected == nil ? 0.24 : max(0.045, 0.11 - displacement * 0.12)
            let alpha = 1 - exp(-dt / response)
            filtered.x += (desired.x - filtered.x) * alpha
            filtered.y += (desired.y - filtered.y) * alpha
            if abs(filtered.x) < 0.001 { filtered.x = 0 }
            if abs(filtered.y) < 0.001 { filtered.y = 0 }
        }
        return filtered
    }

    private func face(_ joints: [PoseObservation.Joint], observation: PoseObservation) -> Face? {
        guard joints.count == 17 else { return nil }
        let reliable = joints.prefix(5).enumerated().filter { _, point in
            point.confidence >= 0.45 && point.x.isFinite && point.y.isFinite
                && (0...Float(observation.width)).contains(point.x)
                && (0...Float(observation.height)).contains(point.y)
        }
        // Two central landmarks minimum: a lone ear or nose must not steal attention.
        let central = reliable.filter { $0.offset < 3 }
        guard central.count >= 2 else { return nil }
        let weight = central.reduce(0.0) { $0 + Double($1.element.confidence) }
        let center = Target(
            x: central.reduce(0.0) { $0 + Double($1.element.x * $1.element.confidence) } / weight
                / Double(observation.width),
            y: central.reduce(0.0) { $0 + Double($1.element.y * $1.element.confidence) } / weight
                / Double(observation.height))
        let xs = reliable.map { Double($0.element.x) / Double(observation.width) }
        return Face(center: center, span: (xs.max() ?? 0) - (xs.min() ?? 0), quality: weight / Double(central.count))
    }
    private func distance(_ a: Target, _ b: Target) -> Double { hypot(a.x - b.x, a.y - b.y) }
    private func score(_ face: Face) -> Double {
        face.span * 2 + face.quality * 0.2 - distance(face.center, Target(x: 0.5, y: 0.5)) * 0.25
    }
}

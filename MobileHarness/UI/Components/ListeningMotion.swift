import Foundation

/// Normalized home-content coordinates; a host can supply these without a touch event.
public struct ListeningLightOrigin: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) {
        self.x = x.isFinite ? min(1, max(0, x)) : 0.5
        self.y = y.isFinite ? min(1, max(0, y)) : 0.4
    }
}

/// Monotonic, generation-scoped motion; no view identity or wall-clock dependency.
struct ListeningMotion: Sendable {
    private(set) var generation: String?
    private(set) var origin = ListeningLightOrigin(x: 0.5, y: 0.4)
    private(set) var activatedAt: Double = 0
    private(set) var fadeStartedAt: Double = 0
    private(set) var fadingFrom: Double = 0
    private(set) var active = false
    private(set) var reduceMotion = false
    private(set) var intensity = 1.0

    mutating func update(
        active: Bool, generation: String?, reduceMotion: Bool, origin: ListeningLightOrigin? = nil,
        initialOpacity: Double = 0.85, intensity: Double = 1, replayEntry: Bool = true, at time: Double
    ) {
        let current = opacity(at: time)
        let newActivation = active && (!self.active || self.generation != generation)
        if newActivation {
            self.origin = origin ?? ListeningLightOrigin(x: 0.5, y: 0.4)
            activatedAt = replayEntry ? time : time - 2
            fadeStartedAt = time
            fadingFrom = reduceMotion || !replayEntry ? current : max(initialOpacity, current)
        } else if self.active != active {
            fadeStartedAt = time
            fadingFrom = current
        }
        self.active = active
        self.generation = generation
        self.reduceMotion = reduceMotion
        if active { self.intensity = intensity }
    }

    func opacity(at time: Double) -> Double {
        let duration = reduceMotion ? 0.2 : 0.32
        let fraction = min(1, max(0, (time - fadeStartedAt) / duration))
        let eased = active && !reduceMotion ? 1 - pow(1 - fraction, 3) : fraction * fraction * (3 - 2 * fraction)
        return active ? fadingFrom + (1 - fadingFrom) * eased : fadingFrom * (1 - eased)
    }
    func elapsed(at time: Double) -> Double { reduceMotion ? 2 : max(0, time - activatedAt) }
    func needsFrame(at time: Double) -> Bool {
        active ? (!reduceMotion || opacity(at: time) < 1) : opacity(at: time) > 0
    }
    func isEntering(at time: Double) -> Bool { active && !reduceMotion && time - activatedAt < 1.05 }
}

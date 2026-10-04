import AgentCore
import Foundation
import Types

/// Agent-owned scheduling bounds. App supplies configuration, never motion policy.
public struct FrameSamplingConfiguration: Sendable {
    public let minimumInterval: TimeInterval
    public let maximumInterval: TimeInterval
    public let initialInterval: TimeInterval
    public let maximumObservationLatency: TimeInterval
    public init(
        minimumInterval: TimeInterval = 0, maximumInterval: TimeInterval = 0.25,
        initialInterval: TimeInterval = 0.1, maximumObservationLatency: TimeInterval = 0.75
    ) throws {
        guard minimumInterval.isFinite, maximumInterval.isFinite, initialInterval.isFinite,
            (0...1).contains(minimumInterval), (0...1).contains(maximumInterval), maximumInterval > 0,
            minimumInterval <= initialInterval, initialInterval <= maximumInterval,
            maximumObservationLatency.isFinite, maximumObservationLatency > 0, maximumObservationLatency <= 1
        else { throw ImageInputError.invalidFrame }
        self.minimumInterval = minimumInterval
        self.maximumInterval = maximumInterval
        self.initialInterval = initialInterval
        self.maximumObservationLatency = maximumObservationLatency
    }
}

/// Bounded image/pose evidence and compute/freshness budgets drive the next interval.
public struct FrameCadence: Sendable {
    private struct Point: Sendable {
        let x: Double
        let y: Double
        let confidence: Double
    }
    private struct Person: Sendable {
        let joints: [Point?]
        let x: Double
        let y: Double
        let span: Double
        let confidence: Double
        let visible: Int
    }
    private let configuration: FrameSamplingConfiguration
    public private(set) var interval: TimeInterval
    private var demandInterval: TimeInterval
    private var inferenceCost: TimeInterval?
    private var latencyPressure = false
    private var imageMotion = FrameMotionAnalyzer()
    private var poseStableForNoise = false
    public private(set) var imageActivity: Double?
    public private(set) var staleInputs = 0
    public var maximumObservationLatency: TimeInterval { configuration.maximumObservationLatency }
    private var previous: [Person] = []
    private var previousCount: Int?
    private var resultTimestamp: TimeInterval?
    private var stableSince: TimeInterval?
    private var recoveryUntil: TimeInterval?
    private var geometry: [Int]?
    private var lastAcceptedAt: TimeInterval?
    private var lastStartedAt: ContinuousClock.Instant?
    private var lastSequence: UInt64?
    private var lastTimestamp: TimeInterval?

    public init(configuration: FrameSamplingConfiguration) {
        self.configuration = configuration
        interval = configuration.initialInterval
        demandInterval = configuration.initialInterval
    }
    /// Called only after taking the newest slot. Optional clock supports actual inter-start throttling.
    public mutating func accepts(_ frame: ImageInput, at now: ContinuousClock.Instant? = nil) throws -> Bool {
        guard lastSequence.map({ frame.sequence > $0 }) ?? true,
            lastTimestamp.map({ frame.timestamp >= $0 }) ?? true
        else { throw ImageInputError.outOfOrder }
        lastSequence = frame.sequence
        lastTimestamp = frame.timestamp
        resetGeometry([frame.width, frame.height, frame.rotation])
        if let now, let capturedAt = frame.capturedAt {
            let age = Self.seconds(capturedAt.duration(to: now))
            if age < 0 || age >= configuration.maximumObservationLatency {
                staleInputs += 1
                return false
            }
        }
        let sample = try FrameMotionAnalyzer.sample(frame)
        imageActivity = imageMotion.measure(sample, at: frame.timestamp, learnNoise: poseStableForNoise)
        if let imageActivity, imageActivity >= 0.1 {
            let activity = min(1, (imageActivity - 0.1) / 0.4)
            let target = configuration.initialInterval * (1 - activity) + configuration.minimumInterval * activity
            demandInterval = min(demandInterval, target)
            stableSince = nil
            poseStableForNoise = false
            updateInterval()
        }
        if let lastAcceptedAt, frame.timestamp - lastAcceptedAt < interval { return false }
        if let now, let lastStartedAt, Self.seconds(lastStartedAt.duration(to: now)) < interval { return false }
        imageMotion.recordInference(sample, at: frame.timestamp)
        lastAcceptedAt = frame.timestamp
        lastStartedAt = now
        return true
    }
    /// Update only with a validated fresh result. Invalid cost must fail rather than change scheduling silently.
    public mutating func observe(
        _ observation: PoseObservation, inferenceDuration: TimeInterval, totalLatency: TimeInterval? = nil
    ) throws {
        try observation.validate()
        guard inferenceDuration.isFinite, inferenceDuration >= 0,
            totalLatency.map({ $0.isFinite && $0 >= inferenceDuration }) ?? true,
            resultTimestamp.map({ observation.timestamp >= $0 }) ?? true
        else { throw ImageInputError.invalidFrame }
        resetGeometry([observation.width, observation.height, observation.rotation])
        try observeTiming(inferenceDuration: inferenceDuration, totalLatency: totalLatency)
        let people = Self.people(observation)
        let time = observation.timestamp
        let elapsed = resultTimestamp.map { time - $0 } ?? 0
        var target = configuration.initialInterval
        poseStableForNoise = false
        if observation.people.isEmpty {
            stableSince = nil
            poseStableForNoise = previousCount == 0
            if let previousCount, previousCount > 0 { recoveryUntil = time + 0.5 }
            target =
                time < (recoveryUntil ?? 0)
                ? configuration.minimumInterval : min(configuration.maximumInterval, 0.2)
        } else if previousCount != observation.people.count || people.count != min(observation.people.count, 6)
            || previous.count != people.count || elapsed <= 0
        {
            stableSince = nil
            recoveryUntil = nil
            target = configuration.minimumInterval
        } else if let speed = Self.motion(people, previous: previous, elapsed: elapsed) {
            recoveryUntil = nil
            if speed <= 0.08 {
                poseStableForNoise = true
                if stableSince == nil { stableSince = time }
                target =
                    time - (stableSince ?? time) >= 0.6
                    ? configuration.maximumInterval : configuration.initialInterval
            } else {
                stableSince = nil
                let activity = min(1, (speed - 0.08) / (0.35 - 0.08))
                target = configuration.initialInterval * (1 - activity) + configuration.minimumInterval * activity
            }
        } else {
            stableSince = nil
            target = configuration.minimumInterval
        }
        imageMotion.updateRegions(observation)
        if let imageActivity, imageActivity >= 0.1 {
            let activity = min(1, (imageActivity - 0.1) / 0.4)
            let imageTarget = configuration.initialInterval * (1 - activity) + configuration.minimumInterval * activity
            target = min(target, imageTarget)
            stableSince = nil
            poseStableForNoise = false
        }
        if latencyPressure { target = min(target, configuration.initialInterval) }
        // Faster response is immediate; slower cadence approaches its target over 0.5 seconds.
        let relaxation = 1 - exp(-min(elapsed, 1) / 0.5)
        demandInterval = target <= demandInterval ? target : demandInterval + (target - demandInterval) * relaxation
        updateInterval()
        previous = people
        previousCount = observation.people.count
        resultTimestamp = time
    }
    /// Stale results can update timing pressure without becoming pose/UI observations.
    public mutating func observeTiming(inferenceDuration: TimeInterval, totalLatency: TimeInterval? = nil) throws {
        guard inferenceDuration.isFinite, inferenceDuration >= 0,
            totalLatency.map({ $0.isFinite && $0 >= inferenceDuration }) ?? true
        else { throw ImageInputError.invalidFrame }
        latencyPressure = totalLatency.map { $0 >= configuration.maximumObservationLatency * 0.75 } ?? false
        // Serial execution already bounds normal utilization: urgent demand adds no artificial gap.
        // Apply a cost floor only while measured computation causes freshness pressure.
        let computePressure =
            inferenceDuration >= configuration.maximumObservationLatency * 0.75
            || (latencyPressure && inferenceDuration >= (totalLatency ?? 0) * 0.5)
        let boundedCost = computePressure ? min(configuration.maximumInterval, inferenceDuration * 1.5) : 0
        if !computePressure {
            inferenceCost = nil
        } else if let inferenceCost {
            self.inferenceCost = boundedCost >= inferenceCost ? boundedCost : inferenceCost * 0.8 + boundedCost * 0.2
        } else {
            inferenceCost = boundedCost
        }
        if latencyPressure { demandInterval = min(demandInterval, configuration.initialInterval) }
        updateInterval()
    }
    private mutating func resetGeometry(_ shape: [Int]) {
        guard geometry != shape else { return }
        imageMotion = FrameMotionAnalyzer()
        imageActivity = nil
        poseStableForNoise = false
        previous = []
        previousCount = nil
        resultTimestamp = nil
        stableSince = nil
        recoveryUntil = nil
        demandInterval = configuration.initialInterval
        updateInterval()
        geometry = shape
    }
    private mutating func updateInterval() {
        interval = min(
            configuration.maximumInterval,
            max(configuration.minimumInterval, demandInterval, inferenceCost ?? 0))
    }
    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
    private static func people(_ observation: PoseObservation) -> [Person] {
        let diagonal = hypot(Double(observation.width), Double(observation.height))
        return observation.people.prefix(6).compactMap { joints in
            let points: [Point?] = joints.map { joint in
                guard joint.confidence >= 0.45, joint.x >= 0, joint.y >= 0,
                    joint.x <= Float(observation.width), joint.y <= Float(observation.height)
                else { return nil }
                return Point(
                    x: Double(joint.x) / diagonal, y: Double(joint.y) / diagonal,
                    confidence: Double(joint.confidence))
            }
            let visible = points.compactMap { $0 }
            guard visible.count >= 4 else { return nil }
            let confidence = visible.reduce(0) { $0 + $1.confidence } / Double(visible.count)
            guard confidence >= 0.6 else { return nil }
            let x = visible.reduce(0) { $0 + $1.x } / Double(visible.count)
            let y = visible.reduce(0) { $0 + $1.y } / Double(visible.count)
            let span = hypot(
                (visible.map(\.x).max() ?? x) - (visible.map(\.x).min() ?? x),
                (visible.map(\.y).max() ?? y) - (visible.map(\.y).min() ?? y))
            return Person(
                joints: points, x: x, y: y, span: max(0.08, span),
                confidence: confidence, visible: visible.count)
        }
    }
    /// Bounded one-to-one spatial association prevents array reordering from creating motion.
    private static func motion(_ people: [Person], previous: [Person], elapsed: Double) -> Double? {
        var remaining = Array(previous.indices)
        var maximumSpeed = 0.0
        for person in people {
            guard
                let match = remaining.min(by: {
                    hypot(person.x - previous[$0].x, person.y - previous[$0].y)
                        < hypot(person.x - previous[$1].x, person.y - previous[$1].y)
                })
            else { return nil }
            let old = previous[match]
            guard hypot(person.x - old.x, person.y - old.y) <= max(0.08, old.span * 0.6),
                old.confidence - person.confidence < 0.15, old.visible - person.visible < 4
            else { return nil }
            remaining.removeAll { $0 == match }
            var displacement = 0.0
            var common = 0
            for (new, old) in zip(person.joints, old.joints) {
                guard let new, let old else { continue }
                // Ignore a small image-relative jitter floor before computing body-relative velocity.
                displacement += max(0, hypot(new.x - old.x, new.y - old.y) - 0.003)
                common += 1
            }
            guard common >= 4 else { return nil }
            maximumSpeed = max(maximumSpeed, displacement / Double(common) / max(person.span, old.span) / elapsed)
        }
        return maximumSpeed
    }
}

import Foundation

// Historical causal-test policy only. Production uses Actions.NexArmSegmentTracker.
/// Host observation watchdog. Receipt timestamps are not device sampling timestamps.
public struct NexArmArrivalTracker: Sendable {
    public enum Outcome: Sendable, Equatable { case waiting, arrived, feedbackTimeout, completionTimeout }
    /// Each awaited segment needs its own bounded settling/observation allowance.
    public static func completionBudget(durationMilliseconds: Int) -> Duration {
        .milliseconds(durationMilliseconds + 3000)
    }
    private let target: [Int]
    private let jointTarget: [Int]?
    private let includeClaw: Bool
    private let final: Bool
    private let started: ContinuousClock.Instant
    private let deadline: ContinuousClock.Instant
    private let earliestObservation: ContinuousClock.Instant
    private var lastFeedback: ContinuousClock.Instant
    private var stableSince: ContinuousClock.Instant?
    private var anchor: [Int]?
    public init(
        target: [Int], final: Bool, started: ContinuousClock.Instant, durationMilliseconds: Int,
        actionDeadline: ContinuousClock.Instant? = nil, jointTarget: [Int]? = nil,
        minimumObservationMilliseconds: Int = 0, includeClaw: Bool = true
    ) {
        self.target = target
        self.jointTarget = jointTarget
        self.includeClaw = includeClaw
        self.final = final
        self.started = started
        // Stable early feedback can describe a stationary start or an intermediate plateau
        // while firmware still owns the trajectory. Never hand off before its nominal end.
        earliestObservation = started.advanced(
            by: .milliseconds(max(durationMilliseconds, minimumObservationMilliseconds)))
        let segmentDeadline = started.advanced(by: Self.completionBudget(durationMilliseconds: durationMilliseconds))
        deadline = min(segmentDeadline, actionDeadline ?? segmentDeadline)
        lastFeedback = started
    }
    public mutating func observe(pose: [Int], joints: [Int], at time: ContinuousClock.Instant) {
        guard pose.count == 6, target.count == 6, joints.count == 6, time >= started, time >= lastFeedback else {
            return
        }
        lastFeedback = time
        let poseArrived =
            zip(pose.prefix(3), target.prefix(3)).allSatisfy { abs($0 - $1) <= (final ? 5 : 15) }
            && abs(pose[3] - target[3]) <= (final ? 20 : 40)
            && abs(pose[4] - target[4]) <= 2 && (!includeClaw || abs(pose[5] - target[5]) <= 2)
        let observedJoints = Array(joints.prefix(includeClaw ? 6 : 5))
        let arrived =
            jointTarget.map { target in
                target.count == 6 && zip(observedJoints, target).allSatisfy { abs($0 - $1) <= 16 }
            } ?? poseArrived
        guard arrived else {
            stableSince = nil
            anchor = nil
            return
        }
        if let anchor, zip(observedJoints, anchor).allSatisfy({ abs($0 - $1) <= 2 }) { return }
        anchor = observedJoints
        stableSince = time
    }
    public func outcome(at time: ContinuousClock.Instant) -> Outcome {
        if time >= deadline { return .completionTimeout }
        if time - lastFeedback >= .seconds(2) { return .feedbackTimeout }
        // Only received samples can advance the stable window, never wall-clock waiting alone.
        if lastFeedback >= earliestObservation, let stableSince,
            lastFeedback - stableSince >= .milliseconds(final ? 300 : 200)
        {
            return .arrived
        }
        return .waiting
    }
}

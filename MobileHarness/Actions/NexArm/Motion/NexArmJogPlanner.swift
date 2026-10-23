import Foundation
import FunctionContracts
import PlatformKit

/// Bounded velocity shaping with finite look-ahead position goals; no telemetry/ACK dependency.
public struct NexArmJogPlanner: Sendable {
    public static let limits = NexArmMotorCommands.positionLimits
    public static let period = 0.03
    public static let maximumSpeed = 600.0
    public static let maximumAcceleration = 1800.0
    public static let maximumJerk = 12000.0
    /// Tracking crawl. A full stick may still use `maximumSpeed`; aim must not sprint the whole gap.
    public static let aimMaximumSpeed = 200.0
    /// Shoulder lift and elbow tracking speed. 60 counts/s was verified for the paired move on 2026-10-03.
    public static let aimReachSpeed = 100.0
    private struct State: Sendable {
        var position: Double
        var velocity = 0.0
        var acceleration = 0.0
        var lastTarget: Int
    }
    private var states: [State]
    public var targets: [Double] { states.map { Double($0.lastTarget) } }
    public var velocities: [Double] { states.map(\.velocity) }
    public var accelerations: [Double] { states.map(\.acceleration) }
    public struct Proposal: Sendable {
        public let id: Int
        public let packet: NexArmPacket?
        public let target: Double
        fileprivate let position: Double
        fileprivate let velocity: Double
        fileprivate let acceleration: Double
    }
    public init(positions: [Int]) throws {
        guard positions.count == 6, positions.allSatisfy({ (0...4095).contains($0) }) else {
            throw NexArmError.invalidPacket
        }
        states = positions.map { State(position: Double($0), lastTarget: $0) }
    }
    public func proposal(id: Int, deflection: Double, elapsed: Double = period) throws -> Proposal? {
        guard (1...6).contains(id), deflection.isFinite, (-1...1).contains(deflection),
            elapsed.isFinite, elapsed > 0
        else { throw NexArmExecutionError.invalidArguments }
        guard abs(deflection) > 0.04 else { return nil }
        let dt = min(elapsed, 0.06)  // Never catch up an accumulated transport stall.
        let index = id - 1
        let old = states[index]
        let input = (abs(deflection) - 0.04) / 0.96
        let desiredVelocity = (deflection < 0 ? -1.0 : 1.0) * input * input * Self.maximumSpeed
        func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double { min(upper, max(lower, value)) }
        let desiredAcceleration = clamp(
            (desiredVelocity - old.velocity) * 8, -Self.maximumAcceleration, Self.maximumAcceleration)
        var acceleration =
            old.acceleration
            + clamp(desiredAcceleration - old.acceleration, -Self.maximumJerk * dt, Self.maximumJerk * dt)
        var velocity = clamp(
            old.velocity + (old.acceleration + acceleration) * 0.5 * dt, -Self.maximumSpeed, Self.maximumSpeed)
        let lower = min(Double(Self.limits[index].lowerBound), old.position, Double(old.lastTarget))
        let upper = max(Double(Self.limits[index].upperBound), old.position, Double(old.lastTarget))
        let position = clamp(old.position + (old.velocity + velocity) * 0.5 * dt, lower, upper)
        if (position >= upper && velocity > 0) || (position <= lower && velocity < 0) {
            velocity = 0
            acceleration = 0
        }
        // A short finite lead bridges transport jitter; it never becomes an endless velocity command.
        var goal = clamp(position + velocity * 0.06, lower, upper)
        if old.velocity * velocity > 0 {
            goal = velocity > 0 ? max(goal, Double(old.lastTarget)) : min(goal, Double(old.lastTarget))
        }
        let target = Int(goal.rounded())
        let packet: NexArmPacket?
        if target == old.lastTarget {
            packet = nil  // Preserve fractional integration without restarting an identical servo goal.
        } else {
            let speed = min(600, max(1, Int(abs(velocity).rounded())))
            // Vendor HX_30HM write_pos_ex: ACC, position, PWM=0, speed. No unsolicited pose query.
            packet = try NexArmPacket(
                id: UInt8(id), command: 3,
                payload: [41, 30, UInt8(target & 255), UInt8(target >> 8), 0, 0, UInt8(speed & 255), UInt8(speed >> 8)])
        }
        return Proposal(
            id: id, packet: packet, target: Double(target), position: position,
            velocity: velocity, acceleration: acceleration)
    }

    /// One jerk-limited step toward an absolute count.
    /// Production tracking uses `NexArmAimCommand` instead of this stream.
    /// Speed follows the remaining distance and stays at `speedLimit` (default `aimMaximumSpeed`).
    /// A direction change holds the current count for one step so the previous speed is not carried into the
    /// reverse move.
    /// Returns nil once the joint is already on that count and no longer moving.
    public mutating func approach(
        id: Int, target: Int, elapsed: Double = period, speedLimit: Double = aimMaximumSpeed
    ) throws -> Proposal? {
        guard (1...5).contains(id), Self.limits[id - 1].contains(target), elapsed.isFinite, elapsed > 0,
            speedLimit.isFinite, speedLimit > 0, speedLimit <= Self.maximumSpeed
        else {
            throw NexArmExecutionError.invalidArguments
        }
        let dt = min(elapsed, 0.06)
        let index = id - 1
        let old = states[index]
        let error = Double(target) - old.position
        if abs(error) <= 2, abs(old.velocity) < 8, old.lastTarget == target {
            return nil
        }
        func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double { min(upper, max(lower, value)) }
        if old.velocity * error < 0, abs(old.velocity) >= 8 {
            let bounds = Self.limits[index]
            let hold = clamp(old.position.rounded(), Double(bounds.lowerBound), Double(bounds.upperBound))
            let holdCount = Int(hold)
            let packet: NexArmPacket?
            if holdCount == old.lastTarget {
                packet = nil
            } else {
                packet = try NexArmPacket(
                    id: UInt8(id), command: 3,
                    payload: [41, 30, UInt8(holdCount & 255), UInt8(holdCount >> 8), 0, 0, 1, 0])
            }
            return Proposal(
                id: id, packet: packet, target: Double(holdCount), position: hold,
                velocity: 0, acceleration: 0)
        }
        let desiredVelocity = clamp(error / 0.5, -speedLimit, speedLimit)
        let desiredAcceleration = clamp(
            (desiredVelocity - old.velocity) * 8, -Self.maximumAcceleration, Self.maximumAcceleration)
        var acceleration =
            old.acceleration
            + clamp(desiredAcceleration - old.acceleration, -Self.maximumJerk * dt, Self.maximumJerk * dt)
        var velocity = clamp(
            old.velocity + (old.acceleration + acceleration) * 0.5 * dt, -speedLimit, speedLimit)
        let lower = Double(Self.limits[index].lowerBound)
        let upper = Double(Self.limits[index].upperBound)
        var position = clamp(old.position + (old.velocity + velocity) * 0.5 * dt, lower, upper)
        if abs(Double(target) - position) <= 2, abs(velocity) < 8 {
            // Commit the final count only after native admission; otherwise a fractional
            // position just short of the target can keep the worker alive indefinitely.
            position = Double(target)
            velocity = 0
            acceleration = 0
        }
        var goal = position + velocity * 0.06
        if target >= Int(old.position.rounded()) {
            goal = min(max(goal, position), Double(target))
        } else {
            goal = max(min(goal, position), Double(target))
        }
        goal = clamp(goal, lower, upper)
        let next = Int(goal.rounded())
        let packet: NexArmPacket?
        if next == old.lastTarget {
            packet = nil
        } else {
            let speed = min(600, max(1, Int(abs(velocity).rounded())))
            packet = try NexArmPacket(
                id: UInt8(id), command: 3,
                payload: [41, 30, UInt8(next & 255), UInt8(next >> 8), 0, 0, UInt8(speed & 255), UInt8(speed >> 8)])
        }
        return Proposal(
            id: id, packet: packet, target: Double(next), position: position,
            velocity: velocity, acceleration: acceleration)
    }

    public mutating func accept(_ proposal: Proposal) {
        let index = proposal.id - 1
        states[index].position = proposal.position
        states[index].velocity = proposal.velocity
        states[index].acceleration = proposal.acceleration
        if proposal.packet != nil { states[index].lastTarget = Int(proposal.target) }
    }
    /// Release discards future velocity, keeping the last finite target; never sends a return move.
    public mutating func stop(id: Int) {
        guard (1...6).contains(id) else { return }
        let target = states[id - 1].lastTarget
        states[id - 1] = State(position: Double(target), lastTarget: target)
    }
}

import ActionRuntime
import Foundation
import PlatformKit

public struct NexArmMotorCompletion: Sendable, Equatable {
    public let tolerance: Int?
    public let stableTolerance: Int
    public let offTargetMilliseconds: Int
    public let feedbackMilliseconds: Int
    public let timeoutMilliseconds: Int?
    public init(
        tolerance: Int? = nil, stableTolerance: Int = 2,
        offTargetMilliseconds: Int = 600, feedbackMilliseconds: Int = 2000,
        timeoutMilliseconds: Int? = nil
    ) throws {
        guard tolerance.map({ (0...64).contains($0) }) ?? true, (0...8).contains(stableTolerance),
            (100...60_000).contains(offTargetMilliseconds),
            (200...5000).contains(feedbackMilliseconds),
            timeoutMilliseconds.map({ (200...86_400_000).contains($0) }) ?? true
        else { throw NexArmError.invalidMotion }
        self.tolerance = tolerance
        self.stableTolerance = stableTolerance
        self.offTargetMilliseconds = offTargetMilliseconds
        self.feedbackMilliseconds = feedbackMilliseconds
        self.timeoutMilliseconds = timeoutMilliseconds
    }
}
public struct NexArmMotorResult: Sendable, Equatable {
    public enum Failure: String, Sendable {
        case targetNotReached, timedOut, feedbackLost, disconnected, sendingFailed, cancelled
    }
    public let step: Int
    public let motor: Int
    public let target: Int
    public let observed: Int?
    public let failure: Failure?
    public let started: Bool
}

/// Business execution failures, separate from device transport/protocol errors.
public enum NexArmActionError: Error, Equatable, Sendable {
    case targetsNotReached([Int])
    case motionTimedOut([Int])
    case alreadyUsed, moving, uncertainMotion
}

/// Reset is an Action operation: the caller selects the configured home.
public enum NexArmMotorReset {
    public static func reset(motor: Int, home: [Int: Int], options: NexArmMotorOptions) throws -> NexArmPacket {
        guard let target = home[motor] else { throw NexArmError.invalidMotion }
        return try NexArmMotorCommands.move(motor: motor, target: target, options: options)
    }
}

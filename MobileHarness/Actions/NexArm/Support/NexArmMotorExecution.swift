import Foundation
import FunctionContracts
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
        else { throw NexArmExecutionError.invalidArguments }
        self.tolerance = tolerance
        self.stableTolerance = stableTolerance
        self.offTargetMilliseconds = offTargetMilliseconds
        self.feedbackMilliseconds = feedbackMilliseconds
        self.timeoutMilliseconds = timeoutMilliseconds
    }
}
public struct NexArmMotorResult: Sendable, Equatable {
    public enum Failure: String, Sendable {
        case targetNotReached, timedOut, feedbackLost, disconnected, sendingFailed, admissionFailed, feedbackFailed,
            cancelled
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
    case moving, uncertainMotion
}

/// Reset is an Action operation: the caller selects the configured home.
public enum NexArmMotorReset {
    public static func reset(motor: Int, home: [Int: Int], options: NexArmMotorOptions) throws -> NexArmPacket {
        guard let target = home[motor] else { throw NexArmExecutionError.invalidArguments }
        return try NexArmMotorCommands.move(motor: motor, target: target, options: options)
    }
}

/// Invocation/admission errors owned by Actions; unrelated to Bluetooth diagnostic events.
public enum NexArmExecutionError: LocalizedError, Sendable, Equatable, ActionReportFailureProviding {
    case disconnected, busy, background, controlNotReady, feedbackTimeout
    case invalidArguments, unsupportedFirmware, firmwareUnavailable, admissionTimeout
    case resourceBusy
    case resourceUnavailable(String)
    public var actionExecutionFailure: ActionFailure {
        let identifier: String
        switch self {
        case .disconnected: identifier = "disconnected"
        case .busy: identifier = "busy"
        case .resourceBusy, .resourceUnavailable: identifier = "resourceUnavailable"
        case .background: identifier = "background"
        case .controlNotReady: identifier = "controlNotReady"
        case .feedbackTimeout: identifier = "feedbackTimeout"
        case .invalidArguments: identifier = "invalidArguments"
        case .unsupportedFirmware, .firmwareUnavailable: identifier = "unavailable"
        case .admissionTimeout: identifier = "admissionTimeout"
        }
        return ActionFailure(rawValue: identifier)
    }
    public var actionReportCode: ActionReport.Entry.Code {
        switch self {
        case .feedbackTimeout: .feedbackLost
        case .disconnected: .disconnected
        case .invalidArguments: .invalidArguments
        case .admissionTimeout: .timedOut
        case .busy, .controlNotReady, .background, .resourceBusy, .resourceUnavailable, .unsupportedFirmware,
            .firmwareUnavailable:
            .unavailable
        }
    }
    public var errorDescription: String? {
        switch self {
        case .invalidArguments: "动作参数或执行计划无效"
        case .unsupportedFirmware: "当前固件不支持此动作"
        case .firmwareUnavailable: "尚未取得动作所需的固件信息"
        case .admissionTimeout: "动作发送准入超时，指令未提交"
        case .disconnected: "设备操作当前不可用"
        case .busy: "机械臂正在处理上一项操作，请稍后重试"
        case .resourceBusy: "电机控制资源正在被其他操作占用，请稍后重试"
        case .resourceUnavailable(let reason): "电机控制资源不可用：\(reason)"
        case .background: "请保持应用在前台后再控制机械臂"
        case .feedbackTimeout: "动作等待位置反馈超时，执行未完成"
        case .controlNotReady: "设备操作当前尚未就绪"
        }
    }
}

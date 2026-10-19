import ActionBindings
import AgentCore
import Foundation
import FunctionContracts
import PlatformKit
import StorageCore
import UI

private struct ActionActivityMapping: Identifiable, Equatable, Sendable {
    public let execution: ActionExecutionRecord
    public var title: String { execution.displayName }
    public var channelTitle: String { execution.channel }
    public var report: AgentActionReport? {
        if case .report(let report) = execution.completion { return report }
        return nil
    }
    public var issueDescriptions: [String] {
        guard let report else { return [] }
        let executionIssues: [String] =
            report.executionFailure.flatMap {
                guard $0 != .cancelled else { return nil }
                return
                    [
                        report.failureDescription ?? execution.failureDescription
                            ?? ($0 == .timedOut ? "动作执行超时，已结束并保留各步骤结果" : "动作执行失败")
                    ]
            } ?? []
        return executionIssues
            + report.entries.enumerated().compactMap { index, entry in
                guard entry.status == .failed, entry.code?.rawValue != "cancelled" else { return nil }
                let reason: String
                switch entry.code?.rawValue {
                case "targetNotReached": reason = "稳定后仍未到位"
                case "feedbackLost": reason = "未收到位置反馈"
                case "disconnected": reason = "机械臂连接不可用"
                case "sendingFailed": reason = "指令发送失败"
                case "admissionFailed": reason = "执行通道准入失败"
                case "feedbackFailed": reason = "位置反馈处理失败"
                case "timedOut": reason = "执行超时"
                case "invalidArguments": reason = "参数无效"
                case "unavailable": reason = "当前不可执行"
                case "cancelled": reason = entry.status == .notStarted ? "已取消，未执行" : "执行已取消"
                case "resultCapacityExceeded": reason = "结果数量超出声明上限"
                default:
                    if report.entries.count == 1, let detail = execution.failureDescription, !detail.isEmpty {
                        reason = detail
                    } else {
                        reason = "执行失败"
                    }
                }
                let capturedReason = entry.details["failureDescription"] ?? reason
                let motor = entry.details["motor"].map { " · \($0)号电机" } ?? ""
                let position: String
                if let target = entry.details["target"], let observed = entry.details["observed"] {
                    position = "（目标 \(target)，反馈 \(observed)）"
                } else {
                    position = ""
                }
                return "第\(index + 1)项\(motor)：\(capturedReason)\(position)"
            }
    }
    public var status: String {
        switch execution.phase {
        case .queued: "等待执行"
        case .running: "正在执行"
        case .cancelling: "正在取消"
        case .cancelled: execution.startedAt == nil ? "执行前已取消" : "已取消"
        case .succeeded:
            switch execution.completion {
            case .activityStarted: "已启动"
            case .activityStopped: "已结束"
            default:
                execution.semantics == .state || execution.semantics == .activityUpdate ? "已设置" : "已完成"
            }
        case .failed:
            if let report, report.hasFailures {
                "\(report.status == .partialFailure ? "部分完成" : "执行失败") · \(report.entries.filter { $0.status == .failed }.count + (report.executionFailure == nil ? 0 : 1))项问题"
            } else {
                execution.failureDescription ?? "执行未完成"
            }
        }
    }
    public var id: String { execution.id }
    public var channel: String { execution.channel }
    public var isActive: Bool { !execution.isTerminal }
    public var isFailure: Bool { execution.phase == .failed }
    public var symbol: String {
        switch execution.phase {
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .cancelling: "hourglass"
        case .succeeded: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .cancelled: "minus.circle"
        }
    }
    public init(execution: ActionExecutionRecord) {
        self.execution = execution
    }
}

extension ActionActivityItem {
    public init(execution: ActionExecutionRecord) {
        let mapped = ActionActivityMapping(execution: execution)
        self.init(
            id: execution.id, title: mapped.title, channel: mapped.channel, status: mapped.status,
            issueDescriptions: mapped.issueDescriptions, symbol: mapped.symbol,
            execution: .init(
                phase: execution.phase.presentationPhase, admittedAt: execution.admittedAt,
                startedAt: execution.startedAt, endedAt: execution.endedAt),
            source: execution.source.rawValue, inputID: execution.inputID,
            isInternal: [
                "UI.Caption.print", "UI.Caption.beginReplyTurn", "UI.Expression.setReplyWaiting",
                "Speech.Listening.update",
            ].contains(
                execution.path.description))
    }
}

extension ActionExecutionRecord.Phase {
    var presentationPhase: ActionActivityItem.Execution.Phase {
        switch self {
        case .queued: .queued
        case .running: .running
        case .cancelling: .cancelling
        case .succeeded: .succeeded
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }
}

extension SignalTraceRecord.Phase {
    var displayTitle: String {
        switch self {
        case .delivering: "投递中"
        case .accepted: "已接纳"
        case .partial: "部分接纳"
        case .rejected: "接纳失败"
        case .suppressed: "已抑制"
        case .dropped: "已丢弃"
        case .unobserved: "无订阅者"
        }
    }
}

extension AgentTaskSignal.Kind {
    var logTitle: String {
        switch self {
        case .request: "委派任务"
        case .input: "补充输入"
        case .progress: "任务进度"
        case .result: "任务结果"
        case .cancel: "取消请求"
        }
    }
}
extension AgentLifecycle {
    var logTitle: String {
        switch self {
        case .registered: "已注册"
        case .running: "已运行"
        case .paused: "已暂停"
        case .stopped: "已停止"
        case .failed: "运行失败"
        }
    }
}

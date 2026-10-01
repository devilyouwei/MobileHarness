import AgentCore
import Foundation
import Observation

public struct ActionActivityItem: Identifiable, Equatable, Sendable {
    public let execution: ActionExecutionRecord
    public var title: String { execution.displayName }
    public var channelTitle: String { execution.channel }
    public var report: ActionReport? {
        if case .report(let report) = execution.completion { return report }
        return nil
    }
    public var issueDescriptions: [String] {
        guard let report else { return [] }
        let executionIssues = report.executionFailure.map { [$0 == .timedOut ? "动作执行超时，已结束并保留各步骤结果" : "动作执行失败"] } ?? []
        return executionIssues
            + report.entries.enumerated().compactMap { index, entry in
                guard entry.status != .succeeded else { return nil }
                let reason: String
                switch entry.code {
                case .targetNotReached: reason = "稳定后仍未到位"
                case .feedbackLost: reason = "未收到位置反馈"
                case .disconnected: reason = "机械臂连接不可用"
                case .sendingFailed: reason = "指令发送失败"
                case .timedOut: reason = "执行超时"
                case .invalidArguments: reason = "参数无效"
                case .unavailable: reason = "当前不可执行"
                case .cancelled: reason = entry.status == .notStarted ? "已取消，未执行" : "执行已取消"
                case .resultCapacityExceeded: reason = "结果数量超出声明上限"
                case .handlerFailed, nil: reason = "执行失败"
                }
                let motor = entry.motor.map { " · \($0)号电机" } ?? ""
                let position: String
                if let target = entry.target, let observed = entry.observed {
                    position = "（目标 \(target)，反馈 \(observed)）"
                } else {
                    position = ""
                }
                return "第\(index + 1)项\(motor)：\(reason)\(position)"
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
    public var id: UUID { execution.id }
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

/// Display aggregation by exact channel name; not a cross-task execution lane.
public struct ActionChannelSummary: Identifiable {
    public let item: ActionActivityItem
    public let additionalRunning: Int
    public let queued: Int
    public var id: String { item.channel }
}

/// Presentation only. The root-owned workflow consumes snapshots; views never own observation tasks.
@MainActor @Observable
public final class ActionActivityState {
    public private(set) var items: [ActionActivityItem] = []
    public private(set) var revision: UInt64?
    public private(set) var evictedCount: UInt64 = 0
    public var observationUnavailable = false
    private var dismissed: Set<UUID> = []

    public init() {}
    public func replace(revision: UInt64, records: [ActionExecutionRecord], evictedCount: UInt64) {
        guard self.revision == nil || revision > self.revision! else { return }
        self.revision = revision
        self.items = records.map(ActionActivityItem.init)
        self.evictedCount = evictedCount
        dismissed.formIntersection(Set(records.map(\.id)))
        observationUnavailable = false
    }
    public func dismiss(_ id: UUID) {
        guard items.contains(where: { $0.id == id && !$0.isActive }) else { return }
        dismissed.insert(id)
    }
    public func summaries(at now: Date) -> [ActionChannelSummary] {
        let channels = Dictionary(grouping: items, by: \.channel)
        return channels.values.compactMap { group in
            let active = group.filter(\.isActive)
            let running = active.filter { $0.execution.phase != .queued }
            let queued = active.filter { $0.execution.phase == .queued }
            let representative: ActionActivityItem?
            if !running.isEmpty {
                representative = running.first { $0.execution.phase == .cancelling } ?? running.first
            } else if !queued.isEmpty {
                representative = queued.first
            } else {
                // Pick the newest admitted execution before filtering visibility; old failures never reappear.
                representative = group.last
            }
            guard let item = representative, !dismissed.contains(item.id) else { return nil }
            if !item.isActive && !item.isFailure {
                guard let end = item.execution.endedAt, now.timeIntervalSince(end) < 3 else { return nil }
            }
            return ActionChannelSummary(
                item: item, additionalRunning: max(0, running.count - 1),
                queued: max(0, queued.count - (item.execution.phase == .queued ? 1 : 0)))
        }.sorted {
            if $0.item.isActive != $1.item.isActive { return $0.item.isActive }
            return $0.item.execution.admittedAt < $1.item.execution.admittedAt
        }
    }
}

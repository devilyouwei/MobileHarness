import AgentCore
import Foundation
import Observation

public struct ActionActivityItem: Identifiable, Equatable, Sendable {
    public let execution: ActionExecutionRecord
    public var title: String { execution.displayName }
    public var channelTitle: String { execution.channel }
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
        case .failed: execution.failureDescription ?? "执行未完成"
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

import AgentCore
import Foundation
import Observation

public struct ActionActivityItem: Identifiable, Equatable, Sendable {
    public let execution: ActionExecutionRecord
    public let title: String
    public let channelTitle: String
    public let status: String
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
    public init(execution: ActionExecutionRecord, title: String, channelTitle: String, status: String) {
        self.execution = execution
        self.title = title
        self.channelTitle = channelTitle
        self.status = status
    }
}

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
    public func replace(revision: UInt64, items: [ActionActivityItem], evictedCount: UInt64) {
        guard self.revision == nil || revision > self.revision! else { return }
        self.revision = revision
        self.items = items
        self.evictedCount = evictedCount
        dismissed.formIntersection(Set(items.map(\.id)))
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

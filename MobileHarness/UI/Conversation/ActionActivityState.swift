import Foundation
import Observation

/// UI-owned values. The host maps execution results into these display fields.
public struct ActionActivityItem: Identifiable, Equatable, Sendable {
    public struct Execution: Equatable, Sendable {
        public enum Phase: String, Sendable { case queued, running, cancelling, succeeded, failed, cancelled }
        public let phase: Phase
        public let admittedAt: Date
        public let startedAt: Date?
        public let endedAt: Date?
        public init(phase: Phase, admittedAt: Date, startedAt: Date?, endedAt: Date?) {
            self.phase = phase
            self.admittedAt = admittedAt
            self.startedAt = startedAt
            self.endedAt = endedAt
        }
    }
    public let id: UUID
    public let title: String
    public let channel: String
    public var channelTitle: String { channel }
    public let status: String
    public let issueDescriptions: [String]
    public let symbol: String
    public let execution: Execution
    public var isActive: Bool { [.queued, .running, .cancelling].contains(execution.phase) }
    public var isFailure: Bool { execution.phase == .failed }
    public init(
        id: UUID, title: String, channel: String, status: String, issueDescriptions: [String], symbol: String,
        execution: Execution
    ) {
        self.id = id
        self.title = title
        self.channel = channel
        self.status = status
        self.issueDescriptions = issueDescriptions
        self.symbol = symbol
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
    public func replace(revision: UInt64, records: [ActionActivityItem], evictedCount: UInt64) {
        guard self.revision == nil || revision > self.revision! else { return }
        self.revision = revision
        self.items = records
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

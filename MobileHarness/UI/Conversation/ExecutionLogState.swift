import Foundation

/// Passive log projections. Neither observation nor filtering drives Agent execution.
public enum ExecutionLogTab: String, CaseIterable, Sendable {
    case action = "Action"
    case task = "Task"
    case agent = "Agent"
}
public enum ExecutionLogFilter: String, CaseIterable, Sendable {
    case all = "全部"
    case active = "进行中"
    case succeeded = "成功"
    case failed = "异常"
}
public struct TaskLogEvent: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let time: Date
    public let title: String
    public let detail: String
    public init(id: UUID, time: Date, title: String, detail: String) {
        self.id = id
        self.time = time
        self.title = title
        self.detail = String(detail.prefix(256))
    }
}
public struct TaskLogItem: Identifiable, Equatable, Sendable {
    public enum Phase: String, Sendable {
        case requested = "委派中"
        case accepted = "已接纳"
        case running = "进行中"
        case waitingUser = "等待用户"
        case cancelling = "取消请求已接纳"
        case succeeded = "已完成"
        case failed = "失败"
        case cancelled = "已取消"
    }
    public let id: UUID
    public let parentID: UUID?
    public let requester: String
    public let executor: String
    public var title: String
    public var phase: Phase
    public var execution: String?
    public var mode: String?
    public var skills: [String] = []
    public var failure: String?
    public var events: [TaskLogEvent]
    public var evictedEvents: Int
    public var isTerminal: Bool { [.succeeded, .failed, .cancelled].contains(phase) }
    public init(
        id: UUID, parentID: UUID?, requester: String, executor: String, title: String, phase: Phase,
        events: [TaskLogEvent] = [], evictedEvents: Int = 0
    ) {
        self.id = id
        self.parentID = parentID
        self.requester = requester
        self.executor = executor
        self.title = String(title.prefix(256))
        self.phase = phase
        self.events = events
        self.evictedEvents = evictedEvents
    }
}
public struct AgentRuntimeLogItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let source: String
    public let status: String
    public let isFailure: Bool
    public let time: Date
    public init(id: UUID = UUID(), source: String, status: String, isFailure: Bool, time: Date = .now) {
        self.id = id
        self.source = source
        self.status = status
        self.isFailure = isFailure
        self.time = time
    }
}

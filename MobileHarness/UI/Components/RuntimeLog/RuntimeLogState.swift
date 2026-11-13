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
    public let source: String
    public let inputID: String?
    public let isInternal: Bool
    public let id: String
    public let title: String
    public let channel: String
    public let status: String
    public let parameters: [String: String]
    public let output: String?
    public let issueDescriptions: [String]
    public let execution: Execution
    public var isActive: Bool { [.queued, .running, .cancelling].contains(execution.phase) }
    public var isFailure: Bool { execution.phase == .failed }
    public init(
        id: String, title: String, channel: String, status: String, issueDescriptions: [String],
        execution: Execution, source: String = "", inputID: String? = nil, isInternal: Bool = false,
        parameters: [String: String] = [:], output: String? = nil
    ) {
        self.source = source
        self.inputID = inputID
        self.isInternal = isInternal
        self.id = id
        self.title = title
        self.channel = channel
        self.status = status
        self.parameters = parameters
        self.output = output
        self.issueDescriptions = issueDescriptions
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
@MainActor
@Observable
public final class RuntimeLogState: RuntimeLogWriting {
    @ObservationIgnored var presentationAdmission: UIPresentationAdmission?

    public internal(set) var showsExecutionHistory = false
    public internal(set) var selectedTab: ExecutionLogTab = .action
    public internal(set) var selectedTaskID: String?
    public private(set) var agentEvents: [AgentRuntimeLogItem] = []
    public private(set) var agentEventEvictions: UInt64 = 0
    public internal(set) var selectedSource = "全部"
    public internal(set) var selectedChannel: String?
    public internal(set) var selectedFilter: ExecutionLogFilter = .all
    public internal(set) var showsInternalActions = false
    public private(set) var tasks: [TaskLogItem] = []
    public private(set) var taskEvictions: UInt64 = 0
    public private(set) var items: [ActionActivityItem] = []
    public private(set) var revision: UInt64?
    public private(set) var evictedCount: UInt64 = 0
    public internal(set) var observationUnavailable = false
    public private(set) var issues: [ExecutionIssue] = []
    public private(set) var issueEvictions: UInt64 = 0
    public private(set) var decisions: [DecisionLogItem] = []
    public private(set) var decisionEvictions: UInt64 = 0

    private func recordIssue(_ issue: ExecutionIssue) {
        if let index = issues.firstIndex(where: { $0.id == issue.id }) {
            issues[index] = issue
            return
        }
        if issues.count == 100 {
            issues.removeFirst()
            issueEvictions &+= 1
        }
        issues.append(issue)
    }

    private func recordDecision(_ decision: DecisionLogItem) {
        guard !decisions.contains(where: { $0.id == decision.id }) else { return }
        if decisions.count == 100 {
            decisions.removeFirst()
            decisionEvictions &+= 1
        }
        decisions.append(decision)
    }

    public var hasRecords: Bool {
        !items.isEmpty || !tasks.isEmpty || !agentEvents.isEmpty || !issues.isEmpty || !decisions.isEmpty
    }
    public var sources: [String] {
        Array(
            Set(
                items.map(\.source) + tasks.flatMap { [$0.requester, $0.executor] } + runtimeIssues.map(\.source)
                    + agentEvents.map(\.source) + decisions.map(\.source))
        ).filter { !$0.isEmpty }.sorted()
    }
    public func matchesSource(_ values: [String]) -> Bool { selectedSource == "全部" || values.contains(selectedSource) }
    public func matchesStatus(active: Bool, success: Bool, failure: Bool) -> Bool {
        switch selectedFilter {
        case .all: true
        case .active: active
        case .succeeded: success
        case .failed: failure
        }
    }
    public var actionChannels: [String] { Set(items.map(\.channel)).sorted() }

    public var visibleActions: [ActionActivityItem] {
        items.filter { item in
            (selectedTaskID == nil
                || tasks.contains { task in task.id == selectedTaskID && task.events.contains { $0.id == item.inputID }
                })
                && (selectedChannel == nil || selectedChannel == item.channel)
                && (showsInternalActions || !item.isInternal || item.isFailure) && matchesSource([item.source])
                && matchesStatus(
                    active: item.isActive, success: item.execution.phase == .succeeded, failure: item.isFailure)
        }
    }
    public var visibleTasks: [TaskLogItem] {
        tasks.filter {
            matchesSource([$0.requester, $0.executor])
                && matchesStatus(active: !$0.isTerminal, success: $0.phase == .succeeded, failure: $0.phase == .failed)
        }
    }
    public var visibleDecisions: [DecisionLogItem] {
        decisions.reversed().filter {
            matchesSource([$0.source])
                && matchesStatus(active: false, success: $0.modelResult != nil, failure: $0.modelResult == nil)
        }.sorted { $0.time > $1.time }
    }

    public var runtimeIssues: [ExecutionIssue] {
        var seen: Set<String> = []
        return issues.sorted { $0.time > $1.time }.filter { issue in
            let linked =
                items.contains { item in
                    issue.inputID != nil && item.inputID == issue.inputID && item.isFailure
                        && item.issueDescriptions.contains { !$0.isEmpty && issue.message.contains($0) }
                }
            return !linked
                && seen.insert("\(issue.source)|\(issue.inputID ?? issue.id)|\(issue.message)")
                    .inserted
        }
    }
    func recordAgentEvent(_ event: AgentRuntimeLogItem) {
        if agentEvents.count == 100 {
            agentEvents.removeFirst()
            agentEventEvictions &+= 1
        }
        agentEvents.append(event)
    }
    func updateTask(_ incoming: TaskLogItem, event: TaskLogEvent) {
        if let index = tasks.firstIndex(where: { $0.id == incoming.id }) {
            if let existing = tasks[index].events.firstIndex(where: { $0.id == event.id }) {
                tasks[index].events[existing] = event
            } else {
                if tasks[index].events.count == 32 {
                    tasks[index].events.removeFirst()
                    tasks[index].evictedEvents += 1
                }
                tasks[index].events.append(event)
            }
            tasks[index].execution = incoming.execution ?? tasks[index].execution
            tasks[index].mode = incoming.mode
            if !incoming.skills.isEmpty { tasks[index].skills = incoming.skills }
            tasks[index].failure = incoming.failure
            if !tasks[index].isTerminal { tasks[index].phase = incoming.phase }
            if tasks[index].title.isEmpty { tasks[index].title = incoming.title }
        } else {
            if tasks.count == 100 {
                let retired = tasks.firstIndex(where: { $0.isTerminal }) ?? 0
                tasks.remove(at: retired)
                taskEvictions &+= 1
            }
            var value = incoming
            value.events = [event]
            tasks.append(value)
        }
    }

    private var dismissed: Set<String> = []

    public init() {}
    func replace(revision: UInt64, records: [ActionActivityItem], evictedCount: UInt64) {
        guard self.revision == nil || revision > self.revision! else { return }
        self.revision = revision
        self.items = records
        if let selectedChannel, !records.contains(where: { $0.channel == selectedChannel }) {
            self.selectedChannel = nil
        }
        self.evictedCount = evictedCount
        dismissed.formIntersection(Set(records.map(\.id)))
    }
    public func dismiss(_ id: String) {
        guard items.contains(where: { $0.id == id && !$0.isActive }) else { return }
        dismissed.insert(id)
    }
    public func summaries(at now: Date) -> [ActionChannelSummary] {
        let channels = Dictionary(
            grouping: items.filter { showsInternalActions || !$0.isInternal || $0.isFailure }, by: \.channel)
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

    @discardableResult
    public func record(_ event: RuntimeLogEvent) -> Bool {
        guard presentationAdmission?.acceptsRetained() ?? true else { return false }
        switch event {
        case .agent(let event): recordAgentEvent(event)
        case .task(let task, let event): updateTask(task, event: event)
        case .actions(let revision, let records, let evictedCount):
            replace(revision: revision, records: records, evictedCount: evictedCount)
        case .decision(let decision): recordDecision(decision)
        case .issue(let issue): recordIssue(issue)
        case .observationUnavailable: observationUnavailable = true
        }
        return true
    }
}

@MainActor
public protocol RuntimeLogWriting: Sendable {
    @discardableResult
    func record(_ event: RuntimeLogEvent) -> Bool
}

public enum RuntimeLogEvent: Sendable {
    case agent(AgentRuntimeLogItem)
    case task(TaskLogItem, TaskLogEvent)
    case actions(revision: UInt64, records: [ActionActivityItem], evictedCount: UInt64)
    case decision(DecisionLogItem)
    case issue(ExecutionIssue)
    case observationUnavailable
}

public struct DecisionLogItem: Identifiable, Sendable, Equatable {
    public enum Route: String, Sendable {
        case local = "本地 D3"
        case cloud = "云端 Decision"
        case fallback = "回退"
    }
    public enum Disposition: String, Sendable {
        case enqueue, discard, interrupt
    }
    public let id: String
    public let source: String
    public let inputText: String
    public let time: Date
    public let duration: Duration
    public let route: Route
    public let modelResult: Disposition?
    public let adoptedResult: Disposition
    public let reason: String?
    public let requests: [String]
    public let localFallback: String?

    public init(
        id: String, source: String, inputText: String, time: Date = .now, duration: Duration, route: Route,
        modelResult: Disposition?,
        adoptedResult: Disposition, reason: String? = nil, requests: [String], localFallback: String? = nil
    ) {
        self.id = id
        self.source = String(source.prefix(64))
        self.inputText = inputText
        self.time = time
        self.duration = duration
        self.route = route
        self.modelResult = modelResult
        self.adoptedResult = adoptedResult
        self.reason = reason.map { String($0.prefix(256)) }
        self.requests = requests
        self.localFallback = localFallback.map { String($0.prefix(256)) }
    }
}

/// Passive log projections. Neither observation nor filtering drives Agent execution.
public enum ExecutionLogTab: String, CaseIterable, Sendable {
    case action = "Action"
    case task = "Task"
    case agent = "Agent"
    case decision = "Decision"
}
public enum ExecutionLogFilter: String, CaseIterable, Sendable {
    case all = "全部"
    case active = "进行中"
    case succeeded = "成功"
    case failed = "异常"
}
public struct TaskLogEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public let time: Date
    public let title: String
    public let detail: String
    public init(id: String, time: Date, title: String, detail: String) {
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
    public let id: String
    public let parentID: String?
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
        id: String, parentID: String?, requester: String, executor: String, title: String, phase: Phase,
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
    public let id: String
    public let source: String
    public let status: String
    public let isFailure: Bool
    public let time: Date
    public init(
        id: String = UUID().uuidString, source: String, status: String, isFailure: Bool, time: Date = .now
    ) {
        self.id = id
        self.source = source
        self.status = status
        self.isFailure = isFailure
        self.time = time
    }
}

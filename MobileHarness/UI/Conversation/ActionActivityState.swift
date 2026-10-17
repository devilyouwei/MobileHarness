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
    public var channelTitle: String { channel }
    public let status: String
    public let issueDescriptions: [String]
    public let symbol: String
    public let execution: Execution
    public var isActive: Bool { [.queued, .running, .cancelling].contains(execution.phase) }
    public var isFailure: Bool { execution.phase == .failed }
    public init(
        id: String, title: String, channel: String, status: String, issueDescriptions: [String], symbol: String,
        execution: Execution, source: String = "", inputID: String? = nil, isInternal: Bool = false
    ) {
        self.source = source
        self.inputID = inputID
        self.isInternal = isInternal
        self.id = id
        self.title = title
        self.channel = channel
        self.status = status
        self.issueDescriptions = issueDescriptions
        self.symbol = symbol
        self.execution = execution
    }
}

/// Display-only execution issue; no device state or SDK fault classification.
public struct ExecutionIssue: Identifiable, Sendable, Equatable {
    public struct Context: Sendable, Equatable {
        public let workerID: String
        public let sessionID: String?
        public let inputID: String?
        public let callID: String?
        public let roundID: String?
        public init(
            workerID: String, sessionID: String? = nil, inputID: String? = nil, callID: String? = nil,
            roundID: String? = nil
        ) {
            self.workerID = workerID
            self.sessionID = sessionID
            self.inputID = inputID
            self.callID = callID
            self.roundID = roundID
        }
    }
    public let inputID: String?
    public let context: Context?
    public let failureCode: String?
    public let id: String
    public let title: String
    public let source: String
    public let message: String
    public let userMessage: String?
    public let category: String?
    public let time: Date
    public init(
        id: String = UUID().uuidString, title: String, source: String, message: String, time: Date = Date(),
        failureCode: String? = nil, context: Context? = nil, inputID: String? = nil, userMessage: String? = nil,
        category: String? = nil
    ) {
        self.inputID = inputID ?? context?.inputID
        self.id = id
        self.title = String(title.prefix(128))
        self.source = String(source.prefix(64))
        self.category = category.map { String($0.prefix(64)) }
        self.message = String(message.prefix(category == nil ? 512 : 2048))
        self.userMessage = userMessage.map { String($0.prefix(512)) }
        precondition(failureCode.map { !$0.isEmpty && $0.utf8.count <= 64 } ?? true)
        self.failureCode = failureCode
        self.context = context
        self.time = time
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
    public var currentTaskID: String?
    public var skillOwnership: [String: String] = [:]
    public var backgroundTaskCount: Int { tasks.filter { $0.execution == "background" && !$0.isTerminal }.count }
    public var currentTaskTitle = ""
    public var currentTaskStatus = ""
    public var loadedSkills: [String] = []
    public var showsExecutionHistory = false
    public var selectedTab: ExecutionLogTab = .action
    public var selectedTaskID: String?
    public private(set) var agentEvents: [AgentRuntimeLogItem] = []
    public private(set) var agentEventEvictions: UInt64 = 0
    public var selectedSource = "全部"
    public var selectedFilter: ExecutionLogFilter = .all
    public var showsInternalActions = false
    public private(set) var tasks: [TaskLogItem] = []
    public private(set) var taskEvictions: UInt64 = 0
    public private(set) var items: [ActionActivityItem] = []
    public private(set) var revision: UInt64?
    public private(set) var evictedCount: UInt64 = 0
    public var observationUnavailable = false
    public var notice: HomeNotice?
    public var visibleNotice: HomeNotice? {
        if let errorToast {
            return HomeNotice(
                id: errorToast.id,
                text: errorToast.userMessage ?? errorToast.message.replacingOccurrences(of: "agent.error: ", with: ""),
                tone: .error)
        }
        return notice
    }
    public private(set) var errorToast: ExecutionIssue?
    private var toastKeys: [String] = []
    public func dismissErrorToast(id: String) { if errorToast?.id == id { errorToast = nil } }
    private func offerToast(_ issue: ExecutionIssue, now: Date = Date()) {
        // Initial/repeated retained snapshots do not replay old failures as new incidents.
        guard issue.context?.callID == nil, now.timeIntervalSince(issue.time) <= 15 else { return }
        let key = "\(issue.source)|\(issue.inputID ?? issue.id)|\(issue.message)"
        guard !toastKeys.contains(key) else { return }
        toastKeys.append(key)
        toastKeys = Array(toastKeys.suffix(100))
        errorToast = issue
    }
    public private(set) var outputIssues: [ExecutionIssue] = []
    public private(set) var backgroundIssues: [ExecutionIssue] = []
    private var outputEvictions: UInt64 = 0
    private var backgroundEvictions: UInt64 = 0
    public var issueEvictions: UInt64 { outputEvictions + backgroundEvictions }
    private var issueRevision: UInt64?
    public func replaceIssues(revision: UInt64, records: [ExecutionIssue], evictedCount: UInt64) {
        guard issueRevision == nil || revision > issueRevision! else { return }
        issueRevision = revision
        let previous = Set(outputIssues.map(\.id))
        if let newest = records.filter({ !previous.contains($0.id) && $0.context?.callID == nil }).max(by: {
            $0.time < $1.time
        }) {
            offerToast(newest)
        }
        outputIssues = Array(records.suffix(100))
        outputEvictions = evictedCount
    }
    public func recordIssue(_ issue: ExecutionIssue) {
        offerToast(issue)
        if backgroundIssues.count == 100 {
            backgroundIssues.removeFirst()
            backgroundEvictions &+= 1
        }
        backgroundIssues.append(issue)
    }
    public var hasRecords: Bool {
        !items.isEmpty || !tasks.isEmpty || !agentEvents.isEmpty || !outputIssues.isEmpty
            || !backgroundIssues.isEmpty
    }
    public var sources: [String] {
        Array(
            Set(
                items.map(\.source) + tasks.flatMap { [$0.requester, $0.executor] } + runtimeIssues.map(\.source)
                    + agentEvents.map(\.source))
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
    public var visibleActions: [ActionActivityItem] {
        items.filter { item in
            (selectedTaskID == nil
                || tasks.contains { task in task.id == selectedTaskID && task.events.contains { $0.id == item.inputID }
                })
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
    public var runtimeIssues: [ExecutionIssue] {
        var seen: Set<String> = []
        return (outputIssues + backgroundIssues).sorted { $0.time > $1.time }.filter { issue in
            let linked =
                items.contains { item in
                    item.inputID == issue.inputID && item.isFailure
                        && item.issueDescriptions.contains { !$0.isEmpty && issue.message.contains($0) }
                }
            return !linked
                && seen.insert("\(issue.source)|\(issue.inputID ?? issue.id)|\(issue.message)")
                    .inserted
        }
    }
    public func recordAgentEvent(_ event: AgentRuntimeLogItem) {
        if agentEvents.count == 100 {
            agentEvents.removeFirst()
            agentEventEvictions &+= 1
        }
        agentEvents.append(event)
    }
    public func updateTask(_ incoming: TaskLogItem, event: TaskLogEvent) {
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
    public func replace(revision: UInt64, records: [ActionActivityItem], evictedCount: UInt64) {
        guard self.revision == nil || revision > self.revision! else { return }
        self.revision = revision
        self.items = records
        self.evictedCount = evictedCount
        dismissed.formIntersection(Set(records.map(\.id)))
        observationUnavailable = false
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
}

/// A display notice is never an ExecutionIssue or a task goal.
public struct HomeNotice: Sendable, Equatable {
    public enum Tone: String, Sendable { case info, warning, error }
    public let id: String
    public let text: String
    public let tone: Tone
    public init(id: String = UUID().uuidString, text: String, tone: Tone) {
        self.id = id
        self.text = text
        self.tone = tone
    }
}

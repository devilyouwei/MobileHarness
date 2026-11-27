import Foundation
import Observation

/// UI-owned values. The host maps execution results into these display fields.
public struct ActionActivityItem: Identifiable, Equatable, Sendable {
    public static let controlChannel = "Control"

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
    public private(set) var agentEvents: [AgentRuntimeLogItem] = []
    public private(set) var agentEventEvictions: UInt64 = 0
    public internal(set) var selectedSource = "All"
    public internal(set) var selectedChannel: String?
    public internal(set) var selectedFilter: ExecutionLogFilter = .all
    public internal(set) var showsInternalActions = false
    private var actionRecords: [ActionActivityItem] = []
    private var controlRecords: [ActionActivityItem] = []
    public var items: [ActionActivityItem] {
        guard !controlRecords.isEmpty else { return actionRecords }
        return (actionRecords + controlRecords).sorted { $0.execution.admittedAt < $1.execution.admittedAt }
    }
    public private(set) var revision: UInt64?
    private var actionEvictions: UInt64 = 0
    private var controlEvictions: UInt64 = 0
    public var evictedCount: UInt64 { actionEvictions &+ controlEvictions }
    public internal(set) var observationUnavailable = false
    public private(set) var issues: [ExecutionIssue] = []
    public private(set) var issueEvictions: UInt64 = 0
    public private(set) var decisions: [DecisionLogItem] = []
    public private(set) var decisionEvictions: UInt64 = 0
    public private(set) var stateVariables: [StateVariableItem] = []
    @ObservationIgnored private var stateSource: (@MainActor @Sendable () async -> [StateVariableItem])?
    @ObservationIgnored private var observedValues: [String: String?] = [:]
    @ObservationIgnored private var observedChanges: [String: Date] = [:]

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
        !actionRecords.isEmpty || !controlRecords.isEmpty || !agentEvents.isEmpty || !issues.isEmpty
            || !decisions.isEmpty
    }
    public var sources: [String] {
        Array(
            Set(
                items.map(\.source) + runtimeIssues.map(\.source)
                    + agentEvents.map(\.source) + decisions.map(\.source))
        ).filter { !$0.isEmpty }.sorted()
    }
    public func matchesSource(_ values: [String]) -> Bool { selectedSource == "All" || values.contains(selectedSource) }
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
            (selectedChannel == nil || selectedChannel == item.channel)
                && (showsInternalActions || !item.isInternal || item.isFailure) && matchesSource([item.source])
                && matchesStatus(
                    active: item.isActive, success: item.execution.phase == .succeeded, failure: item.isFailure)
        }
    }
    public func provideStateVariables(_ source: @escaping @MainActor @Sendable () async -> [StateVariableItem]) {
        stateSource = source
    }

    /// Reads the current variables. Values without a write time get the moment the display first saw them change.
    public func refreshStateVariables(now: Date = .now) async {
        guard let stateSource else { return }
        let items = await stateSource()
        for item in items {
            if let previous = observedValues[item.path], previous != item.value { observedChanges[item.path] = now }
            observedValues[item.path] = .some(item.value)
        }
        observedValues = observedValues.filter { key, _ in items.contains { $0.path == key } }
        observedChanges = observedChanges.filter { key, _ in items.contains { $0.path == key } }
        let changedAt: (StateVariableItem) -> Date = { $0.writtenAt ?? self.observedChanges[$0.path] ?? .distantPast }
        stateVariables = items.sorted {
            if ($0.value == nil) != ($1.value == nil) { return $0.value != nil }
            if $0.value != nil, changedAt($0) != changedAt($1) { return changedAt($0) > changedAt($1) }
            return $0.path < $1.path
        }
    }

    public var visibleDecisions: [DecisionLogItem] {
        decisions.reversed().filter {
            matchesSource([$0.source])
                && matchesStatus(
                    active: false, success: $0.isSuccess,
                    failure: $0.isFailure)
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
    private var dismissed: Set<String> = []

    public init() {}
    func replace(revision: UInt64, records: [ActionActivityItem], evictedCount: UInt64) {
        guard self.revision == nil || revision > self.revision! else { return }
        self.revision = revision
        actionRecords = records
        if let selectedChannel, !actionChannels.contains(selectedChannel) {
            self.selectedChannel = nil
        }
        actionEvictions = evictedCount
        dismissed.formIntersection(Set(records.map(\.id)))
    }

    private func recordControl(_ item: ActionActivityItem) {
        guard !controlRecords.contains(where: { $0.id == item.id }) else { return }
        if controlRecords.count == 100 {
            controlRecords.removeFirst()
            controlEvictions &+= 1
        }
        controlRecords.append(item)
    }

    public func dismiss(_ id: String) {
        guard actionRecords.contains(where: { $0.id == id && !$0.isActive }) else { return }
        dismissed.insert(id)
    }
    public func summaries(at now: Date) -> [ActionChannelSummary] {
        let channels = Dictionary(
            grouping: actionRecords.filter { showsInternalActions || !$0.isInternal || $0.isFailure }, by: \.channel)
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
        case .actions(let revision, let records, let evictedCount):
            replace(revision: revision, records: records, evictedCount: evictedCount)
        case .agentControl(let record): recordControl(record)
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
    /// Supplies the read-only view of the variables an Agent currently loads into its prompt.
    func provideStateVariables(_ source: @escaping @MainActor @Sendable () async -> [StateVariableItem])
}

extension RuntimeLogWriting {
    public func provideStateVariables(_ source: @escaping @MainActor @Sendable () async -> [StateVariableItem]) {}
}

/// One variable an Agent currently loads into its prompt, as a read-only display value.
public struct StateVariableItem: Identifiable, Sendable, Equatable {
    public enum Category: String, Sendable {
        case readOnly = "Read-only"
        case readWrite = "Read-write"
        case semantic = "Semantic"
        case container = "Container"
        case image = "Image"
    }
    public let path: String
    public let category: Category
    /// `nil` means the variable currently has no value.
    public let value: String?
    /// Only variables the Agent owns record a write time.
    public let writtenAt: Date?
    public var id: String { path }
    public var isAgentOwned: Bool { [.readOnly, .readWrite, .semantic].contains(category) }
    public init(path: String, category: Category, value: String?, writtenAt: Date? = nil) {
        self.path = path
        self.category = category
        self.value = value.flatMap { $0.isEmpty ? nil : String($0.prefix(4096)) }
        self.writtenAt = writtenAt
    }
}

public enum RuntimeLogEvent: Sendable {
    case agent(AgentRuntimeLogItem)
    case actions(revision: UInt64, records: [ActionActivityItem], evictedCount: UInt64)
    case agentControl(ActionActivityItem)
    case decision(DecisionLogItem)
    case issue(ExecutionIssue)
    case observationUnavailable
}

public struct DecisionLogItem: Identifiable, Sendable, Equatable {
    public enum Route: String, Sendable {
        case local = "Local"
        case cloud = "Cloud Decision"
        case keyword = "Keyword interrupt"
        case fallback = "Fallback"
        case failed = "Failed"
        case superseded = "Superseded Decision"
    }
    public enum Disposition: String, Sendable {
        case enqueue, discard, interrupt
        case continueListening = "continue_listening"
    }
    public let id: String
    public let source: String
    public let inputText: String
    public let time: Date
    public let duration: Duration
    public let route: Route
    public let modelName: String?
    public let modelID: String?
    public let inferenceDuration: Duration?
    public let modelResult: Disposition?
    public let adoptedResult: Disposition
    public let booleanResult: Bool?
    public let signalStatus: String?
    public let reason: String?
    public let requests: [String]
    public var isSuccess: Bool {
        if route == .keyword { return signalStatus == "interrupted" }
        return booleanResult != nil || modelResult != nil
    }
    public var isFailure: Bool {
        if route == .keyword { return signalStatus == "interrupt_failed" }
        return !isSuccess && route != .superseded
    }

    public init(
        id: String, source: String, inputText: String, time: Date = .now, duration: Duration, route: Route,
        modelResult: Disposition?,
        adoptedResult: Disposition, booleanResult: Bool? = nil, signalStatus: String? = nil, reason: String? = nil,
        requests: [String], modelName: String? = nil, modelID: String? = nil, inferenceDuration: Duration? = nil
    ) {
        self.id = id
        self.source = String(source.prefix(64))
        self.inputText = inputText
        self.time = time
        self.duration = duration
        self.route = route
        self.modelName = modelName
        self.modelID = modelID
        self.inferenceDuration = inferenceDuration
        self.modelResult = modelResult
        self.booleanResult = booleanResult
        self.signalStatus = signalStatus
        self.adoptedResult = adoptedResult
        self.reason = reason.map { String($0.prefix(256)) }
        self.requests = requests
    }
}

/// Passive log projections. Neither observation nor filtering drives Agent execution.
public enum ExecutionLogTab: String, CaseIterable, Sendable {
    case action = "Action"
    case agent = "Agent"
    case decision = "Decision"
    case state = "State"
}
public enum ExecutionLogFilter: String, CaseIterable, Sendable {
    case all = "All"
    case active = "In progress"
    case succeeded = "Succeeded"
    case failed = "Failed"
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

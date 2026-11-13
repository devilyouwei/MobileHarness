import AgentCore
import Foundation
import StorageCore

/// Runtime Task/Skill state; executable code is never loaded from assets.
public struct AgentTaskSkillState: Codable, Sendable {
    public struct TaskRecord: Codable, Sendable, Identifiable {
        public let id: String
        public let mode: String
        public let goal: String
        public let date: Date
        public var status: String
        public var summary: String?
        public var continueDecision: Bool?
        public var sessionID: String? = nil
        public var failure: String? = nil
        public var updatedAt: Date? = nil
        public var inputIDs: [String]
        public var skills: [String]
    }
    public struct Event: Codable, Sendable {
        public let date: Date
        public let operation: String
        public let skill: String
        public let revision: Int
        public let taskID: String?
        public var reason: String? = nil
    }
    public struct Retention: Codable, Sendable {
        public var remainingDecisions: Int
        public var lastUsed: UInt64
        public var sessionID: String? = nil
    }
    public struct DecisionUsage: Codable, Sendable {
        public let sessionID: String?
        public let countsIdle: Bool
        public var observedTask: Bool
        public var roots: Set<String> = []
    }
    public struct Policy: Codable, Sendable {
        public var idleDecisions = 5
        public var maximumNonBaseSkills = 3
        public var maximumNonBaseBytes = 24 * 1024
        public init() {}
    }
    public var version = 4
    public var policy = Policy()
    public private(set) var recentSkills: [String: Retention] = [:]
    public private(set) var taskSkillRoots: Set<String> = []
    public private(set) var decisions: [String: DecisionUsage] = [:]
    private var useOrder: UInt64 = 0
    public var baseSkillIDs: [String]?
    public var loaded: [String] = []
    public var mode: String { activeTaskID == nil ? "default" : "task" }
    public var activeTaskID: String?
    public var tasks: [TaskRecord] = []
    public var events: [Event] = []
    public var inputBindings: [String: String] = [:]
    public init() {}

    public func taskID(for input: String) -> String? {
        inputBindings[input] ?? tasks.first(where: { $0.inputIDs.contains(input) })?.id
    }
    public mutating func bind(_ input: String, task: String?) throws {
        guard let task else { return }
        guard
            let index = tasks.firstIndex(where: {
                $0.id == task && !["completed", "cancelled", "failed", "interrupted"].contains($0.status)
            })
        else {
            throw CommunicationError.scopeClosed
        }
        if !tasks[index].inputIDs.contains(input) {
            guard tasks[index].inputIDs.count < 256 else { throw CommunicationError.capacityExceeded }
            tasks[index].inputIDs.append(input)
        }
        inputBindings[input] = task
        if inputBindings.count > 256 {
            let retained = Set(tasks.filter { $0.id == activeTaskID }.flatMap(\.inputIDs))
            for key in inputBindings.keys where !retained.contains(key) { inputBindings[key] = nil }
        }
        if tasks[index].status == "waitingUser" { tasks[index].status = "running" }
        tasks[index].updatedAt = Date()
    }
    public mutating func initialize(fixed fixedCapabilities: CapabilityRegistry, baseSkills: [String]) throws {
        guard version == 4 else { throw CommunicationError.invalidPayload }
        baseSkillIDs = baseSkills
        if loaded.isEmpty { loaded = try base(fixed: fixedCapabilities) }
        _ = try registry(fixed: fixedCapabilities)
    }
    private func base(fixed fixedCapabilities: CapabilityRegistry) throws -> [String] {
        guard let baseSkillIDs else { throw CommunicationError.invalidPayload }
        let ids = try AgentSkillLoader.expand(baseSkillIDs)
        _ = try AgentSkillLoader.registry(ids, fixed: fixedCapabilities)
        return ids
    }
    public func registry(fixed fixedCapabilities: CapabilityRegistry) throws -> CapabilityRegistry {
        try AgentSkillLoader.registry(loaded, fixed: fixedCapabilities)
    }
    public func ownership(_ id: String) throws -> String {
        if try AgentSkillLoader.expand(baseSkillIDs ?? []).contains(id) { return "base" }
        if try AgentSkillLoader.expand(taskSkillRoots.sorted()).contains(id) { return "task" }
        return "recent"
    }
    /// One original user input, shared by all its internal ReACT requests.
    public mutating func beginDecision(_ inputID: String, sessionID: String? = nil, countsIdle: Bool = true) throws {
        if decisions[inputID] != nil { return }
        guard decisions.count < 32 else { throw CommunicationError.capacityExceeded }
        decisions[inputID] = DecisionUsage(
            sessionID: sessionID, countsIdle: countsIdle, observedTask: activeTaskID != nil)
    }

    public mutating func discardDecision(_ inputID: String) {
        decisions[inputID] = nil
    }

    private mutating func touch(_ roots: Set<String>, inputID: String) throws {
        guard !roots.isEmpty else { return }
        guard useOrder < UInt64.max else { throw CommunicationError.capacityExceeded }
        useOrder += 1
        for root in roots {
            if activeTaskID != nil {
                taskSkillRoots.insert(root)
                recentSkills[root] = nil
            } else {
                recentSkills[root] = Retention(
                    remainingDecisions: policy.idleDecisions, lastUsed: useOrder,
                    sessionID: decisions[inputID]?.sessionID ?? recentSkills[root]?.sessionID)
            }
        }
        // Trusted idle controls are not user Decisions and create no pending usage owner.
        if var usage = decisions[inputID] {
            usage.roots.formUnion(roots)
            usage.observedTask = usage.observedTask || activeTaskID != nil
            decisions[inputID] = usage
        }
    }

    /// Called only for an admitted model function; parsing/parameter rejections never reach here.
    public mutating func recordUse(path: String, callType: String, inputID: String, snapshotSkills: [String]) throws {
        var next = self
        let roots = Set(recentSkills.keys).union(taskSkillRoots)
        let providers = try Set(
            roots.filter { root in
                try AgentSkillLoader.expand([root]).contains { id in
                    guard snapshotSkills.contains(id) else { return false }
                    return try AgentConfigurations.skill(id).useActions.contains {
                        $0.path == path && $0.callType == callType
                    }
                }
            })
        guard !providers.isEmpty else { return }
        try next.touch(providers, inputID: inputID)
        try next.refreshLoaded()
        try next.updateTaskEvidence()
        self = next
    }

    private mutating func refreshLoaded() throws {
        loaded = try AgentSkillLoader.expand(
            (baseSkillIDs ?? []) + taskSkillRoots.sorted() + recentSkills.keys.sorted())
    }

    private mutating func fitBudget(fixed: CapabilityRegistry, requested: Set<String>) throws {
        guard policy.idleDecisions > 0, policy.maximumNonBaseSkills > 0, policy.maximumNonBaseBytes > 0 else {
            throw CommunicationError.invalidPayload
        }
        let base = try base(fixed: fixed)
        let protected = decisions.values.reduce(taskSkillRoots.union(requested)) { $0.union($1.roots) }
        try refreshLoaded()
        while try loaded.filter({ !base.contains($0) }).count > policy.maximumNonBaseSkills
            || AgentSkillLoader.nonBaseBytes(loaded, base: base) > policy.maximumNonBaseBytes
        {
            guard
                let victim = recentSkills.keys.filter({ !protected.contains($0) }).sorted(by: {
                    let lhs = recentSkills[$0]?.lastUsed ?? 0
                    let rhs = recentSkills[$1]?.lastUsed ?? 0
                    return lhs == rhs ? $0 < $1 : lhs < rhs
                }).first
            else { throw CommunicationError.capacityExceeded }
            recentSkills[victim] = nil
            try refreshLoaded()
        }
        _ = try registry(fixed: fixed)
    }

    private mutating func updateTaskEvidence() throws {
        guard let id = activeTaskID, let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let owned = try AgentSkillLoader.expand((baseSkillIDs ?? []) + taskSkillRoots.sorted())
        tasks[index].skills = Array(Set(tasks[index].skills).union(owned)).sorted()
        tasks[index].updatedAt = Date()
    }

    public mutating func control(
        _ operation: String, arguments: [String: String], inputID: String,
        fixed fixedCapabilities: CapabilityRegistry,
        sessionID: String? = nil, taskID: String? = nil
    ) throws -> String {
        let allowed: Set<String>
        let required: Set<String>
        switch operation {
        case "task.start":
            allowed = ["description", "skills"]
            required = ["description"]
        case "loadSkills", "releaseSkills":
            allowed = ["skills"]
            required = allowed
        case "task.end":
            allowed = ["summary", "continueDecision"]
            required = ["summary"]
        default: throw HarnessError.forbiddenFunction
        }
        guard required.isSubset(of: Set(arguments.keys)), Set(arguments.keys).isSubset(of: allowed),
            arguments.values.allSatisfy({
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 4096
            })
        else { throw CommunicationError.invalidPayload }
        if let value = arguments["continueDecision"], !["true", "false"].contains(value) {
            throw CommunicationError.invalidPayload
        }
        var next = self
        let requested = try AgentTaskSkillIDs.decode(arguments["skills"])
        switch operation {
        case "task.start":
            guard activeTaskID == nil, let goal = arguments["description"]
            else { throw CommunicationError.invalidPayload }
            next.taskSkillRoots = Set(requested).subtracting(try base(fixed: fixedCapabilities))
            for root in next.taskSkillRoots { next.recentSkills[root] = nil }
            try next.fitBudget(fixed: fixedCapabilities, requested: next.taskSkillRoots)
            if next.tasks.count == 256 { next.tasks.removeFirst() }
            guard let taskID, BusinessRecordID(rawValue: taskID)?.kind == .task else {
                throw CommunicationError.invalidPayload
            }
            let task = TaskRecord(
                id: taskID, mode: "task", goal: goal, date: Date(), status: "running",
                inputIDs: [], skills: try AgentSkillLoader.expand((baseSkillIDs ?? []) + next.taskSkillRoots.sorted())
            )
            next.tasks.append(task)
            next.tasks[next.tasks.count - 1].sessionID = sessionID
            next.activeTaskID = task.id
            for key in next.decisions.keys { next.decisions[key]?.observedTask = true }
            try next.bind(inputID, task: task.id)
        case "loadSkills":
            let roots = Set(requested).subtracting(try base(fixed: fixedCapabilities))
            try next.touch(roots, inputID: inputID)
            try next.fitBudget(fixed: fixedCapabilities, requested: roots)
        case "releaseSkills":
            let protected = try base(fixed: fixedCapabilities)
            let roots = Set(next.recentSkills.keys).union(next.taskSkillRoots)
            guard requested.allSatisfy({ roots.contains($0) && !protected.contains($0) }) else {
                throw CommunicationError.unauthorized
            }
            for root in requested {
                next.recentSkills[root] = nil
                next.taskSkillRoots.remove(root)
            }
            try next.refreshLoaded()
            // A requested dependency still needed by another root cannot be released.
            guard requested.allSatisfy({ !next.loaded.contains($0) }) else { throw CommunicationError.unauthorized }
        case "task.end":
            guard let id = activeTaskID, let index = next.tasks.firstIndex(where: { $0.id == id }),
                ["running", "waitingUser"].contains(next.tasks[index].status)
            else { throw CommunicationError.scopeClosed }
            next.tasks[index].status = "finishing"
            next.tasks[index].continueDecision = arguments["continueDecision"] == "true"
            next.tasks[index].summary = arguments["summary"]
        default: throw HarnessError.forbiddenFunction
        }
        try next.recordChanges(
            previous: loaded, task: next.activeTaskID,
            releaseReason: operation == "releaseSkills" ? "explicit" : "capacity")
        try next.updateTaskEvidence()
        let beforeLoaded = Set(loaded)
        self = next
        let receipt: [String: Any] = [
            "operation": operation, "status": "committed", "mode": mode,
            "taskID": activeTaskID ?? "none", "skills": loaded,
            "remainingDecisions": recentSkills.mapValues(\.remainingDecisions),
            "taskSkills": taskSkillRoots.sorted(),
            "released": beforeLoaded.subtracting(loaded).sorted(),
        ]
        return String(
            decoding: try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]), as: UTF8.self)
    }

    private mutating func recordChanges(previous: [String], task: String?, releaseReason: String? = nil) throws {
        for id in Set(previous).symmetricDifference(Set(loaded)).sorted() {
            events.append(
                Event(
                    date: Date(), operation: loaded.contains(id) ? "load" : "release",
                    skill: id, revision: try AgentConfigurations.skill(id).revision, taskID: task,
                    reason: loaded.contains(id) ? nil : releaseReason))
        }
        events = Array(events.suffix(256))
    }
    /// Task closure is separate from input settlement: finishTask can continue to another goal.
    public mutating func settleTask(finishRequested: Bool = true, finishedAt: Date = Date()) throws {
        guard let id = activeTaskID, let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        var next = self
        next.tasks[index].updatedAt = finishedAt
        let status = next.tasks[index].status
        if finishRequested && status == "finishing" {
            next.tasks[index].status = "completed"
            for root in next.taskSkillRoots { next.recentSkills[root] = nil }
            next.activeTaskID = nil
            let retired = next.taskSkillRoots
            next.taskSkillRoots = []
            for key in next.decisions.keys { next.decisions[key]?.roots.subtract(retired) }
            try next.refreshLoaded()
            try next.recordChanges(previous: loaded, task: id, releaseReason: "taskEnded")
        } else {
            next.tasks[index].status = "waitingUser"
            if status == "finishing" {
                next.tasks[index].summary = nil
                next.tasks[index].continueDecision = nil
            }
        }
        self = next
    }

    public mutating func decisionCompleted(
        inputID: String? = nil, finishRequested: Bool = true
    ) throws {
        var next = self
        try next.settleTask(finishRequested: finishRequested)
        let beforeIdle = next.loaded
        if let inputID, let usage = next.decisions.removeValue(forKey: inputID),
            usage.countsIdle && !usage.observedTask && next.activeTaskID == nil
        {
            for root in Array(next.recentSkills.keys) {
                if usage.roots.contains(root) || next.decisions.values.contains(where: { $0.roots.contains(root) }) {
                    continue
                }
                next.recentSkills[root]?.remainingDecisions -= 1
                if next.recentSkills[root]?.remainingDecisions == 0 { next.recentSkills[root] = nil }
            }
        }
        try next.refreshLoaded()
        try next.recordChanges(previous: beforeIdle, task: nil, releaseReason: "idle")
        self = next
    }

    public mutating func resetConversation() throws {
        guard activeTaskID == nil else { throw CommunicationError.scopeClosed }
        let previous = loaded
        recentSkills = [:]
        decisions = [:]
        try refreshLoaded()
        try recordChanges(previous: previous, task: nil, releaseReason: "conversationClosed")
    }

    /// Execution interruption keeps the conversation, counters and unfinished business goal.
    public mutating func interruptSession(_ session: String? = nil, inputs: Set<String> = []) throws {
        var next = self
        if let task = next.tasks.first(where: { $0.id == next.activeTaskID }),
            session == nil || task.sessionID == session || !Set(task.inputIDs).isDisjoint(with: inputs)
        {
            try next.settleTask(finishRequested: false)
        }
        next.decisions = next.decisions.filter {
            session != nil && $0.value.sessionID != session && !inputs.contains($0.key)
        }
        self = next
    }

    public mutating func closeSession(_ session: String, inputs: Set<String>) throws {
        try interruptSession(session, inputs: inputs)
        let previous = loaded
        recentSkills = recentSkills.filter { $0.value.sessionID != session }
        try refreshLoaded()
        try recordChanges(previous: previous, task: nil, releaseReason: "sessionClosed")
    }

    public mutating func recover() {
        for i in tasks.indices where !["completed", "cancelled", "failed", "interrupted"].contains(tasks[i].status) {
            tasks[i].status = "interrupted"
            tasks[i].updatedAt = Date()
        }
        activeTaskID = nil
        loaded = []
        recentSkills = [:]
        taskSkillRoots = []
        decisions = [:]
    }
    public func validate() throws {
        guard version == 4, (baseSkillIDs?.count ?? 0) <= 16, loaded.count <= 16,
            Set(loaded).count == loaded.count, tasks.count <= 256,
            events.count <= 256, decisions.count <= 32, recentSkills.count <= 16, taskSkillRoots.count <= 16,
            policy.idleDecisions > 0, policy.maximumNonBaseSkills > 0, policy.maximumNonBaseBytes > 0,
            recentSkills.values.allSatisfy({ (1...policy.idleDecisions).contains($0.remainingDecisions) }),
            Set(recentSkills.keys).isDisjoint(with: taskSkillRoots),
            activeTaskID != nil || taskSkillRoots.isEmpty,
            decisions.values.allSatisfy({ $0.roots.count <= 16 }),
            inputBindings.count <= 256,
            Set(tasks.map(\.id)).count == tasks.count,
            tasks.allSatisfy({
                $0.inputIDs.count <= 256 && Set($0.inputIDs).count == $0.inputIDs.count
                    && [
                        "running", "waitingUser", "finishing", "cancelling", "completed", "cancelled", "failed",
                        "interrupted",
                    ].contains($0.status)
            }),
            activeTaskID == nil || tasks.contains(where: { $0.id == activeTaskID })
        else { throw CommunicationError.invalidPayload }
    }
    public func instructions(includeOverview: Bool = true) throws -> String {
        let templates = try AgentPrompts.skillCatalog()
        let overview =
            includeOverview
            ? "\n" + (try templates.render("availableHeading")) + "\n" + (try AgentConfigurations.skillOverview()) : ""
        return overview
            + "\n" + (try templates.render("loadedHeading")) + "\n"
            + (try AgentSkillLoader.instructions(loaded))
    }
}

extension AgentTaskSkillState {
    public struct ContextSnapshot: Encodable, Sendable, Equatable {
        public struct Task: Encodable, Sendable, Equatable {
            public let goal: String
            public let status: String
        }
        public let task: Task?
        public let skills: [String]
        private enum CodingKeys: String, CodingKey { case task, skills }
        public func encode(to encoder: any Encoder) throws {
            var fields = encoder.container(keyedBy: CodingKeys.self)
            try fields.encode(task, forKey: .task)
            try fields.encode(skills, forKey: .skills)
        }
    }
    public func contextSnapshot(session: String) -> ContextSnapshot {
        let active = tasks.first { $0.id == activeTaskID && $0.sessionID == session }
        return ContextSnapshot(task: active.map { .init(goal: $0.goal, status: $0.status) }, skills: loaded)
    }
}

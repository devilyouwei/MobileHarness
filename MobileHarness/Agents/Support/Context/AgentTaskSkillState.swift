import AgentCore
import Foundation
import Storage

/// Durable business state for a single foreground task; no executable code is loaded from assets.
public enum RecognitionBinding: Codable, Sendable, Equatable {
    case conversation
    case task(String)
}

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
    }
    public var version = 3
    public var temporaryInputID: String?
    public var baseSkillIDs: [String]?
    public var loaded: [String] = []
    public var mode: String { activeTaskID == nil ? "default" : "task" }
    public var activeTaskID: String?
    public var tasks: [TaskRecord] = []
    public var events: [Event] = []
    public var recognitionBindings: [String: RecognitionBinding] = [:]
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
        tasks[index].status = "running"
        tasks[index].updatedAt = Date()
    }
    public mutating func initialize(fixed fixedCapabilities: CapabilityRegistry, baseSkills: [String]) throws {
        guard version == 3 else { throw CommunicationError.invalidPayload }
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
        return activeTaskID == nil ? "decision" : "task"
    }
    public mutating func control(
        _ operation: String, arguments: [String: String], inputID: String,
        fixed fixedCapabilities: CapabilityRegistry,
        sessionID: String? = nil, taskID: String? = nil
    ) throws -> String {
        let allowed: Set<String>
        let required: Set<String>
        switch operation {
        case "startTask":
            allowed = ["goal", "skills", "execution"]
            required = ["goal"]
        case "loadSkills", "releaseSkills":
            allowed = ["skills"]
            required = allowed
        case "finishTask":
            allowed = ["summary", "continueDecision"]
            required = ["summary"]
        case "cancelTask":
            allowed = ["reason"]
            required = allowed
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
        case "startTask":
            guard activeTaskID == nil, arguments["execution"] == nil || arguments["execution"] == "foreground",
                let goal = arguments["goal"]
            else { throw CommunicationError.invalidPayload }
            let inherited = temporaryInputID == inputID ? loaded : (try base(fixed: fixedCapabilities))
            next.loaded = try AgentSkillLoader.expand(inherited + requested)
            _ = try AgentSkillLoader.registry(next.loaded, fixed: fixedCapabilities)
            if next.tasks.count == 256 { next.tasks.removeFirst() }
            guard let taskID, BusinessRecordID(rawValue: taskID)?.kind == .task else {
                throw CommunicationError.invalidPayload
            }
            let task = TaskRecord(
                id: taskID, mode: "task", goal: goal, date: Date(), status: "running",
                inputIDs: [], skills: next.loaded
            )
            next.tasks.append(task)
            next.tasks[next.tasks.count - 1].sessionID = sessionID
            next.activeTaskID = task.id
            next.temporaryInputID = nil
            try next.bind(inputID, task: task.id)
        case "loadSkills":
            if activeTaskID == nil {
                guard temporaryInputID == nil || temporaryInputID == inputID else {
                    throw CommunicationError.scopeClosed
                }
                next.temporaryInputID = inputID
            }
            next.loaded = try AgentSkillLoader.expand(next.loaded + requested)
            _ = try AgentSkillLoader.registry(next.loaded, fixed: fixedCapabilities)
        case "releaseSkills":
            let protected = try base(fixed: fixedCapabilities)
            guard requested.allSatisfy({ next.loaded.contains($0) && !protected.contains($0) }) else {
                throw CommunicationError.unauthorized
            }
            let remaining = next.loaded.filter { !requested.contains($0) }
            let expanded = try AgentSkillLoader.expand(remaining)
            guard Set(expanded) == Set(remaining) else { throw CommunicationError.unauthorized }
            next.loaded = expanded
        case "finishTask", "cancelTask":
            guard let id = activeTaskID, let index = next.tasks.firstIndex(where: { $0.id == id }),
                ["running", "waitingUser"].contains(next.tasks[index].status)
            else { throw CommunicationError.scopeClosed }
            next.tasks[index].status = operation == "finishTask" ? "finishing" : "cancelling"
            next.tasks[index].continueDecision = operation == "finishTask" && arguments["continueDecision"] == "true"
            next.tasks[index].summary = arguments[operation == "finishTask" ? "summary" : "reason"]
        default: throw HarnessError.forbiddenFunction
        }
        try next.recordChanges(previous: loaded, task: next.activeTaskID)
        if let id = next.activeTaskID, let index = next.tasks.firstIndex(where: { $0.id == id }) {
            next.tasks[index].skills = next.loaded
            next.tasks[index].updatedAt = Date()
        }
        self = next
        let receipt: [String: Any] = [
            "operation": operation, "status": "committed", "mode": mode,
            "taskID": activeTaskID ?? "none", "skills": loaded,
        ]
        return String(
            decoding: try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]), as: UTF8.self)
    }

    private mutating func recordChanges(previous: [String], task: String?) throws {
        for id in Set(previous).symmetricDifference(Set(loaded)).sorted() {
            events.append(
                Event(
                    date: Date(), operation: loaded.contains(id) ? "load" : "release",
                    skill: id, revision: try AgentConfigurations.skill(id).revision, taskID: task))
        }
        events = Array(events.suffix(256))
    }
    public mutating func roundCompleted(
        failed: Bool, fixed fixedCapabilities: CapabilityRegistry, inputID: String? = nil, failure: String? = nil,
        cancelled: Bool = false
    )
        throws
    {
        guard let id = activeTaskID, let index = tasks.firstIndex(where: { $0.id == id }) else {
            if temporaryInputID != nil && (inputID == nil || temporaryInputID == inputID) {
                let previous = loaded
                loaded = try base(fixed: fixedCapabilities)
                temporaryInputID = nil
                try recordChanges(previous: previous, task: nil)
            }
            return
        }
        tasks[index].updatedAt = Date()
        if failed && !cancelled { tasks[index].failure = failure.map { String($0.prefix(4096)) } }
        let status = tasks[index].status
        if failed || cancelled || status == "finishing" || status == "cancelling" {
            tasks[index].status = cancelled || status == "cancelling" ? "cancelled" : (failed ? "failed" : "completed")
            let previous = loaded
            activeTaskID = nil
            loaded = try base(fixed: fixedCapabilities)
            temporaryInputID = nil
            for skill in Set(previous).symmetricDifference(Set(loaded)).sorted() {
                events.append(
                    Event(
                        date: Date(), operation: loaded.contains(skill) ? "load" : "release",
                        skill: skill, revision: try AgentConfigurations.skill(skill).revision, taskID: id))
            }
            events = Array(events.suffix(256))
        } else {
            tasks[index].status = "waitingUser"
        }
    }
    public mutating func cancelSession(
        _ session: String, inputs: Set<String>, fixed: CapabilityRegistry
    ) throws {
        if let task = tasks.first(where: { $0.id == activeTaskID }),
            task.sessionID.map({ $0 == session }) ?? !Set(task.inputIDs).isDisjoint(with: inputs)
        {
            try roundCompleted(failed: false, fixed: fixed, cancelled: true)
        } else if activeTaskID == nil, let input = temporaryInputID, inputs.contains(input) {
            try roundCompleted(failed: false, fixed: fixed, inputID: input, cancelled: true)
        }
    }
    public mutating func recover() {
        for i in tasks.indices where !["completed", "cancelled", "failed", "interrupted"].contains(tasks[i].status) {
            tasks[i].status = "interrupted"
            tasks[i].updatedAt = Date()
        }
        activeTaskID = nil
        loaded = []
        recognitionBindings = [:]
        temporaryInputID = nil
    }
    public func validate() throws {
        guard version == 3, (baseSkillIDs?.count ?? 0) <= 16, loaded.count <= 16,
            Set(loaded).count == loaded.count, tasks.count <= 256,
            events.count <= 256,
            recognitionBindings.count <= 32, inputBindings.count <= 256,
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
        let overview = includeOverview ? "\n# AVAILABLE SKILLS\n" + (try AgentConfigurations.skillOverview()) : ""
        return overview
            + "\n# LOADED SKILL INSTRUCTIONS\n"
            + (try loaded.map { try AgentConfigurations.skillInstructions($0) }.joined(separator: "\n"))
    }
}

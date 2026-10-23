import AgentCore
import Foundation
import StorageCore
import StorageState
import Synchronization

/// Agent-owned public Task projection. Private task registries and Skill ownership never enter State.
public final class AgentStateContext: Sendable {
    public struct TaskFact: Codable, Sendable, Equatable {
        public let goal: String
        public let status: String
    }
    private struct Session: Sendable {
        let scope: StateScope
        let task: StateWriter<PublishedState<TaskFact>>
        let reader: any StateContextReading
        var last: TaskFact?
        var invalidated = false
    }
    private struct Sessions: Sendable {
        var closed = false
        var values: [String: Session] = [:]
    }
    private let sessions = Mutex(Sessions())
    private let storage: StateContainer
    private let publishers: (any Sendable)?
    private let agent: AgentID
    public init(storage: StateContainer, agent: AgentID, retainingPublishers: (any Sendable)? = nil) throws {
        self.publishers = retainingPublishers
        self.storage = storage
        self.agent = agent
        try storage.declare([
            StateDeclaration("camera", scope: .application), StateDeclaration("robot", scope: .application),
            StateDeclaration("task", scope: .conversation),
        ])
    }
    public func open(session id: String) throws {
        try sessions.withLock { sessions in
            guard !sessions.closed else { throw StateError.closed }
            guard sessions.values[id] == nil else { return }
            let domain = StateDomain.conversation(agent: agent.rawValue, session: id)
            let scope = try storage.makeScope(domain: domain)
            let task = try scope.register(StateKey<PublishedState<TaskFact>>("task"), initial: PublishedState())
            let reader = try storage.contextReader(domain: domain, scope: scope)
            sessions.values[id] = Session(scope: scope, task: task, reader: reader)
        }
    }
    public func snapshot(session: String, names: [String]) throws -> StateContextSnapshot {
        try sessions.withLock { sessions in
            guard !sessions.closed, let entry = sessions.values[session] else { throw StateError.closed }
            return try entry.reader.snapshot(names: names)
        }
    }
    func publish(_ skills: AgentTaskSkillState?) throws {
        try sessions.withLock { sessions in
            for id in sessions.values.keys {
                guard var session = sessions.values[id] else { continue }
                let active = skills?.tasks.first { $0.id == skills?.activeTaskID && $0.sessionID == id }
                let fact: TaskFact?
                if let active {
                    if ["running", "waitingUser"].contains(active.status) {
                        fact = TaskFact(goal: active.goal, status: active.status)
                    } else if ["finishing", "cancelling"].contains(active.status) {
                        fact = session.last
                    } else {
                        fact = nil
                    }
                } else {
                    fact = nil
                }
                do {
                    let current = try session.task.get()
                    if fact != session.last || current.value.availability != .available || session.invalidated {
                        try session.task.set(PublishedState(fact), expecting: current.revision)
                    }
                    session.invalidated = false
                    session.last = fact
                    sessions.values[id] = session
                } catch {
                    session.task.invalidate()
                    session.invalidated = true
                    sessions.values[id] = session
                    throw error
                }
            }
        }
    }
    public func close(session: String) {
        sessions.withLock { $0.values.removeValue(forKey: session)?.scope.close() }
    }
    public func close() {
        sessions.withLock { sessions in
            sessions.closed = true
            for session in sessions.values.values { session.scope.close() }
            sessions.values.removeAll()
        }
    }
}

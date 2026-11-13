import Foundation

public struct AgentTaskTermination: Sendable {
    public let scope: AgentTaskScope
    public let recipient: ExecutionOwner
    public let requesterStopped: Bool
    public let executionIDs: Set<String>
    public let reason: String
}

public actor AgentManager {
    private struct TaskGrant: Sendable {
        let scope: AgentTaskScope
        let admissionID = UUID().uuidString
        let requester: String
        let executor: String
        var executionIDs: Set<String> = []
        var cancelling = false
        var finishing = false
    }
    private var taskGrants: [String: TaskGrant] = [:]
    public func grantReceivedTask(_ scope: AgentTaskScope, sender incarnation: String) throws -> String {
        try validate(scope.requester, incarnation: incarnation, sessionID: scope.sessionID)
        return try grantTask(scope, sender: scope.requester)
    }
    @discardableResult public func grantTask(_ scope: AgentTaskScope, sender: AgentID) throws -> String {
        guard sender == scope.requester, scope.requester != scope.executor,
            taskGrants[scope.id] == nil, taskGrants.count < 32,
            let requester = identities[scope.requester], let executor = identities[scope.executor]
        else { throw CommunicationError.unauthorized }
        try validate(scope.requester, incarnation: requester, sessionID: scope.sessionID)
        try validate(scope.executor, incarnation: executor, sessionID: scope.sessionID)
        if let parentID = scope.parentID, let parent = taskGrants[parentID] {
            try validateTaskInput(parent.scope, agent: scope.requester)
            guard parent.scope.executor == scope.requester else { throw CommunicationError.unauthorized }
            var visited: Set<String> = [scope.id]
            var ancestor: String? = parentID
            while let id = ancestor {
                guard visited.insert(id).inserted else { throw CommunicationError.unauthorized }
                ancestor = taskGrants[id]?.scope.parentID
            }
        }
        let grant = TaskGrant(scope: scope, requester: requester, executor: executor)
        taskGrants[scope.id] = grant
        return grant.admissionID
    }
    private func validatedGrant(_ id: String, agent: AgentID, sessionID: String) throws -> TaskGrant {
        guard let grant = taskGrants[id], grant.scope.sessionID == sessionID,
            agent == grant.scope.executor || agent == grant.scope.requester
        else { throw CommunicationError.scopeClosed }
        try validate(grant.scope.requester, incarnation: grant.requester, sessionID: sessionID)
        try validate(grant.scope.executor, incarnation: grant.executor, sessionID: sessionID)
        return grant
    }
    public func validateTask(_ id: String, agent: AgentID, sessionID: String) throws {
        guard try !validatedGrant(id, agent: agent, sessionID: sessionID).finishing else {
            throw CommunicationError.scopeClosed
        }
    }
    public func beginTaskCompletion(_ scope: AgentTaskScope, executor: AgentID) throws
        -> (admissionID: String, executionIDs: Set<String>)
    {
        try validateTask(scope, agent: executor, sessionID: scope.sessionID)
        guard scope.executor == executor, let grant = taskGrants[scope.id] else {
            throw CommunicationError.unauthorized
        }
        guard !taskGrants.values.contains(where: { $0.scope.parentID == scope.id }) else {
            throw CommunicationError.scopeClosed
        }
        taskGrants[scope.id]?.finishing = true
        return (grant.admissionID, grant.executionIDs)
    }
    public func beginTaskCompletionIfPresent(_ scope: AgentTaskScope, executor: AgentID, incarnation: String) throws
        -> (admissionID: String, executionIDs: Set<String>)?
    {
        guard scope.executor == executor else { throw CommunicationError.unauthorized }
        try validate(executor, incarnation: incarnation, sessionID: scope.sessionID)
        guard taskGrants[scope.id] != nil else { return nil }
        return try beginTaskCompletion(scope, executor: executor)
    }
    public func validateTask(_ scope: AgentTaskScope, agent: AgentID, sessionID: String) throws {
        guard let grant = taskGrants[scope.id] else { throw CommunicationError.scopeClosed }
        guard grant.scope == scope else { throw CommunicationError.unauthorized }
        try validateTask(scope.id, agent: agent, sessionID: sessionID)
    }
    public func validateTaskInput(_ scope: AgentTaskScope, agent: AgentID) throws {
        try validateTask(scope, agent: agent, sessionID: scope.sessionID)
        guard taskGrants[scope.id]?.cancelling == false else { throw CommunicationError.scopeClosed }
    }
    public func cancelTask(_ scope: AgentTaskScope, requester: AgentID) throws {
        try validateTask(scope, agent: requester, sessionID: scope.sessionID)
        guard requester == scope.requester else { throw CommunicationError.unauthorized }
        taskGrants[scope.id]?.cancelling = true
    }
    public func taskExecutions(_ scope: AgentTaskScope) throws -> Set<String> {
        let grant = try validatedGrant(scope.id, agent: scope.executor, sessionID: scope.sessionID)
        guard grant.scope == scope else { throw CommunicationError.unauthorized }
        return grant.executionIDs
    }
    public func registerExecution(_ id: String, scope: AgentTaskScope, agent: AgentID) throws {
        try validateTaskInput(scope, agent: agent)
        guard agent == scope.executor, var grant = taskGrants[scope.id] else { throw CommunicationError.unauthorized }
        guard grant.executionIDs.contains(id) || grant.executionIDs.count < 32 else {
            throw CommunicationError.capacityExceeded
        }
        grant.executionIDs.insert(id)
        taskGrants[scope.id] = grant
    }
    public func failTask(
        _ scope: AgentTaskScope, executor: AgentID, incarnation: String, reason: String, admissionID: String? = nil
    ) throws
        -> [AgentTaskTermination]
    {
        let root = try validatedGrant(scope.id, agent: executor, sessionID: scope.sessionID)
        guard admissionID == nil || root.admissionID == admissionID else { throw CommunicationError.scopeClosed }
        guard root.scope == scope, scope.executor == executor, root.executor == incarnation else {
            throw CommunicationError.unauthorized
        }
        var ids: Set<String> = [scope.id]
        var prior = -1
        while prior != ids.count {
            prior = ids.count
            for grant in taskGrants.values where grant.scope.parentID.map(ids.contains) == true {
                ids.insert(grant.scope.id)
            }
        }
        let events = taskGrants.values.filter { ids.contains($0.scope.id) }.map { grant in
            let child = grant.scope.id != scope.id
            return AgentTaskTermination(
                scope: grant.scope,
                recipient: ExecutionOwner(
                    agent: child ? grant.scope.executor : grant.scope.requester,
                    incarnation: child ? grant.executor : grant.requester, sessionID: grant.scope.sessionID),
                requesterStopped: child, executionIDs: grant.executionIDs, reason: String(reason.prefix(512)))
        }
        for id in ids { taskGrants[id] = nil }
        return events
    }
    @discardableResult public func retireTask(_ id: String, admissionID: String? = nil) -> Bool {
        if let admissionID, taskGrants[id]?.admissionID != admissionID { return false }
        return taskGrants.removeValue(forKey: id) != nil
    }
    private var identities: [AgentID: String] = [:]
    private var sessions: [AgentID: String] = [:]
    private var registry = AgentRegistry()
    private var stopObservers: [String: @Sendable (AgentID, String, [AgentTaskTermination]) async -> Void] = [:]

    public func observeStops(
        id: String, observer: @escaping @Sendable (AgentID, String, [AgentTaskTermination]) async -> Void
    ) throws {
        if stopObservers[id] != nil { return }
        guard stopObservers.count < 4 else { throw CommunicationError.capacityExceeded }
        stopObservers[id] = observer
    }

    public func removeStopObserver(_ id: String) { stopObservers[id] = nil }
    public init() {}
    public func register(_ agent: any Agent, sessionID: String? = nil) throws {
        guard stopping[agent.descriptor.id] == nil else { throw CommunicationError.scopeClosed }
        try registry.register(agent)
        identities[agent.descriptor.id] = UUID().uuidString
        sessions[agent.descriptor.id] = sessionID
    }
    public func agent(_ id: AgentID) throws -> any Agent {
        try registry.agent(id)
    }
    public func descriptors() -> [AgentDescriptor] {
        registry.all.map(\.descriptor).sorted { $0.id.rawValue < $1.id.rawValue }
    }
    public func start(_ id: AgentID) async throws { try await agent(id).start() }
    public func pause(_ id: AgentID) async throws { try await agent(id).pause() }
    public func resume(_ id: AgentID) async throws { try await agent(id).resume() }
    public func outputIdentity(for producer: any Agent) throws -> String {
        let registered = try agent(producer.descriptor.id)
        guard registered === producer else { throw CommunicationError.staleIncarnation }
        return try identity(producer.descriptor.id)
    }
    public func identity(_ id: AgentID) throws -> String {
        guard let identity = identities[id] else { throw CommunicationError.unavailableTarget }
        return identity
    }
    public func validate(_ id: AgentID, incarnation: String, sessionID: String) throws {
        guard identities[id] == incarnation else { throw CommunicationError.staleIncarnation }
        guard sessions[id].map({ $0 == sessionID }) ?? true else { throw CommunicationError.scopeClosed }
    }
    private var stopping: [AgentID: Task<Void, Never>] = [:]
    public func stop(_ id: AgentID) async throws {
        if let existing = stopping[id] {
            await existing.value
            return
        }
        let target = try agent(id)
        var endingIDs = Set(
            taskGrants.values.filter {
                $0.scope.requester == id || $0.scope.executor == id
            }.map { $0.scope.id })
        // Revocation follows task ancestry, including grandchildren whose Agent remains alive.
        var prior = -1
        while prior != endingIDs.count {
            prior = endingIDs.count
            for grant in taskGrants.values where grant.scope.parentID.map(endingIDs.contains) == true {
                endingIDs.insert(grant.scope.id)
            }
        }
        let ending = taskGrants.values.filter { endingIDs.contains($0.scope.id) }
        let terminations = ending.map { grant in
            let requesterStopped = grant.scope.requester == id || grant.scope.parentID.map(endingIDs.contains) == true
            return AgentTaskTermination(
                scope: grant.scope,
                recipient: ExecutionOwner(
                    agent: requesterStopped ? grant.scope.executor : grant.scope.requester,
                    incarnation: requesterStopped ? grant.executor : grant.requester, sessionID: grant.scope.sessionID),
                requesterStopped: requesterStopped, executionIDs: grant.executionIDs,
                reason: requesterStopped ? "Requesting task or Agent ended" : "Executing Agent stopped")
        }
        for grant in ending { taskGrants[grant.scope.id] = nil }
        let identity = identities.removeValue(forKey: id)
        let observers = Array(stopObservers.values)
        let cleanup = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await target.stop() }
                if let identity {
                    for observer in observers { group.addTask { await observer(id, identity, terminations) } }
                }
            }
        }
        stopping[id] = cleanup
        await cleanup.value
        stopping[id] = nil
    }
    public func remove(_ id: AgentID) async throws {
        try await stop(id)
        registry.remove(id)
        sessions[id] = nil
    }
    public func stopAll() async {
        for agent in registry.all {
            do { try await stop(agent.descriptor.id) } catch {}
        }
    }
}

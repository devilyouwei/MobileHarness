import Foundation

public protocol AgentContextState: Codable, Sendable {
    /// Called only after loading a durable snapshot. No operation may be replayed here.
    func validateContextState() throws
    mutating func recoverInterruptedWork()
}
extension AgentContextState {
    public mutating func recoverInterruptedWork() {}
    public func validateContextState() throws {}
}

public struct AgentContext<State: AgentContextState>: Codable, Sendable {
    public static var maximumEvidenceBytes: Int { 32 * 1024 * 1024 }
    public struct Record: Codable, Sendable, Equatable {
        public let id: String
        public let taskID: String?
        public let kind: String
        public let date: Date
        public let data: Data
        public init(id: String? = nil, taskID: String? = nil, kind: String, data: Data = Data()) throws {
            guard !kind.isEmpty, kind.utf8.count <= 64, data.count <= 524_288 else {
                throw CommunicationError.invalidPayload
            }
            self.id = try id ?? UUID().uuidString
            self.taskID = taskID
            self.kind = kind
            self.date = Date()
            self.data = data
        }
    }
    public let version: Int
    public let agentID: AgentID
    public let scopeID: String
    public private(set) var revision: UInt64
    public enum WorkState: String, Codable, Sendable {
        case queued, running, awaitingFeedback, continuation, completed, failed, cancelled, interrupted
        public var terminal: Bool {
            self == .completed || self == .failed || self == .cancelled || self == .interrupted
        }
    }
    public struct Work: Codable, Sendable {
        public let sessionID: String
        public let admittedAt: Date
        public var state: WorkState
        public var budget: AgentTaskBudget?
    }
    public private(set) var work: [String: Work] = [:]
    public var tasks = AgentTaskRegistry()
    public var state: State
    public private(set) var records: [Record]
    public private(set) var consumedBatches: [SignalBatch]
    public private(set) var evictedRecordCount: UInt64?
    public private(set) var evictedBatchCount: UInt64?
    public init(agentID: AgentID, scopeID: String, state: State) {
        version = 1
        self.agentID = agentID
        self.scopeID = scopeID
        self.state = state
        revision = 0
        records = []
        consumedBatches = []
    }
    public mutating func append(_ record: Record, retainingLast: Int? = nil) throws {
        guard revision < UInt64.max else { throw CommunicationError.capacityExceeded }
        guard !records.contains(where: { $0.id == record.id }) else { throw CommunicationError.outOfOrder }
        if let retainingLast {
            guard (1...8192).contains(retainingLast) else { throw CommunicationError.invalidPayload }
            let removed = max(0, records.count - retainingLast + 1)
            if removed > 0 {
                guard (evictedRecordCount ?? 0) <= UInt64.max - UInt64(removed) else {
                    throw CommunicationError.capacityExceeded
                }
                records.removeFirst(removed)
                evictedRecordCount = (evictedRecordCount ?? 0) + UInt64(removed)
            }
        }
        guard records.count < 8192 else { throw CommunicationError.capacityExceeded }
        let retainedBytes = records.reduce(0) { $0 + $1.data.count }
        guard record.data.count <= Self.maximumEvidenceBytes - retainedBytes else {
            throw CommunicationError.capacityExceeded
        }
        records.append(record)

    }
    public mutating func consume(_ batch: SignalBatch, retainingLast: Int? = nil) throws {
        guard revision < UInt64.max, !consumedBatches.contains(where: { $0.id == batch.id }) else {
            throw CommunicationError.capacityExceeded
        }
        if let retainingLast {
            guard (1...8192).contains(retainingLast) else { throw CommunicationError.invalidPayload }
            let removed = max(0, consumedBatches.count - retainingLast + 1)
            if removed > 0 {
                guard (evictedBatchCount ?? 0) <= UInt64.max - UInt64(removed) else {
                    throw CommunicationError.capacityExceeded
                }
                consumedBatches.removeFirst(removed)
                evictedBatchCount = (evictedBatchCount ?? 0) + UInt64(removed)
            }
        }
        guard consumedBatches.count < 8192 else { throw CommunicationError.capacityExceeded }
        consumedBatches.append(batch)

    }
    public mutating func eraseEvidence(for taskIDs: Set<String>) throws {
        guard !work.contains(where: { taskIDs.contains($0.key) && !$0.value.state.terminal }) else {
            throw CommunicationError.scopeClosed
        }
        records.removeAll { $0.taskID.map(taskIDs.contains) == true }
        consumedBatches.removeAll { taskIDs.contains($0.taskID) }
        for id in taskIDs { work[id] = nil }
    }
    public mutating func beginWork(_ id: String, sessionID: String) throws {
        guard work[id] == nil else { throw CommunicationError.outOfOrder }
        if work.count == 256,
            let oldest = work.filter({ $0.value.state.terminal }).min(by: { $0.value.admittedAt < $1.value.admittedAt })
        {
            work[oldest.key] = nil
        }
        guard work.count < 256 else { throw CommunicationError.capacityExceeded }
        work[id] = Work(sessionID: sessionID, admittedAt: Date(), state: .queued, budget: nil)
    }
    public mutating func transitionWork(_ id: String, to state: WorkState) throws {
        guard var task = work[id], !task.state.terminal else { throw CommunicationError.scopeClosed }
        task.state = state
        work[id] = task
    }
    public mutating func recordBudget(_ budget: AgentTaskBudget, for id: String) throws {
        try budget.validate()
        guard work[id] != nil else { throw CommunicationError.scopeClosed }
        work[id]?.budget = budget
    }
    public mutating func recoverWork() {
        for (id, task) in work where !task.state.terminal { work[id]?.state = .interrupted }
    }
    public mutating func advanceRevision() throws {
        guard revision < UInt64.max else { throw CommunicationError.capacityExceeded }
        revision += 1
    }
    public func validate(agent: AgentID, scope: String) throws {
        try state.validateContextState()
        try tasks.validate()
        for entry in work.values { try entry.budget?.validate() }
        guard version == 1, agentID == agent, scopeID == scope, records.count <= 8192, work.count <= 256,
            consumedBatches.count <= 8192,
            records.reduce(0, { $0 + $1.data.count }) <= Self.maximumEvidenceBytes,
            Set(records.map(\.id)).count == records.count,
            Set(consumedBatches.map(\.id)).count == consumedBatches.count,
            records.allSatisfy({ !$0.kind.isEmpty && $0.kind.utf8.count <= 64 && $0.data.count <= 524_288 }),
            consumedBatches.allSatisfy({
                !$0.signalIDs.isEmpty && $0.signalIDs.count <= 128
                    && Set($0.signalIDs).count == $0.signalIDs.count && $0.admissionSequence > 0
            })
        else { throw CommunicationError.invalidPayload }
    }
}

/// The adapter must atomically reject a stale revision and never reset a corrupt document.
public struct AgentContextPersistence<State: AgentContextState>: Sendable {
    public let load: @Sendable () async throws -> AgentContext<State>?
    public let commit: @Sendable (AgentContext<State>, UInt64?) async throws -> Void
    public init(
        load: @escaping @Sendable () async throws -> AgentContext<State>?,
        commit: @escaping @Sendable (AgentContext<State>, UInt64?) async throws -> Void
    ) {
        self.load = load
        self.commit = commit
    }
}

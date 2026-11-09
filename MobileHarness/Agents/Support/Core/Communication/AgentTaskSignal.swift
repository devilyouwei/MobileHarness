import Foundation

public enum AgentTaskExecution: String, Codable, Sendable { case foreground, background }

/// Task identity is distinct from runtime execution ownership and causal routing hops.
public struct AgentTaskScope: Codable, Sendable, Equatable {
    public let id: String
    public let parentID: String?
    public let requester: AgentID
    public let executor: AgentID
    public let sessionID: String
    public let execution: AgentTaskExecution
    public init(
        id: String, parentID: String? = nil, requester: AgentID, executor: AgentID, sessionID: String,
        execution: AgentTaskExecution = .foreground
    ) {
        self.execution = execution
        self.id = id
        self.parentID = parentID
        self.requester = requester
        self.executor = executor
        self.sessionID = sessionID
    }
    private enum CodingKeys: String, CodingKey { case id, parentID, requester, executor, sessionID, execution }
    public init(from decoder: any Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try value.decode(String.self, forKey: .id),
            parentID: try value.decodeIfPresent(String.self, forKey: .parentID),
            requester: try value.decode(AgentID.self, forKey: .requester),
            executor: try value.decode(AgentID.self, forKey: .executor),
            sessionID: try value.decode(String.self, forKey: .sessionID),
            execution: try value.decode(AgentTaskExecution.self, forKey: .execution))
    }

}

public struct AgentTaskSignal: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case request, input, progress, result, cancel }
    public enum Status: String, Codable, Sendable { case succeeded, failed, cancelled }
    public let kind: Kind
    public let scope: AgentTaskScope
    public let businessContract: String?
    public let data: Data
    public let status: Status?
    public let goal: String?
    public let requestedSkills: [String]?
    public var contract: String { "task." + kind.rawValue }
    public init(
        kind: Kind, scope: AgentTaskScope, businessContract: String? = nil, data: Data, status: Status? = nil,
        goal: String? = nil, requestedSkills: [String]? = nil
    ) throws {
        self.goal = goal
        self.requestedSkills = requestedSkills
        self.kind = kind
        self.scope = scope
        self.businessContract = businessContract
        self.data = data
        self.status = status
        try validate()
    }
    public func validate() throws {
        guard goal == nil || (!(goal?.isEmpty ?? true) && (goal?.utf8.count ?? 0) <= 4096),
            (requestedSkills?.count ?? 0) <= 16,
            Set(requestedSkills ?? []).count == (requestedSkills?.count ?? 0),
            (requestedSkills ?? []).allSatisfy({ CapabilityRegistry.validName($0) }),
            businessContract.map({ !$0.isEmpty && $0.utf8.count <= 64 })
                ?? (kind == .request && scope.execution == .background), data.count <= 65_536,
            (kind == .result) == (status != nil), scope.id != scope.parentID,
            CapabilityRegistry.validName(scope.requester.rawValue),
            CapabilityRegistry.validName(scope.executor.rawValue)
        else { throw CommunicationError.invalidPayload }
    }
    public func message() throws -> AgentMessage {
        try validate()
        return AgentMessage(contract: contract, content: self, maximumBytes: 131_072, validate: { try $0.validate() })
    }
    public static var contracts: [CommunicationContract] {
        [Kind.request, .input, .progress, .result, .cancel].map { kind in
            CommunicationContract(
                name: "task." + kind.rawValue, kind: .observation, maximumBytes: 131_072,
                startsNewWork: true,
                validateMessage: { message in
                    guard let signal = message.content(as: AgentTaskSignal.self), signal.kind == kind else {
                        throw CommunicationError.invalidPayload
                    }
                    try signal.validate()
                })
        }
    }
}

/// Owned by the processing Agent. Remote task completion is never a delivery receipt.
public struct AgentTaskRegistry: Codable, Sendable {
    public enum State: String, Codable, Sendable {
        case requested, accepted, running, cancelling, succeeded, failed, cancelled, interrupted
    }
    public struct Task: Codable, Sendable {
        public let scope: AgentTaskScope
        public var state: State
        public var lastSignalID: String
        public var signalIDs: [String] = []
    }
    private var tasks: [String: Task] = [:]
    public init() {}
    public func task(_ id: String) -> Task? { tasks[id] }
    public var records: [Task] { tasks.values.sorted { $0.scope.id < $1.scope.id } }
    private func validateBackgroundCapacity(_ scope: AgentTaskScope) throws {
        if scope.execution == .background {
            let active = tasks.values.filter {
                $0.scope.execution == .background
                    && ![State.succeeded, .failed, .cancelled, .interrupted].contains($0.state)
            }
            guard active.count < 16 else { throw CommunicationError.capacityExceeded }
        }
    }
    public mutating func accept(_ signal: AgentTaskSignal, input: AgentInput, agent: AgentID) throws {
        try signal.validate()
        let runtimeTermination =
            input.metadata.origin == .runtime && input.metadata.source == "runtime"
            && input.metadata.incarnation == nil
            && (signal.kind == .cancel || (signal.kind == .result && signal.status == .failed))
        guard runtimeTermination || (input.metadata.origin == .agent && input.metadata.incarnation != nil) else {
            throw CommunicationError.unauthorized
        }
        guard input.sessionID == signal.scope.sessionID,
            input.metadata.contract == signal.contract,
            input.payload.kind == .observation
        else { throw CommunicationError.unauthorized }
        let incoming = signal.kind == .request || signal.kind == .input || signal.kind == .cancel
        let source = incoming ? signal.scope.requester : signal.scope.executor
        let target = incoming ? signal.scope.executor : signal.scope.requester
        guard runtimeTermination || input.metadata.source == source.rawValue, agent == target else {
            throw CommunicationError.unauthorized
        }
        if signal.kind == .request {
            try validateBackgroundCapacity(signal.scope)
            try reserve(signal.scope.id)
            guard tasks[signal.scope.id] == nil else { throw CommunicationError.capacityExceeded }
            tasks[signal.scope.id] = Task(
                scope: signal.scope, state: .accepted, lastSignalID: input.id, signalIDs: [input.id])
            return
        }
        guard var task = tasks[signal.scope.id], task.scope == signal.scope,
            ![State.succeeded, .failed, .cancelled, .interrupted].contains(task.state),
            !task.signalIDs.contains(input.id), task.signalIDs.count < 128
        else { throw CommunicationError.scopeClosed }
        guard task.state != .cancelling || signal.kind == .cancel || signal.kind == .result else {
            throw CommunicationError.scopeClosed
        }
        switch signal.kind {
        case .request: break
        case .input, .progress: task.state = .running
        case .cancel: task.state = .cancelling
        case .result:
            switch signal.status {
            case .succeeded: task.state = .succeeded
            case .failed: task.state = .failed
            case .cancelled: task.state = .cancelled
            case nil: throw CommunicationError.invalidPayload
            }
        }
        guard task.state != .cancelling || signal.kind == .cancel || signal.kind == .result else {
            throw CommunicationError.scopeClosed
        }
        task.signalIDs.append(input.id)
        task.lastSignalID = input.id
        tasks[task.scope.id] = task
    }
    public mutating func register(_ scope: AgentTaskScope) throws {
        try validateBackgroundCapacity(scope)
        try reserve(scope.id)
        guard tasks[scope.id] == nil else { throw CommunicationError.capacityExceeded }
        tasks[scope.id] = Task(scope: scope, state: .requested, lastSignalID: scope.id)
    }
    public mutating func acknowledge(_ id: String, accepted: Bool) throws {
        guard var task = tasks[id] else { throw CommunicationError.scopeClosed }
        // A fast child's terminal report can precede the request's admission receipt.
        if task.state == .requested {
            task.state = accepted ? .accepted : .failed
            tasks[id] = task
        }
    }
    /// Sender-side delivery evidence is distinct from executor completion.
    public mutating func delivered(_ id: String, kind: AgentTaskSignal.Kind, accepted: Bool) throws {
        guard var task = tasks[id] else { throw CommunicationError.scopeClosed }
        guard accepted, ![State.succeeded, .failed, .cancelled, .interrupted].contains(task.state) else { return }
        if kind == .cancel { task.state = .cancelling }
        if kind == .input && task.state != .cancelling { task.state = .running }
        tasks[id] = task
    }
    public mutating func report(_ signal: AgentTaskSignal, agent: AgentID) throws {
        guard signal.kind == .result, signal.scope.executor == agent,
            var task = tasks[signal.scope.id], task.scope == signal.scope,
            ![State.succeeded, .failed, .cancelled, .interrupted].contains(task.state)
        else { throw CommunicationError.scopeClosed }
        switch signal.status {
        case .succeeded: task.state = .succeeded
        case .failed: task.state = .failed
        case .cancelled: task.state = .cancelled
        case nil: throw CommunicationError.invalidPayload
        }
        tasks[signal.scope.id] = task
    }
    private mutating func reserve(_ id: String) throws {
        guard tasks[id] == nil else { throw CommunicationError.scopeClosed }
        if tasks.count == 256 {
            let retired = tasks.filter { [.succeeded, .failed, .cancelled, .interrupted].contains($0.value.state) }
                .keys.sorted { $0 < $1 }.first
            guard let retired else { throw CommunicationError.capacityExceeded }
            tasks[retired] = nil
        }
    }
    public func validate() throws {
        guard tasks.count <= 256,
            tasks.allSatisfy({
                $0.key == $0.value.scope.id && $0.value.signalIDs.count <= 128
                    && Set($0.value.signalIDs).count == $0.value.signalIDs.count
            })
        else {
            throw CommunicationError.invalidPayload
        }
    }
    public mutating func recover() {
        for (id, task) in tasks where ![State.succeeded, .failed, .cancelled, .interrupted].contains(task.state) {
            tasks[id]?.state = .interrupted
        }
    }
}

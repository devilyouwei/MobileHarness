import AgentCore
import Foundation
import Storage

/// Validated runtime transactions over one Storage-owned process-memory snapshot.
public actor AgentContextRepository<State: AgentContextState> {
    public nonisolated let scopeID: String
    public nonisolated let agentID: AgentID
    private let memory: any StateRepository<AgentContext<State>>
    private var value: AgentContext<State> {
        get { memory.read() }
        set { memory.replace(newValue) }
    }
    private let persistence: AgentContextPersistence<State>?
    private var committedRevision: UInt64?
    private var loaded = false
    private var writing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init(
        agent: AgentID, scope: String, state: State,
        persistence: AgentContextPersistence<State>? = nil
    ) {
        self.scopeID = scope
        self.agentID = agent
        memory = MemoryStateStore(AgentContext(agentID: agent, scopeID: scope, state: state))
        self.persistence = persistence
    }
    private func acquire() async throws {
        if !writing {
            writing = true
            return
        }
        guard waiters.count < 16 else { throw CommunicationError.capacityExceeded }
        await withCheckedContinuation { waiters.append($0) }
        // The slot is still ours on cancellation; caller must release it.
    }
    private func release() {
        if waiters.isEmpty { writing = false } else { waiters.removeFirst().resume() }
    }
    private func load() async throws {
        guard !loaded else { return }
        if var saved = try await persistence?.load() {
            try saved.validate(agent: value.agentID, scope: value.scopeID)
            let priorRevision = saved.revision
            saved.state.recoverInterruptedWork()
            saved.tasks.recover()
            saved.recoverWork()
            try saved.advanceRevision()
            try await persistence?.commit(saved, priorRevision)
            value = saved
            committedRevision = saved.revision
        }
        try value.validate(agent: agentID, scope: scopeID)
        loaded = true
    }
    public func snapshot() async throws -> AgentContext<State> {
        try await acquire()
        defer { release() }
        try await load()
        return value
    }
    public func exists() async throws -> Bool {
        try await acquire()
        defer { release() }
        try await load()
        return committedRevision != nil
    }
    public func update(_ mutation: @Sendable (inout AgentContext<State>) throws -> Void) async throws {
        try await transaction(mutation)
    }

    public func transaction<Result: Sendable>(
        _ mutation: @Sendable (inout AgentContext<State>) throws -> Result
    ) async throws -> Result {
        try await acquire()
        defer { release() }
        try await load()
        var next = value
        let result = try mutation(&next)
        try next.advanceRevision()
        try next.validate(agent: value.agentID, scope: value.scopeID)
        try await persistence?.commit(next, committedRevision)
        value = next
        committedRevision = next.revision
        return result
    }

    /// The caller owns classification, ordering, consumption and retention policy.
    public func recordSignal(
        _ input: AgentInput, disposition: SignalDisposition, admissionSequence: UInt64,
        consumed: Bool, retainingLast: Int? = nil,
        mutation: @Sendable (inout AgentContext<State>) throws -> Void = { _ in }
    ) async throws {
        let data = try JSONEncoder().encode(SignalEvidence(input))
        let record = try AgentContext<State>.Record(
            taskID: input.taskScope?.id ?? (disposition == .feedback ? input.metadata.parentID ?? input.id : input.id),
            kind: input.metadata.contract, data: data)
        let batch = try SignalBatch(
            taskID: input.taskScope?.id ?? input.id, signalIDs: [input.id], admissionSequence: admissionSequence)
        try await update { context in
            try context.append(record, retainingLast: retainingLast)
            try mutation(&context)
            if consumed { try context.consume(batch, retainingLast: retainingLast) }
        }
    }
}

/// Neutral durable evidence; domain records are encoded by the owning preprocessor.
public struct SignalEvidence: Codable, Sendable {
    public let signalID: String
    public let sessionID: String
    public let rootID: String
    public let parentID: String?
    public let source: String
    public let origin: SignalOrigin
    public let contract: String
    public let sequence: UInt64
    public let content: Data?
    public init(_ input: AgentInput) throws {
        signalID = input.id
        sessionID = input.sessionID
        rootID = input.metadata.rootID
        parentID = input.metadata.parentID
        source = input.metadata.source
        origin = input.metadata.origin
        contract = input.metadata.contract
        sequence = input.metadata.sequence
        switch input.payload {
        case .text(let text): content = Data(text.utf8)
        case .observation(let message): content = try message.encodedContent()
        case .toolResult(let result): content = try JSONEncoder().encode(result)
        case .actionResult(let result): content = try JSONEncoder().encode(result)
        case .roundResult(let result): content = try JSONEncoder().encode(result)
        case .communicationReceipt(let result): content = try JSONEncoder().encode(result)
        default: content = nil
        }
    }
}

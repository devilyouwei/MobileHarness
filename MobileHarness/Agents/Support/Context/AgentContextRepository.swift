import AgentCore
import Foundation
import StorageCore

public struct AgentPublicProjectionFailure: Error, Sendable {
    public let committedRevision: UInt64
    public let underlying: any Error
}

/// Private actor-owned memory. Only an explicit owner projection may publish public facts.
public actor AgentContextRepository<State: AgentContextState> {
    public nonisolated let scopeID: String
    public nonisolated let agentID: AgentID
    private var memory: AgentContext<State>
    private var publish: (@Sendable (AgentContext<State>) throws -> Void)?
    private let persistence: AgentContextPersistence<State>?
    private var committedRevision: UInt64?
    private var loaded = false
    private var writing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init(
        agent: AgentID, scope: String, state: State,
        persistence: AgentContextPersistence<State>? = nil
    ) throws {
        self.scopeID = scope
        self.agentID = agent
        memory = AgentContext(agentID: agent, scopeID: scope, state: state)
        try memory.validate(agent: agent, scope: scope)
        self.persistence = persistence
    }
    public func installPublicProjection(_ publish: @escaping @Sendable (AgentContext<State>) throws -> Void)
        async throws
    {
        try await acquire()
        defer { release() }
        try await load()
        guard self.publish == nil else { throw CommunicationError.invalidPayload }
        try publish(memory)
        self.publish = publish
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
            try saved.validate(agent: agentID, scope: scopeID)
            let priorRevision = saved.revision
            saved.state.recoverInterruptedWork()
            saved.tasks.recover()
            saved.recoverWork()
            try saved.advanceRevision()
            try await persistence?.commit(saved, priorRevision)
            memory = saved
            committedRevision = saved.revision
        }
        try memory.validate(agent: agentID, scope: scopeID)
        loaded = true
    }
    public func snapshot() async throws -> AgentContext<State> {
        try await acquire()
        defer { release() }
        try await load()
        return memory
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
        var next = memory
        let result = try mutation(&next)
        try next.advanceRevision()
        try next.validate(agent: agentID, scope: scopeID)
        try await persistence?.commit(next, committedRevision)
        memory = next
        committedRevision = next.revision
        // A failed public projection cannot undo a durable/private business commit.
        do { try publish?(next) } catch {
            throw AgentPublicProjectionFailure(committedRevision: next.revision, underlying: error)
        }
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

import Foundation

public struct DeliveryReport: Sendable {
    public let delivered: [AgentID]
    public let rejected: [AgentID: String]
    public init(delivered: [AgentID] = [], rejected: [AgentID: String] = [:]) {
        self.delivered = delivered
        self.rejected = rejected
    }
}

/// A port captures the runtime identity; callers can only supply payload and causal input.
public struct AgentMessaging: Sendable {
    private let operation: @Sendable (PerceptionObservation, AgentInput, AgentID?) async throws -> DeliveryReport
    public init(
        operation: @escaping @Sendable (PerceptionObservation, AgentInput, AgentID?) async throws -> DeliveryReport
    ) {
        self.operation = operation
    }
    public func publish(_ observation: PerceptionObservation, parent: AgentInput) async throws -> DeliveryReport {
        try await operation(observation, parent, nil)
    }
    public func send(_ observation: PerceptionObservation, parent: AgentInput, to target: AgentID) async throws
        -> DeliveryReport
    {
        try await operation(observation, parent, target)
    }
}

/// Bounded per-target workers. Waiting receipts retain reservations until every branch settles.
public actor InternalSignalBus {
    public typealias Delivery = @Sendable (AgentInput, AgentID, UUID) async throws -> Void
    private struct Job: Sendable {
        let operation: UUID
        let input: AgentInput
        let target: AgentID
        let incarnation: UUID
        let stateKey: String?
    }
    private struct Operation {
        let input: AgentInput
        let bytes: Int
        var remaining: Int
        var delivered: [AgentID] = []
        var rejected: [AgentID: String] = [:]
        let continuation: CheckedContinuation<DeliveryReport, Never>
    }
    private let deliver: Delivery
    private var operations: [UUID: Operation] = [:]
    private var lanes: [AgentID: [Job]] = [:]
    private var workers: [AgentID: Task<Void, Never>] = [:]
    private var stateSequences: [String: UInt64] = [:]
    private var discrete: [UUID: ContinuousClock.Instant] = [:]
    private var sessions = Set<UUID>()
    private var bytes = 0
    private var branches = 0
    private var closed = false
    public private(set) var replacements = 0
    public private(set) var expirations = 0

    public init(deliver: @escaping Delivery) { self.deliver = deliver }
    public func openSession(_ id: UUID) throws {
        guard !closed else { throw CommunicationError.scopeClosed }
        guard sessions.contains(id) || sessions.count < 256 else { throw CommunicationError.capacityExceeded }
        sessions.insert(id)
    }
    public func publish(_ input: AgentInput, targets: [(AgentID, UUID)]) async throws -> DeliveryReport {
        guard !closed, sessions.contains(input.sessionID) else { throw CommunicationError.scopeClosed }
        guard !input.metadata.expired else { throw CommunicationError.expired }
        guard input.metadata.hops <= 8 else { throw CommunicationError.hopLimitExceeded }
        guard case .observation(let observation) = input.payload else { throw CommunicationError.invalidPayload }
        let size = try observation.validatedSize()
        guard !targets.isEmpty else { throw CommunicationError.noRecipients }
        guard targets.count <= 16, Set(targets.map(\.0)).count == targets.count else {
            throw CommunicationError.capacityExceeded
        }
        discrete = discrete.filter { $0.value > .now }
        guard operations[input.id] == nil, discrete[input.id] == nil else { throw CommunicationError.messageConflict }
        guard operations.count < 128,
            operations.values.filter({ $0.input.metadata.source == input.metadata.source }).count < 16,
            branches + targets.count <= 256, bytes + size * targets.count <= 8 * 1024 * 1024,
            observation.isState || discrete.count + operations.count < 1024
        else { throw CommunicationError.capacityExceeded }
        var jobs: [Job] = []
        var newKeys = Set<String>()
        for (target, incarnation) in targets {
            guard (lanes[target]?.count ?? 0) + (workers[target] == nil ? 0 : 1) < 32 else {
                throw CommunicationError.capacityExceeded
            }
            let key =
                observation.isState
                ? "\(target.rawValue)|\(input.metadata.source)|\(input.metadata.incarnation?.uuidString ?? "external")|\(input.sessionID)|\(input.metadata.contract)"
                : nil
            if let key {
                guard stateSequences[key].map({ input.metadata.sequence > $0 }) ?? true else {
                    throw CommunicationError.outOfOrder
                }
                if stateSequences[key] == nil { newKeys.insert(key) }
                guard
                    stateSequences.keys.filter({ $0.hasPrefix(target.rawValue + "|") }).count
                        + newKeys.filter({ $0.hasPrefix(target.rawValue + "|") }).count <= 32
                else {
                    throw CommunicationError.capacityExceeded
                }
            }
            jobs.append(Job(operation: input.id, input: input, target: target, incarnation: incarnation, stateKey: key))
        }
        guard stateSequences.count + newKeys.count <= 256 else { throw CommunicationError.capacityExceeded }
        return await withCheckedContinuation { continuation in
            operations[input.id] = Operation(
                input: input, bytes: size * jobs.count, remaining: jobs.count, continuation: continuation)
            bytes += size * jobs.count
            branches += jobs.count
            for job in jobs {
                if let key = job.stateKey {
                    stateSequences[key] = input.metadata.sequence
                    if let index = lanes[job.target]?.firstIndex(where: { $0.stateKey == key }) {
                        let previous = lanes[job.target]!.remove(at: index)
                        replacements += 1
                        settle(previous, error: "superseded")
                    }
                }
                lanes[job.target, default: []].append(job)
                if workers[job.target] == nil {
                    workers[job.target] = Task { await self.drain(job.target) }
                }
            }
        }
    }
    private func drain(_ target: AgentID) async {
        while let job = lanes[target]?.first {
            lanes[target]?.removeFirst()
            do {
                guard !closed, sessions.contains(job.input.sessionID), !Task.isCancelled else {
                    throw CommunicationError.scopeClosed
                }
                guard !job.input.metadata.expired else {
                    expirations += 1
                    throw CommunicationError.expired
                }
                try await deliver(job.input, target, job.incarnation)
                settle(job, error: nil)
            } catch { settle(job, error: String(describing: error)) }
        }
        workers[target] = nil
        lanes[target] = nil
    }
    private func settle(_ job: Job, error: String?) {
        guard var operation = operations[job.operation] else { return }
        branches -= 1
        operation.remaining -= 1
        if let error { operation.rejected[job.target] = error } else { operation.delivered.append(job.target) }
        if operation.remaining == 0 {
            bytes -= operation.bytes
            operations[job.operation] = nil
            if case .observation(let observation) = operation.input.payload, !observation.isState {
                discrete[job.operation] = .now.advanced(by: .seconds(60))
            }
            operation.continuation.resume(
                returning: DeliveryReport(delivered: operation.delivered, rejected: operation.rejected))
        } else {
            operations[job.operation] = operation
        }
    }
    public func closeSession(_ session: UUID) async {
        sessions.remove(session)
        for target in Array(lanes.keys) {
            let removed = lanes[target, default: []].filter { $0.input.sessionID == session }
            lanes[target]?.removeAll { $0.input.sessionID == session }
            for job in removed { settle(job, error: "scopeClosed") }
        }
        stateSequences = stateSequences.filter { !$0.key.contains("|\(session)|") }
        // Join only branches still executing for this session, without cancelling other sessions.
        let targets = Set(
            operations.values.filter { $0.input.sessionID == session }.flatMap { operation in
                workers.keys.filter { operation.rejected[$0] == nil && !operation.delivered.contains($0) }
            })
        let tasks = targets.compactMap { workers[$0] }
        for task in tasks { await task.value }
    }
    public func shutdown() async {
        closed = true
        let tasks = Array(workers.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        stateSequences.removeAll()
        discrete.removeAll()
        sessions.removeAll()
    }
}

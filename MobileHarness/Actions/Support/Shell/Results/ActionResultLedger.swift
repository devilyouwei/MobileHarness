import Foundation
import FunctionContracts

/// Scheduler-owned bounded outbox: every feedback-producing admission reserves its terminal slot.
struct ActionResultLedger {
    enum DeliveryState: String, Sendable { case reserved, pending, accepted, closed, expired }
    struct Record: Sendable {
        let executionID: String
        let roundID: String?
        let result: ExecutionResult?
        let state: DeliveryState
    }
    enum Delivery: Sendable {
        case started(ExecutionStart)
        case finished(ExecutionResult)

        var executionID: String {
            switch self {
            case .started(let value): value.executionID
            case .finished(let value): value.executionID
            }
        }
    }
    private struct Entry {
        let invocation: ScheduledAction
        let order: UInt64
        let snapshot: ActionInvocationSnapshot
        var result: ExecutionResult?
        var startedAt: ContinuousClock.Instant?
        var startFailure: DeliveryState?
        var completedAt: ContinuousClock.Instant?
        var attempts = 0
        var nextAttempt: ContinuousClock.Instant = .now
    }
    private var entries: [String: Entry] = [:]
    private var history: [Record] = []
    private var order: UInt64 = 0
    private(set) var evictedHistory: UInt64 = 0
    private(set) var expiredResults: UInt64 = 0
    let capacity: Int
    let deliveryTimeout: Duration

    init(capacity: Int, deliveryTimeout: Duration = .seconds(60)) {
        precondition((1...1024).contains(capacity) && deliveryTimeout > .zero)
        self.capacity = capacity
        self.deliveryTimeout = deliveryTimeout
    }

    func checkCapacity(_ invocation: ScheduledAction) throws {
        guard invocation.feedback != .none else { return }
        guard invocation.owner != nil else { throw ActionExecutionError.invalidInvocation }
        let snapshot = try ActionInvocationSnapshot(invocation.call)
        let retained = entries.values.reduce(0) { sum, entry in
            sum + entry.invocation.call.parameters.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        }
        guard retained + snapshot.retainedBytes <= 32 * 1024 * 1024 else {
            throw ActionSchedulingError.resultCapacityExceeded
        }
        guard entries.count < capacity else { throw ActionSchedulingError.resultCapacityExceeded }
    }

    mutating func reserve(_ invocation: ScheduledAction) throws {
        guard invocation.feedback != .none else { return }
        order &+= 1
        entries[invocation.executionID] = Entry(
            invocation: invocation, order: order, snapshot: try ActionInvocationSnapshot(invocation.call))
    }

    mutating func started(_ invocation: ScheduledAction) {
        guard invocation.feedback == .terminal,
            invocation.envelope.callID != nil || invocation.prepared?.descriptor.controlCapabilities.isEmpty == false
        else { return }
        entries[invocation.executionID]?.startedAt = .now
    }

    mutating func complete(
        _ invocation: ScheduledAction, status: ExecutionResult.Status, effect: ExecutionResult.Effect,
        completion: ActionCompletion? = nil, failure: ExecutionResult.Failure? = nil
    ) {
        guard var entry = entries[invocation.executionID], let owner = invocation.owner else { return }
        if invocation.feedback == .failuresOnly && status == .succeeded {
            entries[invocation.executionID] = nil
            return
        }
        entry.result = ExecutionResult(
            executionID: invocation.executionID, owner: owner, path: invocation.call.actionPath,
            envelope: invocation.envelope,
            status: status, effect: effect, completion: completion, failure: failure,
            invocation: entry.snapshot)
        entry.completedAt = .now
        entries[invocation.executionID] = entry
    }

    func ready() -> Delivery? {
        guard
            let entry = entries.values.filter({ ($0.startedAt != nil || $0.result != nil) && $0.nextAttempt <= .now })
                .min(by: { $0.order < $1.order })
        else { return nil }
        if entry.startedAt != nil, let owner = entry.invocation.owner {
            return .started(
                .init(
                    executionID: entry.invocation.executionID, owner: owner, envelope: entry.invocation.envelope,
                    path: entry.invocation.call.actionPath,
                    controlCapabilities: entry.invocation.prepared?.descriptor.controlCapabilities ?? []))
        }
        return entry.result.map(Delivery.finished)
    }

    var hasPending: Bool { entries.values.contains { $0.startedAt != nil || $0.result != nil } }

    mutating func delivered(_ delivery: Delivery, outcome: ActionResultDelivery) {
        let id = delivery.executionID
        guard var entry = entries[id] else { return }
        if case .started = delivery, let startedAt = entry.startedAt {
            if outcome == .retry, startedAt.duration(to: .now) < deliveryTimeout {
                deferRetry(&entry)
            } else {
                if outcome != .accepted { entry.startFailure = outcome == .closed ? .closed : .expired }
                entry.startedAt = nil
                entry.attempts = 0
                entry.nextAttempt = .now
            }
            entries[id] = entry
            return
        }
        switch outcome {
        case .accepted: finish(id, state: entry.startFailure ?? .accepted)
        case .closed: finish(id, state: .closed)
        case .retry:
            // Retry covers temporary receiver pressure only; an unresolved result must end as a visible failure.
            if let completedAt = entry.completedAt, completedAt.duration(to: .now) >= deliveryTimeout {
                expiredResults &+= 1
                finish(id, state: .expired)
                return
            }
            deferRetry(&entry)
            entries[id] = entry
        }
    }

    private func deferRetry(_ entry: inout Entry) {
        entry.attempts = min(entry.attempts + 1, 10)
        entry.nextAttempt = .now.advanced(by: .milliseconds(100 * entry.attempts))
    }

    mutating func close(sessionID: String? = nil) {
        let selected = entries.filter { sessionID == nil || $0.value.invocation.envelope.sessionID == sessionID }.map(
            \.key)
        for id in selected { finish(id, state: .closed) }
    }

    func snapshot() -> [Record] {
        history
            + entries.values.sorted { $0.order < $1.order }.map {
                Record(
                    executionID: $0.invocation.executionID, roundID: $0.invocation.envelope.roundID, result: $0.result,
                    state: $0.result == nil ? .reserved : .pending)
            }
    }

    private mutating func finish(_ id: String, state: DeliveryState) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        if history.count == 256 {
            history.removeFirst()
            evictedHistory &+= 1
        }
        history.append(
            Record(
                executionID: id, roundID: entry.invocation.envelope.roundID, result: entry.result, state: state))
        while history.reduce(0, { $0 + ($1.result?.invocation?.retainedBytes ?? 0) }) > 32 * 1024 * 1024 {
            history.removeFirst()
            evictedHistory &+= 1
        }
    }
}

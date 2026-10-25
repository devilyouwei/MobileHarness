import Foundation
import FunctionContracts

/// Scheduler-owned bounded outbox: every feedback-producing admission reserves its terminal slot.
struct ActionResultLedger {
    enum DeliveryState: String, Sendable { case reserved, pending, accepted, closed }
    struct Record: Sendable {
        let executionID: String
        let result: ExecutionResult?
        let state: DeliveryState
    }
    private struct Entry {
        let invocation: ScheduledAction
        let order: UInt64
        var result: ExecutionResult?
        var attempts = 0
        var nextAttempt: ContinuousClock.Instant = .now
    }
    private var entries: [String: Entry] = [:]
    private var history: [Record] = []
    private var order: UInt64 = 0
    private(set) var evictedHistory: UInt64 = 0
    let capacity: Int

    init(capacity: Int) {
        precondition((1...1024).contains(capacity))
        self.capacity = capacity
    }

    func checkCapacity(_ invocation: ScheduledAction) throws {
        guard invocation.feedback != .none else { return }
        guard invocation.owner != nil else { throw ActionExecutionError.invalidInvocation }
        guard entries.count < capacity else { throw ActionSchedulingError.resultCapacityExceeded }
    }

    mutating func reserve(_ invocation: ScheduledAction) {
        guard invocation.feedback != .none else { return }
        order &+= 1
        entries[invocation.executionID] = Entry(invocation: invocation, order: order)
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
            status: status, effect: effect, completion: completion, failure: failure)
        entries[invocation.executionID] = entry
    }

    mutating func ready() -> ExecutionResult? {
        return entries.values.filter { $0.result != nil && $0.nextAttempt <= .now }
            .min(by: { $0.order < $1.order })?.result
    }

    var hasPending: Bool { entries.values.contains { $0.result != nil } }

    mutating func delivered(_ id: String, outcome: ActionResultDelivery) {
        guard var entry = entries[id] else { return }
        switch outcome {
        case .accepted: finish(id, state: .accepted)
        case .closed: finish(id, state: .closed)
        case .retry:
            entry.attempts = min(entry.attempts + 1, 10)
            entry.nextAttempt = .now.advanced(by: .milliseconds(100 * entry.attempts))
            entries[id] = entry
        }
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
                    executionID: $0.invocation.executionID, result: $0.result,
                    state: $0.result == nil ? .reserved : .pending)
            }
    }

    private mutating func finish(_ id: String, state: DeliveryState) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        if history.count == 256 {
            history.removeFirst()
            evictedHistory &+= 1
        }
        history.append(Record(executionID: id, result: entry.result, state: state))
    }
}

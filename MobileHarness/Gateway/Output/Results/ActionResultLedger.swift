import Actions
import AgentCore
import Foundation

/// Scheduler-owned bounded outbox: every feedback-producing admission reserves its terminal slot.
struct ActionResultLedger {
    enum DeliveryState: String, Sendable { case reserved, pending, accepted, closed, expired, exhausted }
    struct Record: Sendable {
        let executionID: UUID
        let result: ActionResult?
        let state: DeliveryState
    }
    private struct Entry {
        let invocation: ActionInvocation
        let order: UInt64
        var result: ActionResult?
        var attempts = 0
        var nextAttempt: ContinuousClock.Instant = .now
        var deadline: ContinuousClock.Instant = .now
    }
    private var entries: [UUID: Entry] = [:]
    private var history: [Record] = []
    private var order: UInt64 = 0
    private(set) var evictedHistory: UInt64 = 0
    let capacity: Int

    init(capacity: Int) {
        precondition((1...1024).contains(capacity))
        self.capacity = capacity
    }

    func checkCapacity(_ invocation: ActionInvocation) throws {
        guard invocation.feedback != .none else { return }
        guard invocation.owner != nil else { throw ActionExecutionError.invalidInvocation }
        guard entries.count < capacity else { throw ActionSchedulingError.resultCapacityExceeded }
    }

    mutating func reserve(_ invocation: ActionInvocation) {
        guard invocation.feedback != .none else { return }
        order &+= 1
        entries[invocation.executionID] = Entry(invocation: invocation, order: order)
    }

    mutating func complete(
        _ invocation: ActionInvocation, status: ActionResult.Status, effect: ActionResult.Effect,
        completion: ActionCompletion? = nil, failure: ActionResult.Failure? = nil
    ) {
        guard var entry = entries[invocation.executionID], let owner = invocation.owner else { return }
        if invocation.feedback == .failuresOnly && status == .succeeded {
            entries[invocation.executionID] = nil
            return
        }
        entry.result = ActionResult(
            executionID: invocation.executionID, owner: owner, inputID: invocation.envelope.inputID,
            turn: invocation.envelope.turn, path: invocation.call.actionPath,
            status: status, effect: effect, completion: completion, failure: failure)
        entry.deadline = .now.advanced(by: .seconds(10))
        entries[invocation.executionID] = entry
    }

    mutating func ready() -> ActionResult? {
        let expired = entries.filter { $0.value.result != nil && $0.value.deadline <= .now }.map(\.key)
        for id in expired { finish(id, state: .expired) }
        return entries.values.filter { $0.result != nil && $0.nextAttempt <= .now }
            .min(by: { $0.order < $1.order })?.result
    }

    var hasPending: Bool { entries.values.contains { $0.result != nil } }

    mutating func delivered(_ id: UUID, outcome: ActionResultDelivery) {
        guard var entry = entries[id] else { return }
        switch outcome {
        case .accepted: finish(id, state: .accepted)
        case .closed: finish(id, state: .closed)
        case .retry:
            entry.attempts += 1
            if entry.attempts >= 4 {
                finish(id, state: .exhausted)
            } else {
                entry.nextAttempt = .now.advanced(by: .milliseconds(100 * entry.attempts))
                entries[id] = entry
            }
        }
    }

    mutating func close(sessionID: UUID? = nil) {
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

    private mutating func finish(_ id: UUID, state: DeliveryState) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        if history.count == 256 {
            history.removeFirst()
            evictedHistory &+= 1
        }
        history.append(Record(executionID: id, result: entry.result, state: state))
    }
}

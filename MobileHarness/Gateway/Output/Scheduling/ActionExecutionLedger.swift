import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts

/// Owned only by ChannelScheduler. Active records share scheduling bounds; only terminal history evicts.
struct ActionExecutionLedger {
    private var records: [UUID: ActionExecutionRecord] = [:]
    private var order: [UUID] = []
    private var terminalOrder: [UUID] = []
    private var revision: UInt64 = 0
    private var evictedCount: UInt64 = 0
    let terminalCapacity: Int

    init(terminalCapacity: Int = 100) {
        precondition((1...1000).contains(terminalCapacity))
        self.terminalCapacity = terminalCapacity
    }

    mutating func admit(_ invocation: ScheduledAction, definition: ActionBinding) {
        let semantics: ActionExecutionRecord.Semantics
        switch definition.kind {
        case .finite: semantics = .finite
        case .state: semantics = .state
        case .activityStart: semantics = .activityStart
        case .activityUpdate: semantics = .activityUpdate
        case .activityStop: semantics = .activityStop
        }
        records[invocation.executionID] = ActionExecutionRecord(
            id: invocation.executionID, path: invocation.call.actionPath, displayName: definition.displayName,
            source: invocation.envelope.source,
            sessionID: invocation.envelope.sessionID, inputID: invocation.envelope.inputID,
            channel: invocation.channel, semantics: semantics)
        order.append(invocation.executionID)
        revision += 1
    }

    @discardableResult
    mutating func transition(
        _ id: UUID, to phase: ActionExecutionRecord.Phase,
        completion: ActionCompletion? = nil, failure: ActionExecutionRecord.Failure? = nil,
        failureDescription: String? = nil
    ) -> Bool {
        guard var record = records[id], !record.isTerminal, record.phase != phase else { return false }
        // A late start cannot undo a cancellation request.
        guard !(record.phase == .cancelling && phase == .running) else { return false }
        record.phase = phase
        if phase == .running { record.startedAt = .now }
        record.completion = completion?.agentValue
        record.failureDescription = failureDescription.map { String($0.prefix(512)) }
        record.failure = failure
        if record.isTerminal {
            record.endedAt = .now
            terminalOrder.append(id)
        }
        records[id] = record
        while terminalOrder.count > terminalCapacity {
            let expired = terminalOrder.removeFirst()
            records.removeValue(forKey: expired)
            order.removeAll { $0 == expired }
            evictedCount += 1
        }
        revision += 1
        return true
    }

    func snapshot() -> ActionExecutionSnapshot {
        ActionExecutionSnapshot(
            revision: revision, records: order.compactMap { records[$0] }, evictedCount: evictedCount)
    }
}

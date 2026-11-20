import Foundation
import FunctionContracts

/// Owned only by ChannelScheduler. Active records share scheduling bounds; only terminal history evicts.
struct ActionExecutionLedger {
    private var records: [String: ActionExecutionRecord] = [:]
    private var order: [String] = []
    private var terminalOrder: [String] = []
    private var revision: UInt64 = 0
    private var evictedCount: UInt64 = 0
    let terminalCapacity: Int

    init(terminalCapacity: Int = 100) {
        precondition((1...1000).contains(terminalCapacity))
        self.terminalCapacity = terminalCapacity
    }

    mutating func admit(_ invocation: ScheduledAction, kind: ActionFunction.Kind) {
        let semantics: ActionExecutionRecord.Semantics
        switch kind {
        case .finite: semantics = .finite
        case .state: semantics = .state
        case .activityStart: semantics = .activityStart
        case .activityUpdate: semantics = .activityUpdate
        case .activityStop: semantics = .activityStop
        }
        records[invocation.executionID] = ActionExecutionRecord(
            id: invocation.executionID, path: invocation.call.actionPath,
            source: invocation.envelope.source,
            sessionID: invocation.envelope.sessionID, inputID: invocation.envelope.inputID,
            channel: invocation.channel, semantics: semantics,
            parameters: Self.logParameters(invocation.call.parameters))
        order.append(invocation.executionID)
        revision += 1
    }

    @discardableResult
    mutating func transition(
        _ id: String, to phase: ActionExecutionRecord.Phase,
        completion: ActionCompletion? = nil, failure: ActionExecutionRecord.Failure? = nil,
        failureDescription: String? = nil
    ) -> Bool {
        guard var record = records[id], !record.isTerminal, record.phase != phase else { return false }
        // A late start cannot undo a cancellation request.
        guard !(record.phase == .cancelling && phase == .running) else { return false }
        record.phase = phase
        if phase == .running { record.startedAt = .now }
        record.completion = completion
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

    private static let credentialFields: Set<String> = [
        "key", "apikey", "token", "accesstoken", "refreshtoken", "authorization", "password",
        "secret", "clientsecret", "credential", "credentials", "cookie",
    ]

    private static func logParameters(_ parameters: [String: String]) -> [String: String] {
        parameters.reduce(into: [:]) { result, entry in
            let (name, value) = entry
            let normalized = name.lowercased().filter(\.isLetter)
            result[name] =
                credentialFields.contains(normalized)
                ? "[redacted]" : ActionExecutionRecord.logPreview(value, maximumUTF8Bytes: 2048)
        }
    }

    func snapshot() -> ActionExecutionSnapshot {
        ActionExecutionSnapshot(
            revision: revision, records: order.compactMap { records[$0] }, evictedCount: evictedCount)
    }
}

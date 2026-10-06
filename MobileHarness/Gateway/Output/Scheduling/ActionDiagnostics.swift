import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts

/// Payload-free execution history. The scheduler owns mutation; snapshots are immutable values.
public struct ActionDiagnostics: Sendable {
    public enum Phase: String, Sendable { case admitted, started, succeeded, failed, cancelled }
    public enum Effect: String, Sendable {
        case notStarted
        /// The handler entered execution; failure/cancellation does not establish rollback.
        case unknown
        /// Only the registered completion contract, never a claim of physical or rendered completion.
        case contractCompleted
    }

    public struct Record: Sendable {
        public let executionID: UUID
        public let path: ActionPath
        public let source: AgentID
        public let sessionID: UUID
        public let inputID: UUID
        public let channel: String
        public let kind: ActionBinding.Kind
        public let phase: Phase
        public let effect: Effect
        public let time: ContinuousClock.Instant
    }

    public struct Snapshot: Sendable {
        public let records: [Record]
        public let evictedCount: UInt64
    }

    private var records: [Record] = []
    private var next = 0
    private var evictedCount: UInt64 = 0
    public let capacity: Int

    public init(capacity: Int = 256) {
        precondition((1...4096).contains(capacity))
        self.capacity = capacity
    }

    public mutating func record(
        _ invocation: ScheduledAction, kind: ActionBinding.Kind, phase: Phase, effect: Effect
    ) {
        let record = Record(
            executionID: invocation.executionID, path: invocation.call.actionPath,
            source: invocation.envelope.source, sessionID: invocation.envelope.sessionID,
            inputID: invocation.envelope.inputID, channel: invocation.channel,
            kind: kind, phase: phase, effect: effect, time: .now)
        if records.count < capacity {
            records.append(record)
        } else {
            records[next] = record
            next = (next + 1) % capacity
            evictedCount &+= 1
        }
    }

    public func snapshot() -> Snapshot {
        Snapshot(records: Array(records[next...]) + Array(records[..<next]), evictedCount: evictedCount)
    }
}

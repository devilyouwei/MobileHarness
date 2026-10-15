import Foundation

/// Admission diagnostics, independent of publisher responses and Agent business completion.
public struct SignalTraceRecord: Identifiable, Sendable {
    public enum Mode: String, Sendable { case publish, send, feedback }
    public enum Phase: String, Sendable {
        case delivering, accepted, partial, rejected, suppressed, dropped, unobserved
    }
    public struct Branch: Sendable, Equatable {
        public let target: AgentID
        public var phase: Phase
        public var reason: String?
        public init(target: AgentID, phase: Phase = .delivering, reason: String? = nil) {
            self.target = target
            self.phase = phase
            self.reason = reason.map { String($0.prefix(512)) }
        }
    }
    public let aggregates: Bool
    public let id: String
    public let source: String
    public let contract: String
    public let sessionID: String
    public let rootID: String
    public let parentID: String?
    public let taskScope: AgentTaskScope?
    public let task: AgentTaskSignal?
    public let summary: String
    public let mode: Mode
    public let time: Date
    public var updatedAt: Date
    public var branches: [Branch]
    public var phase: Phase
    public var reason: String?
    public var count: Int
    public init(
        input: AgentInput, mode: Mode, targets: [AgentID], summary: String, aggregates: Bool = false, time: Date = .now
    ) {
        self.aggregates = aggregates
        id = input.id
        source = String(input.metadata.source.prefix(64))
        contract = String(input.metadata.contract.prefix(64))
        sessionID = input.sessionID
        rootID = input.metadata.rootID
        parentID = input.metadata.parentID
        taskScope = input.taskScope
        if case .observation(let message) = input.payload,
            let signal = message.content(as: AgentTaskSignal.self), signal.data.count <= 65_536
        {
            task = signal
        } else {
            task = nil
        }
        self.summary = String(summary.prefix(256))
        self.mode = mode
        self.time = time
        updatedAt = time
        branches = Array(Set(targets)).sorted { $0.rawValue < $1.rawValue }.prefix(16).map { Branch(target: $0) }
        phase = targets.isEmpty ? .unobserved : .delivering
        count = 1
    }
}

public struct SignalTraceSnapshot: Sendable {
    public let revision: UInt64
    public let records: [SignalTraceRecord]
    public let evictedCount: UInt64
    public init(revision: UInt64, records: [SignalTraceRecord], evictedCount: UInt64 = 0) {
        self.revision = revision
        self.records = records
        self.evictedCount = evictedCount
    }
}

import Foundation

/// Read-only execution observation, independent of Agent result delivery and device telemetry.
public struct ActionExecutionRecord: Identifiable, Equatable, Sendable {
    public enum Phase: String, Sendable { case queued, running, cancelling, succeeded, failed, cancelled }
    public enum Semantics: String, Sendable { case finite, state, activityStart, activityUpdate, activityStop }
    public struct Failure: RawRepresentable, Equatable, Sendable {
        public let rawValue: String
        public init(rawValue: String) {
            precondition(!rawValue.isEmpty && rawValue.utf8.count <= 64)
            self.rawValue = rawValue
        }
        public static let operationFailed = Self(rawValue: "operationFailed")
        public static let resourceUnavailable = Self(rawValue: "resourceUnavailable")
    }
    public let id: UUID
    public let path: ActionPath
    /// Copied from the registered definition at admission, not resolved by presentation.
    public let displayName: String
    public let source: AgentID
    public let sessionID: UUID
    public let inputID: UUID
    public let channel: String
    public let semantics: Semantics
    public var phase: Phase
    public let admittedAt: Date
    public var startedAt: Date?
    public var endedAt: Date?
    public var failure: Failure?
    public var failureDescription: String?
    public var completion: AgentActionCompletion?
    public var isTerminal: Bool { phase == .succeeded || phase == .failed || phase == .cancelled }

    public init(
        id: UUID, path: ActionPath, displayName: String, source: AgentID, sessionID: UUID, inputID: UUID,
        channel: String,
        semantics: Semantics, phase: Phase = .queued, admittedAt: Date = .now, startedAt: Date? = nil,
        endedAt: Date? = nil, failure: Failure? = nil, completion: AgentActionCompletion? = nil,
        failureDescription: String? = nil
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName
        self.source = source
        self.sessionID = sessionID
        self.inputID = inputID
        self.channel = channel
        self.semantics = semantics
        self.phase = phase
        self.admittedAt = admittedAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.failureDescription = failureDescription.map { String($0.prefix(512)) }
        self.failure = failure
        self.completion = completion
    }
}

public struct ActionExecutionSnapshot: Sendable {
    public let revision: UInt64
    public let records: [ActionExecutionRecord]
    public let evictedCount: UInt64
    public init(revision: UInt64, records: [ActionExecutionRecord], evictedCount: UInt64 = 0) {
        self.revision = revision
        self.records = records
        self.evictedCount = evictedCount
    }
}

/// Output failure observation, distinct from scheduled Action execution and Agent-facing results.
public struct OutputFailureRecord: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let source: AgentID
    public let title: String
    public let message: String
    public let failureCode: String?
    public let time: Date
    public init(
        id: UUID = UUID(), source: AgentID, title: String, message: String, time: Date = Date(),
        failureCode: String? = nil
    ) {
        self.id = id
        self.source = source
        self.title = String(title.prefix(128))
        self.message = String(message.prefix(512))
        precondition(failureCode.map { !$0.isEmpty && $0.utf8.count <= 64 } ?? true)
        self.failureCode = failureCode
        self.time = time
    }
}
public struct OutputFailureSnapshot: Sendable {
    public let revision: UInt64
    public let records: [OutputFailureRecord]
    public let evictedCount: UInt64
    public init(revision: UInt64, records: [OutputFailureRecord], evictedCount: UInt64) {
        self.revision = revision
        self.records = records
        self.evictedCount = evictedCount
    }
}

import Foundation

/// Read-only execution observation, independent of Agent result delivery and device telemetry.
public struct ActionExecutionRecord: Identifiable, Equatable, Sendable {
    public enum Phase: String, Sendable { case queued, running, cancelling, succeeded, failed, cancelled }
    public enum Semantics: String, Sendable { case finite, state, activityStart, activityUpdate, activityStop }
    public enum Failure: String, Sendable {
        case operationFailed, resourceUnavailable, disconnected, busy, background, invalidPose
        case unconfirmed, controlNotReady, feedbackTimeout, completionTimeout, invalidArguments
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
    public var completion: ActionCompletion?
    public var isTerminal: Bool { phase == .succeeded || phase == .failed || phase == .cancelled }

    public init(
        id: UUID, path: ActionPath, displayName: String, source: AgentID, sessionID: UUID, inputID: UUID,
        channel: String,
        semantics: Semantics, phase: Phase = .queued, admittedAt: Date = .now, startedAt: Date? = nil,
        endedAt: Date? = nil, failure: Failure? = nil, completion: ActionCompletion? = nil,
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

/// Optional machine-readable failure classification; presentation uses the thrown error description.
public protocol ActionExecutionFailureProviding: Error {
    var actionExecutionFailure: ActionExecutionRecord.Failure { get }
}

import Foundation

/// Bounded leaf results. A child path identifies its location in a nested composition.
public struct ActionReport: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public enum Status: String, Sendable { case succeeded, failed, cancelled, notStarted }
        public enum Code: String, Sendable {
            case targetNotReached, feedbackLost, disconnected, sendingFailed, timedOut
            case invalidArguments, unavailable, handlerFailed, cancelled, resultCapacityExceeded
        }
        public let path: String
        public let status: Status
        public let code: Code?
        /// Producer-owned scalar details; framework transports keys without interpreting them.
        public let details: [String: String]
        public init(
            path: String, status: Status, code: Code? = nil, details: [String: String] = [:]
        ) {
            self.path = path
            self.status = status
            self.code = code
            precondition(
                details.count <= 16
                    && details.allSatisfy { !$0.key.isEmpty && $0.key.utf8.count <= 64 && $0.value.utf8.count <= 512 })
            self.details = details
        }
    }
    public enum ValidationError: Error { case capacity, invalidPath }
    public let entries: [Entry]
    /// Execution-level failure is separate from bounded child results; no child is discarded.
    public let executionFailure: Entry.Code?
    private init(validatedEntries: [Entry], executionFailure: Entry.Code? = nil) {
        entries = validatedEntries
        self.executionFailure = executionFailure
    }
    public static func executionFailed(_ code: Entry.Code) -> Self {
        Self(validatedEntries: [], executionFailure: code)
    }
    public static func failure(_ code: Entry.Code) -> Self {
        Self(validatedEntries: [.init(path: "root", status: code == .cancelled ? .cancelled : .failed, code: code)])
    }
    public static func code(for error: any Error) -> Entry.Code {
        if error is CancellationError { return .cancelled }
        switch (error as? any ActionExecutionFailureProviding)?.actionExecutionFailure {
        case .feedbackTimeout: return .feedbackLost
        case .disconnected: return .disconnected
        case .completionTimeout: return .targetNotReached
        case .invalidArguments, .invalidPose: return .invalidArguments
        case .busy, .controlNotReady, .resourceUnavailable, .background: return .unavailable
        default: return .handlerFailed
        }
    }
    public init(entries: [Entry]) throws {
        guard entries.count <= 256 else { throw ValidationError.capacity }
        guard entries.allSatisfy({ !$0.path.isEmpty && $0.path.utf8.count <= 128 }) else {
            throw ValidationError.invalidPath
        }
        self.executionFailure = nil
        self.entries = entries
    }
    public func withExecutionFailure(_ code: Entry.Code) -> Self {
        Self(validatedEntries: entries, executionFailure: code)
    }
    /// Retain child outcomes while attaching an exception that happened after they were recorded.
    public func recordingFailure(_ error: any Error) -> Self {
        let reported = (error as? any ActionReportProviding)?.actionReport
        let code =
            reported?.executionFailure
            ?? (reported?.isCancelled == true ? .cancelled : reported?.entries.first { $0.status == .failed }?.code)
            ?? Self.code(for: error)
        return withExecutionFailure(code)
    }
    public var hasFailures: Bool { executionFailure != nil || entries.contains { $0.status == .failed } }
    public var isCancelled: Bool {
        executionFailure == .cancelled || entries.contains { $0.status == .cancelled || $0.code == .cancelled }
    }
    public var status: ActionStatus {
        if isCancelled && executionFailure != .timedOut { return .cancelled }
        if hasFailures { return entries.contains { $0.status == .succeeded } ? .partialFailure : .failed }
        return .succeeded
    }
}

/// Adapters can preserve a completed report through existing throwing handler boundaries.
public protocol ActionReportProviding: Error { var actionReport: ActionReport { get } }
public struct ActionReportedError: Error, Sendable, ActionReportProviding {
    public let actionReport: ActionReport
    public init(_ report: ActionReport) { actionReport = report }
}

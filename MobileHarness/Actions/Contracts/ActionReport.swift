import Foundation

/// Bounded leaf results. A child path identifies its location in a nested composition.
public struct ActionReport: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public enum Status: String, Sendable { case succeeded, failed, cancelled, notStarted }
        /// Bounded producer-owned code; Runtime interprets generic execution outcomes only.
        public struct Code: RawRepresentable, Equatable, Hashable, Sendable {
            public let rawValue: String
            public init(rawValue: String) {
                precondition(!rawValue.isEmpty && rawValue.utf8.count <= 64)
                self.rawValue = rawValue
            }
            public static let timedOut = Self(rawValue: "timedOut")
            public static let invalidArguments = Self(rawValue: "invalidArguments")
            public static let unavailable = Self(rawValue: "unavailable")
            public static let handlerFailed = Self(rawValue: "handlerFailed")
            public static let cancelled = Self(rawValue: "cancelled")
            public static let resultCapacityExceeded = Self(rawValue: "resultCapacityExceeded")
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
    public let failureDescription: String?
    private init(validatedEntries: [Entry], executionFailure: Entry.Code? = nil, failureDescription: String? = nil) {
        entries = validatedEntries
        self.executionFailure = executionFailure
        self.failureDescription = failureDescription.map { String($0.prefix(512)) }
    }
    public static func executionFailed(_ code: Entry.Code) -> Self {
        Self(validatedEntries: [], executionFailure: code)
    }
    public static func failure(_ code: Entry.Code) -> Self {
        Self(validatedEntries: [.init(path: "root", status: code == .cancelled ? .cancelled : .failed, code: code)])
    }
    public static func description(for error: any Error) -> String {
        String(((error as? any LocalizedError)?.errorDescription ?? String(describing: error)).prefix(512))
    }
    public static func code(for error: any Error) -> Entry.Code {
        if error is CancellationError { return .cancelled }
        if let producer = error as? any ActionReportFailureProviding { return producer.actionReportCode }
        if let producer = error as? any ActionExecutionFailureProviding {
            return .init(rawValue: producer.executionFailureCode.rawValue)
        }
        return .handlerFailed
    }
    public init(entries: [Entry]) throws {
        guard entries.count <= 256 else { throw ValidationError.capacity }
        guard entries.allSatisfy({ !$0.path.isEmpty && $0.path.utf8.count <= 128 }) else {
            throw ValidationError.invalidPath
        }
        self.executionFailure = nil
        self.failureDescription =
            entries.first { $0.status == .failed && $0.details["failureDescription"] != nil }?.details[
                "failureDescription"]
        self.entries = entries
    }
    public func withExecutionFailure(_ code: Entry.Code, description: String? = nil) -> Self {
        Self(validatedEntries: entries, executionFailure: code, failureDescription: description ?? failureDescription)
    }
    /// Retain child outcomes while attaching an exception that happened after they were recorded.
    public func recordingFailure(_ error: any Error) -> Self {
        let reported = (error as? any ActionReportProviding)?.actionReport
        let code =
            reported?.executionFailure
            ?? (reported?.isCancelled == true ? .cancelled : reported?.entries.first { $0.status == .failed }?.code)
            ?? Self.code(for: error)
        return withExecutionFailure(code, description: reported?.failureDescription ?? Self.description(for: error))
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

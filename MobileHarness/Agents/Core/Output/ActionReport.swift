import Foundation

/// Bounded leaf results. A child path identifies its location in a nested composition.
public struct AgentActionReport: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public enum Status: String, Sendable { case succeeded, failed, cancelled, notStarted }
        public struct Code: RawRepresentable, Equatable, Sendable {
            public let rawValue: String
            public init(rawValue: String) {
                precondition(!rawValue.isEmpty && rawValue.utf8.count <= 64)
                self.rawValue = rawValue
            }
            public static let timedOut = Self(rawValue: "timedOut")
            public static let handlerFailed = Self(rawValue: "handlerFailed")
            public static let cancelled = Self(rawValue: "cancelled")
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
    public init(delivering entries: [Entry], executionFailure: Entry.Code?) {
        precondition(entries.count <= 256 && entries.allSatisfy { !$0.path.isEmpty && $0.path.utf8.count <= 128 })
        self.entries = entries
        self.executionFailure = executionFailure
    }
    public static func executionFailed(_ code: Entry.Code) -> Self {
        Self(validatedEntries: [], executionFailure: code)
    }
    public static func failure(_ code: Entry.Code) -> Self {
        Self(validatedEntries: [.init(path: "root", status: code == .cancelled ? .cancelled : .failed, code: code)])
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
    public var hasFailures: Bool { executionFailure != nil || entries.contains { $0.status == .failed } }
    public var isCancelled: Bool {
        executionFailure == .cancelled || entries.contains { $0.status == .cancelled || $0.code == .cancelled }
    }
    public var status: ActionResult.Status {
        if isCancelled && executionFailure != .timedOut { return .cancelled }
        if hasFailures { return entries.contains { $0.status == .succeeded } ? .partialFailure : .failed }
        return .succeeded
    }
}

import Foundation

/// Bounded leaf results. A child path identifies its location in a nested composition.
public struct AgentActionReport: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public enum Status: String, Sendable { case succeeded, failed, cancelled, notStarted }
        public enum Code: String, Sendable {
            case targetNotReached, feedbackLost, disconnected, sendingFailed, timedOut
            case invalidArguments, unavailable, handlerFailed, cancelled, resultCapacityExceeded
        }
        public let path: String
        public let status: Status
        public let code: Code?
        public let motor: Int?
        public let target: Int?
        public let observed: Int?
        public init(
            path: String, status: Status, code: Code? = nil, motor: Int? = nil,
            target: Int? = nil, observed: Int? = nil
        ) {
            self.path = path
            self.status = status
            self.code = code
            self.motor = motor
            self.target = target
            self.observed = observed
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
    public var isCancelled: Bool { entries.contains { $0.status == .cancelled || $0.code == .cancelled } }
    public var status: ActionResult.Status {
        if isCancelled && executionFailure != .timedOut { return .cancelled }
        if hasFailures { return entries.contains { $0.status == .succeeded } ? .partialFailure : .failed }
        return .succeeded
    }
}

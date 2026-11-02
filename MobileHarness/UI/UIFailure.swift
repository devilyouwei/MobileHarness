import Foundation

/// Module-owned error envelope. Presentation and transport policy belong to the caller.
public struct UIFailure: Error, Sendable, CustomStringConvertible {
    public enum Code: String, Sendable, CaseIterable {
        case cancelled, unavailable, stopped, busy, invalidInput, capacityExceeded, timedOut, missing, stale, conflict,
            forbidden
        case executionFailed = "execution.failed"
        case cleanupFailed = "cleanup.failed"
    }
    public struct Source: Sendable, Equatable {
        public let fileID: String
        public let function: String
        public let line: UInt
    }
    public let code: Code
    public let component: String
    public let operation: String
    public let message: String
    public let underlying: any Error
    public let cleanupErrors: [any Error]
    public let source: Source
    public var isCancellation: Bool { code == .cancelled && underlying is CancellationError && cleanupErrors.isEmpty }
    public var description: String {
        let cleanup = cleanupErrors.map { String(describing: $0) }.joined(separator: "; ")
        return "\(component).\(operation) [\(code.rawValue)]: \(message)"
            + (cleanupErrors.isEmpty ? "" : "; cleanup: \(cleanup)")
    }
    public init(
        component: String, operation: String, underlying: any Error,
        cleanupErrors: [any Error] = [], code: Code? = nil,
        fileID: String = #fileID, function: String = #function, line: UInt = #line
    ) {
        if let existing = underlying as? Self {
            self.code = cleanupErrors.isEmpty ? (code ?? existing.code) : .cleanupFailed
            self.component = existing.component
            self.operation = existing.operation
            message = existing.message
            self.underlying = existing.underlying
            self.cleanupErrors = existing.cleanupErrors + cleanupErrors
            source = existing.source
            return
        }
        self.code = cleanupErrors.isEmpty ? (code ?? Self.classify(underlying)) : .cleanupFailed
        self.component = component
        self.operation = operation
        message = String(describing: underlying)
        self.underlying = underlying
        self.cleanupErrors = cleanupErrors
        source = Source(fileID: fileID, function: function, line: line)
    }
    private static func classify(_ error: any Error) -> Code {
        if error is CancellationError { return .cancelled }
        guard let error = error as? UIContainerError else { return .executionFailed }
        switch error {
        case .unavailable: return .unavailable
        case .stopped: return .stopped
        case .stale: return .stale
        }
    }
}

public typealias UIFailureReporting = @Sendable (String, String, any Error) -> Void
public enum UIContainerError: Error, Sendable, Equatable { case unavailable, stopped, stale }

import Foundation

/// Gateway-owned lifecycle failure; presentation policy belongs to the host.
public struct GatewayFailure: Error, Sendable, CustomStringConvertible {
    public enum Code: String, Sendable {
        case cancelled, unavailable, stopped, conflict
        case executionFailed = "execution.failed"
        case cleanupFailed = "cleanup.failed"
    }
    public struct Source: Sendable {
        public let fileID: String
        public let function: String
        public let line: UInt
    }
    public let code: Code
    public let component: String
    public let operation: String
    public let underlying: any Error
    public let cleanupErrors: [any Error]
    public let source: Source
    public var isCancellation: Bool {
        code == .cancelled && underlying is CancellationError && cleanupErrors.isEmpty
    }
    public var description: String { "\(component).\(operation) [\(code.rawValue)]: \(underlying)" }
    public init(
        component: String = "root", operation: String, underlying: any Error,
        cleanupErrors: [any Error] = [], code: Code? = nil,
        fileID: String = #fileID, function: String = #function, line: UInt = #line
    ) {
        self.component = component
        self.operation = operation
        self.underlying = underlying
        self.cleanupErrors = cleanupErrors
        self.code =
            !cleanupErrors.isEmpty
            ? .cleanupFailed : (code ?? (underlying is CancellationError ? .cancelled : .executionFailed))
        source = Source(fileID: fileID, function: function, line: line)
    }
}

public enum GatewayContainerError: Error, Sendable { case unavailable, stopped, alreadyConfigured }

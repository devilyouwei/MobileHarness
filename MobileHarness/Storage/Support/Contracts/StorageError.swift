import Foundation

/// A native, nonblocking reporting port. The host owns transport and diagnostics retention.
public struct StorageFailureReporter: Sendable {
    private let receive: @Sendable (String, String, any Error) -> Void
    public init(receive: @escaping @Sendable (String, String, any Error) -> Void = { _, _, _ in }) {
        self.receive = receive
    }
    public func report(_ component: String, _ operation: String, _ error: any Error) {
        guard !(error is CancellationError) else { return }
        receive(component, operation, error)
    }
}

public enum StorageError: Error, Equatable, Sendable {
    case busy, capacityExceeded, missing, timedOut, duplicate, closed, expired, forbidden
}

public enum DocumentStorageError: Error, Equatable, Sendable {
    case invalidConfiguration, capacityExceeded, unsupportedVersion, conflict, invalidFile
}

public enum RecordStorageError: Error, Equatable, Sendable {
    case invalidID, missingRecord, busy, invalidRecord, conflict, notReady, closed
}

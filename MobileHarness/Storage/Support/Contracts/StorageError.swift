public enum StorageError: Error, Equatable, Sendable {
    case busy, capacityExceeded, missing, timedOut, duplicate, closed, expired, forbidden
}

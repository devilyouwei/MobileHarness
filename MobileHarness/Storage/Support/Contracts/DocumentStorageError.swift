public enum DocumentStorageError: Error, Equatable, Sendable {
    case invalidConfiguration, capacityExceeded, unsupportedVersion, conflict, invalidFile
}

public enum RecordStorageError: Error, Sendable {
    case invalidID, missingRecord, busy, invalidRecord, conflict, notReady, closed
}

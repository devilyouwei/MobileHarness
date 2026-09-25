/// Exclusive operation admission: one active operation, no waiting queue.
/// Reject overlapping operations explicitly. This is not a model or request scheduler.
public actor OperationAdmission {
    private var active = false
    public init() {}
    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard !active else { throw CapabilityError.inputBusy }
        active = true
        defer { active = false }
        let result = try await operation()
        try Task.checkCancellation()
        return result
    }
}

/// Original module cleanup errors are retained individually; lifecycle adapters do not fabricate success.
public struct NativeCleanupFailure: Error {
    public let errors: [any Error]
    public init(errors: [any Error]) { self.errors = errors }
}

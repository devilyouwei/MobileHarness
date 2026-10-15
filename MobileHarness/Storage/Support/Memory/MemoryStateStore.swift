import Synchronization

/// Exactly one owned snapshot, with no encoding, I/O, queue or restart durability.
public final class MemoryStateStore<Value: Sendable>: StateRepository {
    private let state: Mutex<Value>
    public init(_ initial: Value) { state = Mutex(initial) }
    public func read() -> Value { state.withLock { $0 } }
    public func replace(_ value: Value) { state.withLock { $0 = value } }
}

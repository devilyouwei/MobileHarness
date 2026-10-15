/// A single process-local snapshot. The owner validates size and transaction boundaries.
/// Read values are snapshots; identity references use stable IDs rather than escaped mutable objects.
public protocol StateRepository<Value>: Sendable {
    associatedtype Value: Sendable
    func read() -> Value
    func replace(_ value: Value)
}

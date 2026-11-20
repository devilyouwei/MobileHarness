import Foundation
import Synchronization

/// External Signal source (never routed through Gateway); ModelKit owns this contract independently of other modules.
public protocol SignalListener<Element>: AsyncSequence, Sendable where Element: Sendable {
    var producer: String { get }
    func cancel() async
    func join() async
}
public enum ModelSignalListenerError: Error, Sendable { case duplicateConsumer }
private final class ModelListenerIteratorClaim: Sendable {
    private let claimed = Mutex(false)
    func take() -> Bool {
        claimed.withLock {
            if $0 { return false }
            $0 = true
            return true
        }
    }
}
private actor ModelSignalDetachment {
    let operation: @Sendable () async -> Void
    var task: Task<Void, Never>?
    init(_ operation: @escaping @Sendable () async -> Void) { self.operation = operation }
    func close() async {
        if let task {
            await task.value
            return
        }
        let task = Task { await operation() }
        self.task = task
        await task.value
    }
}
public struct StateSignalListener<Value: Sendable>: SignalListener {
    public typealias Element = Value
    public let producer: String
    public let generation: UUID
    private let stream: AsyncStream<Value>
    private let claim = ModelListenerIteratorClaim()
    private let detachment: ModelSignalDetachment
    public init(
        producer: String, generation: UUID, stream: AsyncStream<Value>, detach: @escaping @Sendable () async -> Void
    ) {
        self.producer = producer
        self.generation = generation
        self.stream = stream
        detachment = ModelSignalDetachment(detach)
    }
    public struct Iterator: AsyncIteratorProtocol {
        public typealias Element = Value
        private var base: AsyncStream<Value>.Iterator
        private let authorized: Bool
        fileprivate init(base: AsyncStream<Value>.Iterator, authorized: Bool) {
            self.base = base
            self.authorized = authorized
        }
        public mutating func next(isolation actor: isolated (any Actor)? = #isolation) async throws -> Value? {
            guard authorized else { throw ModelSignalListenerError.duplicateConsumer }
            return await base.next(isolation: actor)
        }
    }
    public func makeAsyncIterator() -> Iterator { .init(base: stream.makeAsyncIterator(), authorized: claim.take()) }
    public func cancel() async { await detachment.close() }
    public func join() async { await detachment.close() }
}

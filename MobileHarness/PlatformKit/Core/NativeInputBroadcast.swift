import Foundation
import Synchronization

public enum NativeSubscriptionError: Error, Sendable { case capacityExceeded, overflow }

/// Native broadcast, independent of message transport. No subscriber can consume another's packets.
public final class NativeInputBroadcast<Value: Sendable>: Sendable {
    public enum Policy: Sendable { case latest, ordered }
    private struct Entry: Sendable {
        let continuation: AsyncThrowingStream<Value, any Error>.Continuation
        let policy: Policy
    }
    private struct State: Sendable {
        var entries: [String: Entry] = [:]
        var replacements: UInt64 = 0
    }
    private let state = Mutex(State())
    private let onFailure: @Sendable (any Error) -> Void
    public init(onFailure: @escaping @Sendable (any Error) -> Void = { _ in }) { self.onFailure = onFailure }
    deinit { finish() }
    public var replacements: UInt64 { state.withLock { $0.replacements } }
    public func listen(_ policy: Policy, producer: String = "platform.native") throws -> StateSignalListener<Value> {
        let (stream, id) = try makeSubscription(policy)
        return StateSignalListener(
            source: .init(
                producer: producer, generation: id, delivery: policy == .latest ? .latest : .ordered(capacity: 64)),
            stream: stream, detach: { [weak self] in self?.detach(id) })
    }
    public func listenMedia(_ policy: Policy, producer: String) throws -> MediaSignalListener<Value> {
        let (stream, id) = try makeSubscription(policy)
        return MediaSignalListener(
            source: .init(
                producer: producer, generation: id, delivery: policy == .latest ? .latest : .ordered(capacity: 64)),
            stream: stream, detach: { [weak self] in self?.detach(id) })
    }
    private func detach(_ id: String) {
        let entry = state.withLock { $0.entries.removeValue(forKey: id) }
        entry?.continuation.finish()
    }
    private func makeSubscription(_ policy: Policy) throws -> (AsyncThrowingStream<Value, any Error>, String) {
        let pair = AsyncThrowingStream<Value, any Error>.makeStream(
            bufferingPolicy: policy == .latest ? .bufferingNewest(1) : .bufferingOldest(64))
        let id = UUID().uuidString
        pair.continuation.onTermination = { [weak self] _ in
            self?.state.withLock { $0.entries[id] = nil }
        }
        try state.withLock {
            guard $0.entries.count < 16 else { throw NativeSubscriptionError.capacityExceeded }
            $0.entries[id] = Entry(continuation: pair.continuation, policy: policy)
        }
        return (pair.stream, id)
    }
    public func send(_ value: Value) {
        let entries = state.withLock { $0.entries }
        for (id, entry) in entries {
            if case .dropped = entry.continuation.yield(value) {
                if entry.policy == .ordered {
                    state.withLock { $0.entries[id] = nil }
                    entry.continuation.finish(throwing: NativeSubscriptionError.overflow)
                    onFailure(NativeSubscriptionError.overflow)
                } else {
                    state.withLock { if $0.replacements < UInt64.max { $0.replacements += 1 } }
                }
            }
        }
    }
    public func finish(throwing error: (any Error)? = nil) {
        let entries = state.withLock {
            let entries = $0.entries
            $0.entries.removeAll()
            return entries
        }
        for entry in entries.values { entry.continuation.finish(throwing: error) }
    }
}

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
    public init() {}
    deinit { finish() }
    public var replacements: UInt64 { state.withLock { $0.replacements } }
    public func subscribe(_ policy: Policy) throws -> AsyncThrowingStream<Value, any Error> {
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
        return pair.stream
    }
    public func send(_ value: Value) {
        let entries = state.withLock { $0.entries }
        for (id, entry) in entries {
            if case .dropped = entry.continuation.yield(value) {
                if entry.policy == .ordered {
                    state.withLock { $0.entries[id] = nil }
                    entry.continuation.finish(throwing: NativeSubscriptionError.overflow)
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

/// Callback-owned generation fence; no forwarding task, executor hop or additional queue.
public final class NativeInputSession<Value: Sendable>: Sendable {
    private let active = Mutex(true)
    private let broadcast: NativeInputBroadcast<Value>
    public init(broadcast: NativeInputBroadcast<Value>) { self.broadcast = broadcast }
    public func send(_ value: Value) {
        active.withLock { if $0 { broadcast.send(value) } }
    }
    public func finish(throwing error: (any Error)? = nil) {
        active.withLock {
            guard $0 else { return }
            $0 = false
            broadcast.finish(throwing: error)
        }
    }
    deinit { finish() }
}

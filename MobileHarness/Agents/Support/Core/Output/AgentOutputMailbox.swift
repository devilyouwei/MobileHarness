import Foundation

/// One pull consumer, bounded discrete actions, and explicit latest-state replacement keys.
/// The producer supplies the keys; Core never interprets business function addresses.
public final class AgentOutputMailbox: @unchecked Sendable {
    private struct Entry {
        let envelope: OutputEnvelope
        let key: String?
    }
    private struct State {
        var entries: [Entry] = []
        var waiting: CheckedContinuation<OutputEnvelope?, Never>?
        var closed = false
    }
    private let lock = NSLock()
    private var state = State()
    private let capacity: Int
    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }
    public var stream: AsyncStream<OutputEnvelope> {
        AsyncStream(unfolding: { [self] in await next() }, onCancel: { [self] in close() })
    }
    /// Replacing a declared state returns the old envelope so its owner can record coalescing.
    @discardableResult public func admit(_ envelope: OutputEnvelope, replacing key: String? = nil) throws
        -> OutputEnvelope?
    {
        let result: (OutputEnvelope?, CheckedContinuation<OutputEnvelope?, Never>?) = try lock.withLock {
            guard !state.closed else { throw CommunicationError.scopeClosed }
            if let waiting = state.waiting {
                state.waiting = nil
                return (nil, waiting)
            }
            if let key, let index = state.entries.firstIndex(where: { $0.key == key }) {
                let previous = state.entries.remove(at: index).envelope
                state.entries.append(Entry(envelope: envelope, key: key))
                return (previous, nil)
            }
            guard state.entries.count < capacity else { throw CommunicationError.capacityExceeded }
            state.entries.append(Entry(envelope: envelope, key: key))
            return (nil, nil)
        }
        result.1?.resume(returning: envelope)
        return result.0
    }
    public func close(terminal: OutputEnvelope? = nil) {
        let waiting = lock.withLock {
            guard !state.closed else { return nil as CheckedContinuation<OutputEnvelope?, Never>? }
            state.closed = true
            if let terminal {
                // A terminal event may replace state snapshots, never an accepted discrete Action.
                state.entries.removeAll { $0.key != nil }
                state.entries.append(Entry(envelope: terminal, key: nil))
            }
            let waiting = state.waiting
            state.waiting = nil
            return waiting
        }
        waiting?.resume(returning: terminal)
    }
    private func next() async -> OutputEnvelope? {
        if Task.isCancelled { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: (Bool, OutputEnvelope?) = lock.withLock {
                    if !state.entries.isEmpty { return (true, state.entries.removeFirst().envelope) }
                    if state.closed || Task.isCancelled { return (true, nil) }
                    guard state.waiting == nil else { return (true, nil) }
                    state.waiting = continuation
                    return (false, nil)
                }
                if immediate.0 { continuation.resume(returning: immediate.1) }
            }
        } onCancel: {
            close()
        }
    }
}

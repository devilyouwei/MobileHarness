import Synchronization

/// One worker per request. Owners join work and release leases after native execution exits.
public final class InferenceTaskControl: Sendable {
    private struct State {
        var installed = false
        var cancelled = false
        var finished = false
        var task: Task<Void, Never>?
    }
    private let state = Mutex(State())

    public init() {}

    /// Cancellation before installation reaches the worker. Duplicate workers are rejected.
    public func install(_ task: Task<Void, Never>) throws {
        let result = state.withLock { value -> (accepted: Bool, cancelled: Bool) in
            guard !value.installed else { return (false, true) }
            value.installed = true
            if !value.finished { value.task = task }
            return (true, value.cancelled)
        }
        if result.cancelled { task.cancel() }
        guard result.accepted else { throw CapabilityError.inputBusy }
    }

    /// A fast worker may finish before installation; its handle must never be retained again.
    public func finish() {
        state.withLock { value in
            value.finished = true
            value.task = nil
        }
    }

    public var isCancelled: Bool { state.withLock { $0.cancelled } }

    public func waitForCompletion() async {
        let task = state.withLock { $0.task }
        await task?.value
    }

    public func cancel() {
        let task = state.withLock { value in
            value.cancelled = true
            return value.task
        }
        task?.cancel()
    }
}

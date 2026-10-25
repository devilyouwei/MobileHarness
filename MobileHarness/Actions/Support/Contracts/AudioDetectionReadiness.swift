import Foundation
import Synchronization

/// Request-scoped capture readiness. Contains no media and has no global registration.
public final class AudioDetectionReadiness: Sendable {
    private struct State {
        var active = true
        var completed = false
    }
    private let state = Mutex(State())
    public var isActive: Bool { state.withLock { $0.active } }
    public var completed: Bool { state.withLock { $0.completed } }
    public func cancel(completed: Bool = false) {
        state.withLock {
            $0.active = false
            $0.completed = completed
        }
    }
    public let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    public init() {
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = stream.stream
        continuation = stream.continuation
    }
    public func ready() {
        continuation.yield(())
        continuation.finish()
    }
    public func finish() {
        state.withLock { $0.active = false }
        continuation.finish()
    }
}

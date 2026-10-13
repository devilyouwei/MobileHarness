import Foundation
import Synchronization

enum AudioCaptureReadinessError: Error, Equatable {
    case alreadyWaiting
}

/// One startup waiter and one terminal result. A running session alone does not prove PCM delivery.
final class AudioCaptureReadiness: Sendable {
    private struct State {
        var claimed = false
        var result: Result<Void, any Error>?
        var waiter: CheckedContinuation<Void, any Error>?
    }
    private let state = Mutex(State())

    func resolve(_ result: Result<Void, any Error>) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(with: result)
    }

    func wait() async throws {
        let admitted = state.withLock { state in
            guard !state.claimed else { return false }
            state.claimed = true
            return true
        }
        guard admitted else { throw AudioCaptureReadinessError.alreadyWaiting }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
                let result = state.withLock { state -> Result<Void, any Error>? in
                    if let result = state.result { return result }
                    state.waiter = waiter
                    return nil
                }
                if let result { waiter.resume(with: result) }
            }
            try Task.checkCancellation()
        } onCancel: {
            self.resolve(.failure(CancellationError()))
        }
    }
}

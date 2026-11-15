import Foundation
import Synchronization

enum AudioCaptureReadinessError: Error, Equatable {
    case alreadyWaiting
    case timedOut
    case configurationChanged
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

    func wait(timeout: Duration = .seconds(10)) async throws {
        let admitted = state.withLock { state in
            guard !state.claimed else { return false }
            state.claimed = true
            return true
        }
        guard admitted else { throw AudioCaptureReadinessError.alreadyWaiting }
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self.resolve(.failure(AudioCaptureReadinessError.timedOut))
                }
                defer { group.cancelAll() }
                try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
                    let result = state.withLock { state -> Result<Void, any Error>? in
                        if let result = state.result { return result }
                        state.waiter = waiter
                        return nil
                    }
                    if let result { waiter.resume(with: result) }
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            self.resolve(.failure(CancellationError()))
        }
    }
}

/// Notification callbacks only retire one capture; graph teardown stays on its native actor.
final class AudioCaptureConfigurationGate: Sendable {
    private struct State {
        var active = true
        var changed = false
    }
    private let state = Mutex(State())
    private let readiness: AudioCaptureReadiness
    private let source: MicrophoneCapture

    init(readiness: AudioCaptureReadiness, source: MicrophoneCapture) {
        self.readiness = readiness
        self.source = source
    }

    func configurationChanged(engineRunning: Bool, formatMatches: Bool) {
        guard !engineRunning || !formatMatches else { return }
        state.withLock { state in
            guard state.active, !state.changed else { return }
            state.changed = true
            readiness.resolve(.failure(AudioCaptureReadinessError.configurationChanged))
            source.finish(throwing: AudioIOError.runtimeFailed)
        }
    }

    func check() throws {
        if state.withLock({ $0.changed }) { throw AudioCaptureReadinessError.configurationChanged }
    }

    func invalidate() { state.withLock { $0.active = false } }
}

struct AudioCaptureStartupRecovery {
    private var remaining = 1
    mutating func admit(_ error: any Error) -> Bool {
        guard remaining > 0, error as? AudioCaptureReadinessError == .configurationChanged else { return false }
        remaining -= 1
        return true
    }
}

import Foundation
import FunctionContracts
import PlatformKit
import Synchronization
import UI

@MainActor public final class AudioDetectionPresentation {
    private let state: any AudioDetectionPresenting
    private let endpoint: any AudioDetectionRunning
    private var task: Task<Void, any Error>?
    private var readiness: AudioDetectionReadiness?
    public init(state: any AudioDetectionPresenting, endpoint: any AudioDetectionRunning) {
        self.state = state
        self.endpoint = endpoint
    }
    public func run(readiness: AudioDetectionReadiness) async throws {
        guard task == nil else { throw AudioDetectionError.busy }
        try state.requirePresentation()
        state.present(.snapshot(AudioDetectionSnapshot()))
        state.present(.error(nil))
        state.present(.phase(.preparing))
        self.readiness = readiness
        let operation = Task { [state, endpoint] in
            let refresh = Task {
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(100))
                        try Task.checkCancellation()
                        state.refresh()
                    }
                } catch {}
            }
            var failure: (any Error)?
            do {
                try await endpoint.run { snapshot in
                    guard readiness.isActive, state.isPresentationAvailable, !Task.isCancelled else { return }
                    state.present(.snapshot(snapshot))
                    state.refresh()
                    if snapshot.capturedAt != nil {
                        state.present(.phase(.running))
                        readiness.ready()
                    }
                }
                try Task.checkCancellation()
                state.present(.phase(.finished))
            } catch {
                failure = error
                if error is CancellationError {
                    state.present(.phase(readiness.completed ? .finished : .stopped))
                } else {
                    state.present(.error("检测失败：" + error.localizedDescription))
                    state.present(.phase(.failed))
                }
            }
            refresh.cancel()
            await refresh.value
            state.present(.level(0))
            state.clearDirection()
            readiness.finish()
            if let failure { throw failure }
        }
        task = operation
        defer {
            task = nil
            self.readiness = nil
        }
        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            readiness.cancel(completed: readiness.completed)
            operation.cancel()
        }
    }
    public func stopAndWait() async {
        guard let task else { return }
        readiness?.cancel()
        state.present(.phase(.stopping))
        state.present(.level(0))
        state.clearDirection()
        task.cancel()
        _ = await task.result
    }
}

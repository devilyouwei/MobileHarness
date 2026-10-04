import Foundation
import UI

/// One operation and one freshness/deadline monitor; no pending diagnostic queue.
@MainActor public final class AudioDetectionWorkflow: AudioDetectionControlling {
    public let state: AudioDetectionState
    private let endpoint: any AudioDetectionRunning
    private let duration: Duration
    private var operation: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var captureStart: ContinuousClock.Instant?
    private var completed = false
    private var generation: UUID?
    public init(state: AudioDetectionState, endpoint: any AudioDetectionRunning, duration: Duration = .seconds(10)) {
        self.state = state
        self.endpoint = endpoint
        self.duration = duration
    }
    public func start() {
        guard operation == nil else { return }
        state.snapshot = AudioDetectionSnapshot()
        state.error = nil
        state.phase = .preparing
        captureStart = nil
        completed = false
        let generation = UUID()
        self.generation = generation
        operation = Task {
            do {
                try await endpoint.run { [weak self] snapshot in
                    guard let self, self.generation == generation, self.state.isActive,
                        !Task.isCancelled, self.state.phase != .stopping
                    else { return }
                    self.state.snapshot = snapshot
                    self.state.refresh()
                    if snapshot.capturedAt != nil {
                        if self.captureStart == nil { self.captureStart = .now }
                        self.state.phase = .running
                    }
                }
                try Task.checkCancellation()
                state.phase = .finished
            } catch is CancellationError {
                state.phase = completed ? .finished : .stopped
            } catch {
                if Task.isCancelled {
                    state.phase = completed ? .finished : .stopped
                } else {
                    state.error = "检测失败：\(error.localizedDescription)"
                    if state.snapshot.permissionGranted == true && state.snapshot.capture == .waiting {
                        state.snapshot.signal = .noAudio
                    }
                    state.phase = .failed
                }
            }
            let previousMonitor = monitor
            previousMonitor?.cancel()
            await previousMonitor?.value
            monitor = nil
            state.snapshot.level = 0
            state.clearDirection()
            self.generation = nil
            operation = nil
        }
        monitor = Task {
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(100))
                    try Task.checkCancellation()
                    state.refresh()
                    if let start = captureStart, start.duration(to: .now) >= duration {
                        completed = true
                        stop()
                        return
                    }
                }
            } catch {}
        }
    }
    public func stop() {
        guard operation != nil, state.phase != .stopping else { return }
        state.phase = .stopping
        generation = nil
        state.snapshot.level = 0
        state.clearDirection()
        monitor?.cancel()
        operation?.cancel()
    }
    /// Settings/model mutation barriers can await actual microphone/Agent cleanup.
    public func stopAndWait() async {
        stop()
        await operation?.value
    }
}

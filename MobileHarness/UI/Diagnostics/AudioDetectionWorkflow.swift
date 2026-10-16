import Foundation

/// One operation and one freshness/deadline monitor; no pending diagnostic queue.
@MainActor public final class AudioDetectionWorkflow: AudioDetectionControlling {
    public let state: AudioDetectionState
    private let endpoint: any AudioDetectionRunning
    private let duration: Duration
    private var operation: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var captureStart: ContinuousClock.Instant?
    private var completed = false
    private var generation: String?
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
        let generation = UUID().uuidString
        self.generation = generation
        operation = Task {
            var terminalPhase: AudioDetectionState.Phase = .finished
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
                terminalPhase = .finished
            } catch is CancellationError {
                terminalPhase = completed ? .finished : .stopped
            } catch {
                if Task.isCancelled {
                    terminalPhase = completed ? .finished : .stopped
                } else {
                    state.error = "检测失败：\(error.localizedDescription)"
                    if state.snapshot.permissionGranted == true && state.snapshot.capture == .waiting {
                        state.snapshot.signal = .noAudio
                    }
                    terminalPhase = .failed
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
            state.phase = terminalPhase
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

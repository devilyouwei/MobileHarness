import Foundation

/// One native transition worker and one latest desired state, independent of page lifetime.
@MainActor public final class ListeningCaptureWorkflow {
    private let start: @MainActor () async throws -> Void
    private let stopNative: @MainActor () async -> Void
    private var worker: Task<Void, Never>?
    private var starting: Task<Void, Error>?
    private var desired = false
    private var running = false
    private var revision: UInt64 = 0
    private var failure: (revision: UInt64, error: any Error)?

    public init(
        start: @escaping @MainActor () async throws -> Void,
        stop: @escaping @MainActor () async -> Void
    ) {
        self.start = start
        stopNative = stop
    }

    public func setEnabled(_ enabled: Bool) async throws {
        request(enabled)
        let requested = revision
        await worker?.value
        guard revision == requested else { throw CancellationError() }
        if enabled, let failure, failure.revision == requested { throw failure.error }
        try Task.checkCancellation()
    }

    public func invalidate() { request(false) }
    public func stop() async {
        request(false)
        await worker?.value
    }

    private func request(_ enabled: Bool) {
        guard desired != enabled else { return }
        revision &+= 1
        desired = enabled
        failure = nil
        if !enabled { starting?.cancel() }
        guard worker == nil else { return }
        worker = Task {
            defer { worker = nil }
            while true {
                let selected = revision
                if desired, !running {
                    let operation = Task { try await start() }
                    starting = operation
                    do {
                        try await operation.value
                        if operation.isCancelled { throw CancellationError() }
                        running = true
                    } catch {
                        await stopNative()
                        running = false
                        if revision == selected {
                            failure = (selected, error)
                            desired = false
                        }
                    }
                    starting = nil
                } else if !desired, running {
                    await stopNative()
                    running = false
                }
                if selected == revision { return }
            }
        }
    }
}

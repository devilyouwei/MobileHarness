import Foundation
import ModelKit

/// Role-owned latest-state observation. It has no sampling timer, fingerprint or retry loop.
@MainActor final class ResourceObservationSession {
    private let source: @MainActor () async throws -> ModelKit.StateSignalListener<UInt64>
    private let changed: @MainActor () async throws -> Void
    private let failed: @MainActor (any Error) -> Void
    private var task: Task<Void, Never>?
    private var epoch = UUID()
    private var foreground = false
    private var closed = false
    init(
        source: @escaping @MainActor () async throws -> ModelKit.StateSignalListener<UInt64>,
        changed: @escaping @MainActor () async throws -> Void,
        failed: @escaping @MainActor (any Error) -> Void
    ) {
        self.source = source
        self.changed = changed
        self.failed = failed
    }
    func setForeground(_ active: Bool) {
        guard !closed, active != foreground else { return }
        foreground = active
        epoch = UUID()
        let current = epoch
        let previous = task
        previous?.cancel()
        guard active else { return }
        task = Task { [weak self] in
            await previous?.value
            guard let self, self.epoch == current else { return }
            var listener: ModelKit.StateSignalListener<UInt64>?
            do {
                let stream = try await self.source()
                listener = stream
                for try await _ in stream {
                    try Task.checkCancellation()
                    guard self.epoch == current else { break }
                    try await self.changed()
                }
                if !Task.isCancelled, self.epoch == current { throw CocoaError(.fileReadUnknown) }
            } catch {
                if !Task.isCancelled, self.epoch == current { self.failed(error) }
            }
            await listener?.cancel()
            await listener?.join()
        }
    }
    func shutdown() async {
        closed = true
        epoch = UUID()
        task?.cancel()
        await task?.value
        task = nil
    }
    deinit { task?.cancel() }
}

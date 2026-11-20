import Foundation
import PlatformKit

/// Connects the native memory-warning Signal to the model release entry. It owns the subscription and its worker.
@MainActor public final class MemoryPressureRelay {
    private let listen: @MainActor () throws -> StateSignalListener<MemoryWarning>
    private let release: @Sendable () async -> Void
    private let failed: @MainActor (any Error) -> Void
    private var subscription: (listener: StateSignalListener<MemoryWarning>, worker: Task<Void, Never>)?

    public init(
        listen: @escaping @MainActor () throws -> StateSignalListener<MemoryWarning>,
        release: @escaping @Sendable () async -> Void,
        failed: @escaping @MainActor (any Error) -> Void
    ) {
        self.listen = listen
        self.release = release
        self.failed = failed
    }

    public func start() throws {
        guard subscription == nil else { return }
        let listener = try listen()
        let release = release
        let failed = failed
        let worker = Task {
            do {
                for try await _ in listener {
                    if Task.isCancelled { break }
                    await release()
                }
            } catch {
                if !Task.isCancelled { await failed(error) }
            }
            await listener.cancel()
            await listener.join()
        }
        subscription = (listener, worker)
    }

    public func stop() async {
        guard let current = subscription else { return }
        subscription = nil
        current.worker.cancel()
        await current.listener.cancel()
        await current.worker.value
        await current.listener.join()
    }
}

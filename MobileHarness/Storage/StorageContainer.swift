import Foundation
import StorageCache
import StorageCore
import StorageDatabase
import StorageFiles
import StorageState

/// Owns the storage graph. Backend selection and application ordering remain in App.
public actor StorageContainer {
    public nonisolated let state: StateContainer
    public nonisolated let cache: CacheContainer
    public nonisolated let database: any DatabaseStorage
    public nonisolated let files: FilesContainer
    private var startup: Task<Void, any Error>?
    private var shutdown: Task<Void, any Error>?
    private var closed = false
    private let failures: StorageFailureReporter
    public init(database: any DatabaseStorage, files: FilesContainer, failures: StorageFailureReporter = .init()) {
        self.failures = failures
        self.database = database
        self.files = files
        state = StateContainer(failures: failures)
        cache = CacheContainer(failures: failures)
    }
    public func start() async throws(StorageFailure) {
        do {
            guard !closed else { throw StorageError.closed }
            let task: Task<Void, any Error>
            if let startup {
                task = startup
            } else {
                task = Task { [database, files, cache, state] in
                    do {
                        try Task.checkCancellation()
                        try files.start()
                        try await database.start()
                        try Task.checkCancellation()
                    } catch {
                        let primary = error
                        state.close()
                        await cache.close()
                        await files.close()
                        var cleanup: [any Error] = []
                        do { try await database.stop() } catch { cleanup.append(error) }
                        if cleanup.isEmpty { throw primary }
                        throw StorageFailure(
                            component: "root", operation: "start", underlying: primary, cleanupErrors: cleanup)
                    }
                }
                startup = task
            }
            do {
                try await withTaskCancellationHandler {
                    try await task.value
                    try Task.checkCancellation()
                } onCancel: {
                    task.cancel()
                }
            } catch is CancellationError {
                do { try await stop() } catch {
                    throw StorageFailure(
                        component: "root", operation: "start", underlying: CancellationError(), cleanupErrors: [error])
                }
                throw CancellationError()
            }
        } catch {
            throw failures.report("root", "start", error)
        }
    }

    public func stop() async throws(StorageFailure) {
        do {
            if let shutdown { return try await shutdown.value }
            closed = true
            startup?.cancel()
            state.close()
            cache.beginClosing()
            files.beginClosing()
            let task = Task { [startup, database, files, cache] in
                let closingDatabase = Task { try await database.stop() }
                async let closingCache: Void = cache.close()
                async let closingFiles: Void = files.close()
                let result = await startup?.result
                _ = await (closingCache, closingFiles)
                var errors: [any Error] = []
                do { try await closingDatabase.value } catch { errors.append(error) }
                if case .failure(let failure as StorageFailure) = result {
                    errors.append(contentsOf: failure.cleanupErrors)
                }
                if let primary = errors.first {
                    throw StorageFailure(
                        component: "root", operation: "stop", underlying: primary,
                        cleanupErrors: Array(errors.dropFirst()))
                }
            }
            shutdown = task
            try await task.value
        } catch {
            throw failures.report("root", "stop", error)
        }
    }
}

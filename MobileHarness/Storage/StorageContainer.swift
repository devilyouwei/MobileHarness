import Foundation
import StorageCache
import StorageCore
import StorageDatabase
import StorageFiles
import StorageState

public struct StorageLifecycleFailure: Error, Sendable {
    public let primary: any Error
    public let cleanup: [any Error]
}
/// Owns the storage graph. Backend selection and application ordering remain in App.
public actor StorageContainer {
    public nonisolated let state: StateContainer
    public nonisolated let cache: CacheContainer
    public nonisolated let database: any DatabaseStorage
    public nonisolated let files: FilesContainer
    private var startup: Task<Void, any Error>?
    private var shutdown: Task<Void, any Error>?
    private var closed = false
    public init(database: any DatabaseStorage, files: FilesContainer) {
        self.database = database
        self.files = files
        state = StateContainer()
        cache = CacheContainer()
    }
    public func start() async throws {
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
                    throw StorageLifecycleFailure(primary: primary, cleanup: cleanup)
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
                throw StorageLifecycleFailure(primary: CancellationError(), cleanup: [error])
            }
            throw CancellationError()
        }
    }

    public func stop() async throws {
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
            if case .failure(let failure as StorageLifecycleFailure) = result {
                errors.append(contentsOf: failure.cleanup)
            }
            if let primary = errors.first {
                throw StorageLifecycleFailure(primary: primary, cleanup: Array(errors.dropFirst()))
            }
        }
        shutdown = task
        try await task.value
    }
}

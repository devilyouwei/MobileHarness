import Foundation
import StorageChat
import StorageCore
import StorageDatabase
import StorageDevices
import StorageMedia
import StorageTasks
import Synchronization

public enum SQLiteDatabaseFactory {
    /// Construction is inert. Filesystem and database work belongs to start().
    public static func make(databaseURL: URL, failures: StorageFailureReporter = .init()) -> SQLiteDatabaseStorage {
        SQLiteDatabaseStorage(failures: failures) {
            guard databaseURL.isFileURL else { throw RecordStorageError.invalidRecord }
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            return try SQLiteRepositories(url: databaseURL, failures: failures)
        }
    }
}

/// Owns one persistent storage scope; failed or stopped scopes are never reopened.
public actor SQLiteDatabaseStorage: DatabaseStorage {
    public nonisolated var chat: any ChatRepository { get throws { try repositories().chat } }
    public nonisolated var tasks: any TaskRepository { get throws { try repositories().tasks } }
    public nonisolated var media: any MediaRepository { get throws { try repositories().media } }
    public nonisolated var devices: any DeviceRepository { get throws { try repositories().devices } }

    private nonisolated let access = DatabaseAccess()
    private let open: @Sendable () throws -> SQLiteRepositories
    private var startup: Task<Void, any Error>?
    private var shutdown: Task<Void, any Error>?
    private var ready = false
    private var stopped = false
    private var closed = false
    private var failure: (any Error)?

    private let failures: StorageFailureReporter
    init(failures: StorageFailureReporter = .init(), open: @escaping @Sendable () throws -> SQLiteRepositories) {
        self.failures = failures
        self.open = open
    }

    public nonisolated func repositories() throws -> DatabaseRepositories {
        do {
            return try access.repositories()
        } catch {
            failures.report("database", "repositories", error)
            throw error
        }
    }

    public func stateSnapshot() async throws -> StorageStateSnapshot {
        try Task.checkCancellation()
        let phase: DatabasePhase =
            failure != nil
            ? .failed
            : stopped ? .stopped : closed ? .stopping : ready ? .ready : startup != nil ? .starting : .cold
        return .init(
            path: "storage.database", runtime: ["phase": .text(phase.rawValue)],
            health: phase == .failed ? .fault : .unknown,
            issues: phase == .failed ? [.init(code: "databaseFailed", impact: "databaseUnavailable")] : [],
            stateValues: ["runtime.phase": DatabasePhase.allCases.map(\.rawValue)])
    }
    public func start() async throws {
        do {
            guard !closed else { throw RecordStorageError.closed }
            if let failure { throw failure }
            let task: Task<Void, any Error>
            if let startup {
                task = startup
            } else {
                let created = Task.detached { [open, access] in
                    try Task.checkCancellation()
                    let repositories = try open()
                    access.install(repositories)
                    try Task.checkCancellation()
                    try repositories.recoverInFlight()
                    try Task.checkCancellation()
                    try access.publish()
                }
                startup = created
                task = created
            }
            do {
                try await withTaskCancellationHandler {
                    try await task.value
                    try Task.checkCancellation()
                } onCancel: {
                    task.cancel()
                }
                if let failure { throw failure }
                guard !closed else { throw RecordStorageError.closed }
                ready = true
            } catch {
                if failure == nil { failure = error }
                access.closeAdmission()
                throw error
            }
        } catch {
            failures.report("database", "start", error)
            throw error
        }
    }

    public func stop() async throws {
        do {
            if let shutdown { return try await shutdown.value }
            closed = true
            access.closeAdmission()
            startup?.cancel()
            let task = Task.detached { [startup, access] in
                let result = await startup?.result
                try await access.closeBackend()
                // A constructor can fail before it can publish an owner for later cleanup.
                // Its unconfirmed cleanup must still block replacement of this scope.
                if case .failure(let failure as StorageFailure) = result, let primary = failure.cleanupErrors.first {
                    throw StorageFailure(
                        component: "database", operation: "stop", underlying: primary,
                        cleanupErrors: Array(failure.cleanupErrors.dropFirst()), code: .cleanupFailed)
                }
            }
            shutdown = task
            try await task.value
            stopped = true
        } catch {
            if failure == nil { failure = error }
            failures.report("database", "stop", error)
            throw error
        }
    }
}

private final class DatabaseAccess: Sendable {
    private struct State {
        var backend: SQLiteRepositories?
        var ready = false
        var closed = false
    }
    private let state = Mutex(State())

    func install(_ backend: SQLiteRepositories) {
        state.withLock { value in
            value.backend = backend
            if value.closed { backend.beginClosing() }
        }
    }
    func publish() throws {
        try state.withLock { value in
            guard !value.closed else { throw RecordStorageError.closed }
            value.ready = true
        }
    }
    func repositories() throws -> DatabaseRepositories {
        try state.withLock { value in
            guard !value.closed else { throw RecordStorageError.closed }
            guard value.ready, let backend = value.backend else { throw RecordStorageError.notReady }
            return DatabaseRepositories(
                chat: backend.chat, tasks: backend.tasks, media: backend.media, devices: backend.devices)
        }
    }
    func closeAdmission() {
        state.withLock { value in
            value.closed = true
            value.ready = false
            value.backend?.beginClosing()
        }
    }
    func closeBackend() async throws {
        let backend = state.withLock { $0.backend }
        try await backend?.shutdown()
        state.withLock { $0.backend = nil }
    }
}

import Foundation
internal import GRDB
import StorageCore
import Synchronization

internal final class SQLiteDatabase: Sendable {
    let storageScope = UUID()
    private let temporaryURL: URL?
    private let pool: DatabasePool
    private struct Lifetime {
        var accepting = true
        var active = 0
        var poolClosed = false
        var drained: CheckedContinuation<Void, Never>?
        var shutdown: Task<Void, any Error>?
    }
    private let lifetime = Mutex(Lifetime())
    private let admittedWrites = Mutex(0)
    private let writer = NSLock()
    private let committedChanges = Mutex(0)
    private let writeTransactions = Mutex(0)
    var committedWriteCount: Int { writeTransactions.withLock { $0 } }
    var lastWriteChanges: Int { committedChanges.withLock { $0 } }
    func write<Value>(_ body: (Database) throws -> Value) throws -> Value {
        try admit()
        defer { release() }
        let admitted = admittedWrites.withLock { count in
            guard count < 17 else { return false }
            count += 1
            return true
        }
        guard admitted else { throw RecordStorageError.busy }
        defer { admittedWrites.withLock { $0 -= 1 } }
        writer.lock()
        defer { writer.unlock() }
        let result = try pool.write { db in
            let before = db.totalChangesCount
            let result = try body(db)
            return (result, db.totalChangesCount - before)
        }
        committedChanges.withLock { $0 = result.1 }
        writeTransactions.withLock { $0 += 1 }
        return result.0
    }
    public init(url: URL, removeOnClose: Bool = false) throws {
        temporaryURL = removeOnClose ? url : nil
        guard url.isFileURL else { throw RecordStorageError.invalidRecord }
        var configuration = Configuration()
        configuration.busyMode = .timeout(2)
        configuration.maximumReaderCount = 4
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        pool = try DatabasePool(path: url.path, configuration: configuration)
    }
    func migrate(_ changes: [(name: String, statements: [String])]) throws {
        var migrations = DatabaseMigrator()
        for change in changes {
            migrations.registerMigration(change.name) { db in
                for sql in change.statements { try db.execute(sql: sql) }
            }
        }
        try migrations.migrate(pool)
    }
    private func admit() throws {
        try lifetime.withLock { state in
            guard state.accepting else { throw RecordStorageError.closed }
            guard state.active < 64 else { throw RecordStorageError.busy }
            state.active += 1
        }
    }
    private func release() {
        let drained = lifetime.withLock { state -> CheckedContinuation<Void, Never>? in
            state.active -= 1
            guard state.active == 0 else { return nil }
            let drained = state.drained
            state.drained = nil
            return drained
        }
        drained?.resume()
    }
    func beginClosing() { lifetime.withLock { $0.accepting = false } }
    private func waitForDrain() async {
        await withCheckedContinuation { continuation in
            lifetime.withLock { state in
                if state.active == 0 {
                    continuation.resume()
                } else {
                    state.drained = continuation
                }
            }
        }
    }
    func shutdown() async throws {
        let task = lifetime.withLock { state in
            if let shutdown = state.shutdown { return shutdown }
            state.accepting = false
            let task = Task.detached { [self] in
                await waitForDrain()
                try closeUnpublished()
            }
            state.shutdown = task
            return task
        }
        try await task.value
    }
    // Only used before publication, or after all admitted operations have drained.
    func closeUnpublished() throws {
        beginClosing()
        guard !lifetime.withLock({ $0.poolClosed }) else { return }
        try pool.close()
        lifetime.withLock { $0.poolClosed = true }
        removeTemporaryFiles()
    }
    private func removeTemporaryFiles() {
        guard let temporaryURL else { return }
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: temporaryURL.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
    deinit {
        if temporaryURL != nil, !lifetime.withLock({ $0.poolClosed }) {
            do {
                try pool.close()
                removeTemporaryFiles()
            } catch {
                // A busy temporary connection keeps its files until system cleanup.
            }
        }
    }
    func read<Value>(_ body: (Database) throws -> Value) throws -> Value {
        try admit()
        defer { release() }
        return try pool.read(body)
    }
}

internal enum SQLiteRecordKey {
    static func id(_ kind: BusinessRecordID.Kind, _ number: Int64) -> String { "\(kind.rawValue)_\(number)" }
}

import AppLifecycle
import Foundation
import SQLite3
import StorageChat
import StorageCore
import StorageFiles
import StorageMedia
import StorageTasks
import Synchronization
import Testing

@testable import StorageSQLite

private enum StorageRuntimeFixtureError: Error, Equatable { case open, cleanup, consumer, timedOut }

private func storageTestRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func waitForStorageClosed(_ storage: SQLiteDatabaseStorage) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        do { _ = try storage.repositories() } catch RecordStorageError.closed {
            return
        } catch RecordStorageError.notReady {}
        await Task.yield()
    }
    throw StorageRuntimeFixtureError.timedOut
}

@Suite struct StorageRuntimeTests {
    @Test func constructionIsInertAndRepeatedStartupKeepsOneScope() async throws {
        let root = storageTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("records.sqlite")
        let storage = SQLiteDatabaseFactory.make(databaseURL: url)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(throws: RecordStorageError.notReady) { try storage.repositories() }
        let scopes = try await withThrowingTaskGroup(of: UUID.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await storage.start()
                    return try storage.repositories().tasks.storageScope
                }
            }
            var scopes = Set<UUID>()
            for try await scope in group { scopes.insert(scope) }
            return scopes
        }
        #expect(scopes.count == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let repositories = try storage.repositories()
        let device = try await repositories.devices.device(nativeID: "fixture", name: "Fixture")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { try await storage.stop() } }
            try await group.waitForAll()
        }
        #expect(throws: RecordStorageError.closed) { try storage.repositories() }
        await #expect(throws: RecordStorageError.closed) { try await storage.start() }
        await #expect(throws: RecordStorageError.closed) { try await repositories.devices.nativeDevice(device) }
        await #expect(throws: RecordStorageError.closed) {
            try await repositories.tasks.createTask(dialog: nil, agent: "fixture", goal: "late")
        }
        let replacement = SQLiteDatabaseFactory.make(databaseURL: url)
        try await replacement.start()
        #expect(try await replacement.repositories().devices.nativeDevice(device) == "fixture")
        #expect(try replacement.repositories().tasks.storageScope != repositories.tasks.storageScope)
        try await replacement.stop()
    }

    @Test func startupRecoversUnfinishedRecordsOnlyOnce() async throws {
        let root = storageTestRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("records.sqlite")
        let seed = try SQLiteRepositories(url: url)
        let dialog = try await seed.chat.current(agent: "fixture")
        let task = try await seed.tasks.createTask(dialog: dialog.id, agent: "fixture", goal: "interrupted")
        let identity = MessageIdentity(
            clientID: "old-response", inputID: "old-input", role: "assistant", kind: "response", order: 1,
            date: Date(), taskID: task)
        let id = try seed.chat.beginMessage(dialog: dialog.id, identity: identity)
        try await seed.shutdown()
        let storage = SQLiteDatabaseFactory.make(databaseURL: url)
        try await storage.start()
        let chat = try storage.repositories().chat
        let message = try #require(try await chat.messages(dialog: dialog.id, after: nil).first)
        #expect(message.id == id && message.state == "interrupted")
        let data = try #require(try await chat.compressionData(dialog: dialog.id).first)
        let compression = try JSONDecoder().decode(ConversationTaskCompression.self, from: data)
        #expect(compression.taskID == task && compression.status == .interrupted)
        let live = try await chat.beginMessage(
            dialog: dialog.id,
            identity: .init(
                clientID: "live-response", inputID: "live-input", role: "assistant", kind: "response", order: 2,
                date: Date()))
        try await storage.start()
        #expect(
            try await chat.messages(dialog: dialog.id, after: nil).first(where: { $0.id == live })?.state
                == "generating")
        try await storage.stop()
    }

    @Test @MainActor func initializationRunsOffMainAndFailureDoesNotReopen() async throws {
        let calls = Mutex(0)
        let storage = SQLiteDatabaseStorage {
            #expect(!Thread.isMainThread)
            calls.withLock { $0 += 1 }
            throw StorageRuntimeFixtureError.open
        }
        for _ in 0..<2 {
            await #expect(throws: StorageRuntimeFixtureError.open) { try await storage.start() }
        }
        #expect(calls.withLock { $0 } == 1)
        #expect(throws: RecordStorageError.closed) { try storage.repositories() }
        try await storage.stop()
        try await storage.stop()
        await #expect(throws: RecordStorageError.closed) { try await storage.start() }
    }

    @Test func initializationCleanupFailureRemainsAStopFailure() async throws {
        let storage = SQLiteDatabaseStorage {
            throw StorageFailure(
                component: "database", operation: "prepare", underlying: StorageRuntimeFixtureError.open,
                cleanupErrors: [StorageRuntimeFixtureError.cleanup])
        }
        do {
            try await storage.start()
            Issue.record("Expected preparation failure")
        } catch let error as StorageFailure {
            #expect(error.underlying as? StorageRuntimeFixtureError == .open)
            #expect(error.cleanupErrors.first as? StorageRuntimeFixtureError == .cleanup)
        }
        for _ in 0..<2 {
            await #expect(throws: StorageFailure.self) { try await storage.stop() }
        }
    }

    @Test func cancelledStartupJoinsInitializationAndClosesItsBackend() async throws {
        let records = try SQLiteRepositories.temporary()
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let storage = SQLiteDatabaseStorage {
            entered.continuation.yield(())
            guard release.wait(timeout: .now() + 5) == .success else { throw StorageRuntimeFixtureError.timedOut }
            return records
        }
        let starting = Task { try await storage.start() }
        var events = entered.stream.makeAsyncIterator()
        _ = await events.next()
        starting.cancel()
        let stopped = Mutex(false)
        let stopping = Task {
            try await storage.stop()
            stopped.withLock { $0 = true }
        }
        try await waitForStorageClosed(storage)
        #expect(!stopped.withLock { $0 })
        release.signal()
        await #expect(throws: CancellationError.self) { try await starting.value }
        try await stopping.value
        #expect(stopped.withLock { $0 })
        #expect(throws: RecordStorageError.closed) { try records.devices.selectedDevice() }
    }

    @Test(arguments: [false, true]) func stopWaitsForAdmittedReadOrWrite(write: Bool) async throws {
        let records = try SQLiteRepositories.temporary()
        let storage = SQLiteDatabaseStorage { records }
        try await storage.start()
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let operation = Task.detached {
            let body = {
                entered.continuation.yield(())
                guard release.wait(timeout: .now() + 5) == .success else { throw StorageRuntimeFixtureError.timedOut }
                return 42
            }
            return try write ? records.database.write { _ in try body() } : records.database.read { _ in try body() }
        }
        var events = entered.stream.makeAsyncIterator()
        _ = await events.next()
        let stopped = Mutex(false)
        let stopping = Task {
            try await storage.stop()
            stopped.withLock { $0 = true }
        }
        try await waitForStorageClosed(storage)
        #expect(!stopped.withLock { $0 })
        #expect(throws: RecordStorageError.closed) { try records.devices.selectedDevice() }
        release.signal()
        #expect(try await operation.value == 42)
        try await stopping.value
        #expect(stopped.withLock { $0 })
    }

    @Test func actualCloseFailureIsRetainedAcrossRepeatedStop() async throws {
        let records = try SQLiteRepositories.temporary()
        let storage = SQLiteDatabaseStorage { records }
        try await storage.start()
        let address = try records.database.read { db in
            var statement: OpaquePointer?
            let code = sqlite3_prepare_v2(db.sqliteConnection, "SELECT * FROM tasks", -1, &statement, nil)
            guard code == SQLITE_OK, let statement else { throw StorageRuntimeFixtureError.open }
            return Int(bitPattern: statement)
        }
        var statement: OpaquePointer? = OpaquePointer(bitPattern: address)
        defer { if let statement { sqlite3_finalize(statement) } }
        await #expect(throws: (any Error).self) { try await storage.stop() }
        #expect(throws: RecordStorageError.closed) { try records.devices.selectedDevice() }
        // Even if the native resource becomes releasable later, this scope retains its failed close result.
        sqlite3_finalize(statement)
        statement = nil
        for _ in 0..<2 {
            await #expect(throws: (any Error).self) { try await storage.stop() }
        }
    }

    @Test func mediaProviderDoesNotCacheNotReady() async throws {
        let storage = SQLiteDatabaseStorage { try SQLiteRepositories.temporary() }
        let photos = CapturedPhotoStore(
            repository: { try storage.repositories().media }, files: .success(try MemoryFileStore()))
        let owner = StorageOwner(namespace: "photos", source: "fixture", session: "session", input: "input")
        await #expect(throws: RecordStorageError.notReady) { try await photos.save(Data([1, 2, 3]), owner: owner) }
        try await storage.start()
        let id = try await photos.save(Data([1, 2, 3]), owner: owner)
        #expect(try await photos.read(id, owner: owner) == Data([1, 2, 3]))
        try await storage.stop()
        await #expect(throws: RecordStorageError.closed) { try await photos.read(id, owner: owner) }
    }

    @Test @MainActor func rootRollbackStopsConsumersBeforeClosingStorage() async throws {
        let storage = SQLiteDatabaseStorage { try SQLiteRepositories.temporary() }
        var cleanupTask: String?
        let root = try ApplicationLifecycle(services: [
            .init(id: "storage", start: { try await storage.start() }, stop: { try await storage.stop() }),
            .init(
                id: "consumer", dependencies: ["storage"], start: { throw StorageRuntimeFixtureError.consumer },
                stop: {
                    cleanupTask = try await storage.repositories().tasks.createTask(
                        dialog: nil, agent: "fixture", goal: "cleanup")
                }),
        ])
        do {
            try await root.start()
            Issue.record("Expected consumer startup failure")
        } catch let error as ApplicationLifecycleFailure {
            #expect(error.service == "consumer")
            #expect(error.primary as? StorageRuntimeFixtureError == .consumer)
            #expect(error.cleanup.isEmpty)
        }
        #expect(cleanupTask != nil)
        #expect(throws: RecordStorageError.closed) { try storage.repositories() }
        try await root.stop()
    }
    @Test func stopBeforeStartNeverCreatesTheDatabase() async throws {
        let root = storageTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SQLiteDatabaseFactory.make(databaseURL: root.appendingPathComponent("records.sqlite"))
        try await storage.stop()
        await #expect(throws: RecordStorageError.closed) { try await storage.start() }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func corruptedDatabaseFailsWithoutReplacingItsBytes() async throws {
        let root = storageTestRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("records.sqlite")
        let bytes = Data(repeating: 0x7f, count: 4096)
        try bytes.write(to: url)
        let storage = SQLiteDatabaseFactory.make(databaseURL: url)
        await #expect(throws: (any Error).self) { try await storage.start() }
        #expect(throws: RecordStorageError.closed) { try storage.repositories() }
        try await storage.stop()
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test @MainActor func sceneSuspensionDuringStorageStartupRollsBackWithoutFailure() async throws {
        let records = try SQLiteRepositories.temporary()
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let storage = SQLiteDatabaseStorage {
            entered.continuation.yield(())
            guard release.wait(timeout: .now() + 5) == .success else { throw StorageRuntimeFixtureError.timedOut }
            return records
        }
        let root = try ApplicationLifecycle(services: [
            .init(id: "storage", start: { try await storage.start() }, stop: { try await storage.stop() })
        ])
        let starting = Task { try await root.start() }
        var events = entered.stream.makeAsyncIterator()
        _ = await events.next()
        root.setForeground(false)
        release.signal()
        await #expect(throws: CancellationError.self) { try await starting.value }
        #expect(root.state == .suspended && root.failure == nil)
        #expect(throws: RecordStorageError.closed) { try storage.repositories() }
        #expect(throws: RecordStorageError.closed) { try records.devices.selectedDevice() }
        try await root.stop()
    }

}

import AppStorage
import Foundation
import Storage
import StorageCache
import StorageChat
import StorageCore
import StorageDatabase
import StorageDevices
import StorageFiles
import StorageMedia
import StorageSQLite
import StorageTasks
import Testing

private enum ContainerFixtureError: Error, Equatable { case invalid, start, cleanup }
private func containerRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

@Suite struct SharedCacheTests {
    @Test func buffersKeepIdentityAndMemoryAcrossNamespaces() throws {
        let cache = BufferCache()
        let buffer = CacheBuffer(Data(repeating: 7, count: 4096))
        try cache.put(buffer, key: "frame", namespace: "images")
        let lease = try cache.get("frame", namespace: "images")
        #expect(lease.bufferID == buffer.id)
        let address = buffer.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) }
        #expect(try lease.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) } == address)
        #expect(throws: StorageError.missing) { try cache.get("frame", namespace: "other") }
        try cache.remove("frame", namespace: "images")
        #expect(try lease.withUnsafeBytes { $0.count } == 4096)
        cache.close()
        #expect(throws: StorageError.closed) { try lease.withUnsafeBytes { $0.count } }
        lease.release()
        lease.release()
    }
    @Test func removedLeasesRemainChargedUntilReleased() throws {
        let cache = BufferCache(capacity: 1, maximumBytes: 4)
        try cache.put(CacheBuffer(Data([1, 2, 3, 4])), key: "one")
        let lease = try cache.get("one")
        try cache.remove("one")
        #expect(throws: StorageError.capacityExceeded) { try cache.put(CacheBuffer(Data([5])), key: "two") }
        lease.release()
        try cache.put(CacheBuffer(Data([5])), key: "two")
        #expect(throws: StorageError.closed) { try lease.withUnsafeBytes { $0.count } }
    }
    @Test func audioScopesShareAndRetireWithoutReusingClosedStores() async throws {
        let cache = CacheContainer()
        let first = try await cache.audioScope("session")
        let same = try await cache.audioScope("session")
        #expect(first === same)
        let owner = AudioCache.Owner(source: "fixture", session: "session", input: "input")
        try await first.register("clip", owner: owner, cancel: {})
        let stream = try await first.begin("clip")
        let frame = try AudioFrame(
            data: Data(repeating: 0, count: 16),
            format: StorageCache.AudioFormat(sampleRate: 24000, channels: 1, encoding: .float32), sequence: 0,
            timestamp: 0)
        try await stream.append(frame)
        await first.complete("clip")
        let player = try await first.checkout("clip", owner: owner)
        #expect(try await player.next()?.buffer.id == frame.buffer.id)
        #expect(try await player.next() == nil)
        try await first.release("clip", owner: owner)
        await cache.closeAudioScope("session")
        await #expect(throws: AudioCacheError.closed) { try await first.register("late", owner: owner, cancel: {}) }
        let replacement = try await cache.audioScope("session")
        #expect(replacement !== first)
        await cache.close()
        await #expect(throws: StorageError.closed) { try await cache.audioScope("session") }
    }
}
@Suite struct StorageContainerTests {
    @Test func registrationSharesWithinRootAndSeparatesRoots() async throws {
        let root = containerRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ApplicationContainer(root: root)
        let first = registry.storage()
        let same = registry.storage()
        let second = ApplicationContainer(root: root).storage()
        #expect(first === same && first !== second)
        #expect(registry.files() === first.files)
        #expect(registry.cache() === first.cache)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(throws: RecordStorageError.notReady) { try first.database.assistantConversations }
        try await first.start()
        let store = try first.files.document(String.self, in: first.files.settings, name: "settings.json")
        _ = try await store.save("value", expecting: nil)
        let chat = try first.database.assistantConversations
        _ = try await chat.current()
        async let one: Void = first.stop()
        async let two: Void = first.stop()
        _ = try await (one, two)
        await #expect(throws: StorageError.closed) { try await store.load() }
        await #expect(throws: RecordStorageError.closed) { try await chat.current() }
        await #expect(throws: StorageFailure.self) { try await first.start() }
        try await second.stop()
    }
    @Test func fileNamespacesAreScopedAndCompatibleOnDisk() async throws {
        let root = containerRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ApplicationContainer(root: root)
        let storage = registry.storage()
        let other = ApplicationContainer(root: root).storage()
        #expect(throws: StorageError.forbidden) { try storage.files.file(other.files.photos) }
        let document = try storage.files.document(String.self, in: storage.files.settings, name: "settings.json")
        #expect(throws: FileStorageError.invalidPath) {
            try storage.files.document(String.self, in: storage.files.settings, name: "../escape")
        }
        let saved = try await document.save("original", expecting: nil)
        let direct = try FileDocumentStore<String>(url: root.appendingPathComponent("Settings/settings.json"))
        #expect(try await direct.load()?.revision == saved.revision)
        let photos = try storage.files.file(storage.files.photos)
        try await photos.putIfAbsent(Data([1]), key: "photo.jpg")
        await #expect(throws: FileStorageError.invalidPath) { try await photos.read("../escape", maximumBytes: 10) }
        try await storage.stop()
        try await other.stop()
        await #expect(throws: StorageError.closed) { try await photos.read("photo.jpg", maximumBytes: 10) }
    }
}

private actor FailingContainerDatabase: DatabaseStorage {
    private var starts = 0
    private var stops = 0
    nonisolated var assistantConversations: any AssistantConversationRepository {
        get throws { throw RecordStorageError.notReady }
    }
    nonisolated var assistantMessages: any AssistantMessageRepository {
        get throws { throw RecordStorageError.notReady }
    }
    nonisolated var assistantTasks: any AssistantTaskRepository & AssistantTaskSummaryRepository {
        get throws { throw RecordStorageError.notReady }
    }
    nonisolated var writerMessages: any WriterMessageRepository { get throws { throw RecordStorageError.notReady } }
    nonisolated var writerExecutions: any WriterExecutionRepository { get throws { throw RecordStorageError.notReady } }
    nonisolated var agentMessages: any AgentMessageRepository { get throws { throw RecordStorageError.notReady } }
    nonisolated var logs: any ModelRequestLogRepository { get throws { throw RecordStorageError.notReady } }
    nonisolated var workspaces: any WorkspaceRepository { get throws { throw RecordStorageError.notReady } }
    nonisolated var media: any MediaRepository { get throws { throw RecordStorageError.notReady } }
    nonisolated var devices: any DeviceRepository { get throws { throw RecordStorageError.notReady } }
    func start() throws {
        starts += 1
        throw ContainerFixtureError.start
    }
    func stop() throws {
        stops += 1
        throw ContainerFixtureError.cleanup
    }
    func counts() -> (Int, Int) { (starts, stops) }
}

extension StorageContainerTests {
    @Test func failedStartClosesChildrenAndRetainsCleanupFailures() async throws {
        let root = containerRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = FailingContainerDatabase()
        let files = FilesContainer(
            settings: root.appendingPathComponent("Settings"), photos: root.appendingPathComponent("Photos"),
            models: root.appendingPathComponent("Models"))
        let storage = StorageContainer(database: database, files: files)
        do {
            try await storage.start()
            Issue.record("Expected database preparation failure")
        } catch let error as StorageFailure {
            #expect(error.underlying as? ContainerFixtureError == .start)
            #expect(error.cleanupErrors.count == 1)
            #expect(error.cleanupErrors.first as? ContainerFixtureError == .cleanup)
        }
        let reflected = try await storage.stateSnapshot()
        #expect(reflected.business.isEmpty)
        #expect(reflected.health == .fault)
        #expect(reflected.issues.contains { $0.code == "lifecycleFailed" && $0.impact == "storageUnavailable" })
        #expect(throws: StorageError.closed) { try files.file(files.photos) }
        #expect(throws: StorageError.closed) { try storage.cache.images.put(CacheBuffer(Data([1])), key: "late") }
        await #expect(throws: StorageFailure.self) { try await storage.start() }
        #expect(await database.counts().0 == 1)
        await #expect(throws: StorageFailure.self) { try await storage.stop() }
        let stopped = await database.counts().1
        await #expect(throws: StorageFailure.self) { try await storage.stop() }
        #expect(await database.counts().1 == stopped)
    }
}

private actor WaitingContainerDatabase: DatabaseStorage {
    private var starting = false
    private var stopped = false
    nonisolated var assistantConversations: any AssistantConversationRepository {
        get throws { throw RecordStorageError.notReady }
    }
    nonisolated var assistantMessages: any AssistantMessageRepository {
        get throws { throw RecordStorageError.notReady }
    }
    nonisolated var assistantTasks: any AssistantTaskRepository & AssistantTaskSummaryRepository {
        get throws { throw RecordStorageError.notReady }
    }
    nonisolated var writerMessages: any WriterMessageRepository { get throws { throw RecordStorageError.notReady } }
    nonisolated var writerExecutions: any WriterExecutionRepository { get throws { throw RecordStorageError.notReady } }
    nonisolated var agentMessages: any AgentMessageRepository { get throws { throw RecordStorageError.notReady } }
    nonisolated var logs: any ModelRequestLogRepository { get throws { throw RecordStorageError.notReady } }
    nonisolated var workspaces: any WorkspaceRepository { get throws { throw RecordStorageError.notReady } }
    nonisolated var media: any MediaRepository { get throws { throw RecordStorageError.notReady } }
    nonisolated var devices: any DeviceRepository { get throws { throw RecordStorageError.notReady } }
    func start() async throws {
        starting = true
        try await Task.sleep(for: .seconds(30))
    }
    func stop() { stopped = true }
    func isStarting() -> Bool { starting }
    func isStopped() -> Bool { stopped }
}
extension StorageContainerTests {
    @Test func cancellingStartupPreservesNormalCancellationAndJoinsCleanup() async throws {
        let root = containerRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = WaitingContainerDatabase()
        let files = FilesContainer(
            settings: root.appendingPathComponent("Settings"), photos: root.appendingPathComponent("Photos"),
            models: root.appendingPathComponent("Models"))
        let storage = StorageContainer(database: database, files: files)
        let work = Task { try await storage.start() }
        while !(await database.isStarting()) { await Task.yield() }
        work.cancel()
        do {
            try await work.value
            Issue.record("Expected structured cancellation")
        } catch let failure as StorageFailure {
            #expect(failure.isCancellation)
            #expect(failure.underlying is CancellationError)
            #expect(failure.cleanupErrors.isEmpty)
        }
        #expect(await database.isStopped())
        #expect(throws: StorageError.closed) { try files.file(files.photos) }
        try await storage.stop()
    }
}

extension SharedCacheTests {
    @Test func closingRejectsExistingAudioAdmissionBeforeCleanup() async throws {
        let cache = CacheContainer()
        let audio = try await cache.audioScope("session")
        cache.beginClosing()
        let owner = AudioCache.Owner(source: "fixture", session: "session", input: "input")
        await #expect(throws: AudioCacheError.closed) { try await audio.register("late", owner: owner, cancel: {}) }
        await #expect(throws: StorageError.closed) { try await cache.audioScope("other") }
        #expect(throws: StorageError.closed) { try cache.images.put(CacheBuffer(Data([1])), key: "late") }
        await cache.close()
    }
}

private actor StateReadSpyDatabase: DatabaseStorage {
    private var stateReads = 0
    nonisolated var assistantConversations: any AssistantConversationRepository {
        get throws { throw ContainerFixtureError.invalid }
    }
    nonisolated var assistantMessages: any AssistantMessageRepository {
        get throws { throw ContainerFixtureError.invalid }
    }
    nonisolated var assistantTasks: any AssistantTaskRepository & AssistantTaskSummaryRepository {
        get throws { throw ContainerFixtureError.invalid }
    }
    nonisolated var writerMessages: any WriterMessageRepository { get throws { throw ContainerFixtureError.invalid } }
    nonisolated var writerExecutions: any WriterExecutionRepository {
        get throws { throw ContainerFixtureError.invalid }
    }
    nonisolated var agentMessages: any AgentMessageRepository { get throws { throw ContainerFixtureError.invalid } }
    nonisolated var logs: any ModelRequestLogRepository { get throws { throw ContainerFixtureError.invalid } }
    nonisolated var workspaces: any WorkspaceRepository { get throws { throw ContainerFixtureError.invalid } }
    nonisolated var media: any MediaRepository { get throws { throw ContainerFixtureError.invalid } }
    nonisolated var devices: any DeviceRepository { get throws { throw ContainerFixtureError.invalid } }
    func start() async throws {}
    func stop() async throws {}
    func stateSnapshot() async throws -> StorageStateSnapshot {
        stateReads += 1
        return .init(path: "storage.database", runtime: ["phase": .text("cold")])
    }
    func observedReads() -> Int { stateReads }
}

@Test func singleNodeStorageRootAndCatalogNeverSampleTheDatabaseChild() async throws {
    let location = containerRoot()
    let database = StateReadSpyDatabase()
    let files = FilesContainer(
        settings: location.appendingPathComponent("settings"), photos: location.appendingPathComponent("photos"),
        models: location.appendingPathComponent("models"))
    let root = StorageContainer(database: database, files: files)
    let own = try await root.stateSnapshot()
    #expect(own.children.map(\.path).contains("storage.database"))
    #expect(await database.observedReads() == 0)
    let readers = try await root.stateReaders()
    #expect(await database.observedReads() == 0)
    let read = try #require(readers["storage.database"])
    #expect(try await read().runtime["phase"] == .text("cold"))
    #expect(await database.observedReads() == 1)
    #expect(!FileManager.default.fileExists(atPath: location.path))
}

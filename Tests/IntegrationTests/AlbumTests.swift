import Actions
import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import PlatformKit
import StorageCore
import StorageFiles
import StorageMedia
import Testing
import UI

@testable import Agents
@testable import StorageSQLite

#if canImport(ImageIO)
    import ImageIO
    import UniformTypeIdentifiers
#endif

private let albumOwner = StorageOwner(
    namespace: "photos", source: "assistant", session: "album-session", input: "album-input")
private func albumMetadata(_ mime: String = "image/jpeg", date: Date? = nil) -> MediaMetadata {
    MediaMetadata(mime: mime, width: 2, height: 3, capturedAt: date, origin: "import")
}

@Test func albumCollectionIsSeparateFromReadyAndSurvivesReopening() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let files = try MemoryFileStore()
    let first = try SQLiteRepositories(url: url)
    let store = MediaStore(repository: first.media, files: files)
    let id = try await store.save(Data([1, 2, 3]), owner: albumOwner)
    #expect(try await store.albumPage().items.isEmpty)
    try await store.collect(id, owner: albumOwner, metadata: albumMetadata())
    try await store.collect(id, owner: albumOwner, metadata: albumMetadata())
    #expect(try await store.albumPage().items.map(\.id) == [id])
    try await first.shutdown()
    let second = try SQLiteRepositories(url: url)
    let reopened = MediaStore(repository: second.media, files: files)
    #expect(try await reopened.readAlbum(id) == Data([1, 2, 3]))
    #expect(try await reopened.albumPage().items.count == 1)
    try await second.shutdown()
}

@Test func albumRetentionNeverEvictsCollectedPhotoAndRejectsFullCapacity() async throws {
    let records = try SQLiteRepositories.temporary()
    let files = try MemoryFileStore()
    let store = MediaStore(
        repository: records.media, files: files,
        limits: .init(maximumPhotos: 2, maximumBytes: 8, overflowPolicy: .evictOldest))
    let kept = try await store.save(Data([1, 2]), owner: albumOwner)
    try await store.collect(kept, owner: albumOwner, metadata: albumMetadata())
    let temporary = try await store.save(Data([3, 4]), owner: albumOwner)
    let replacement = try await store.save(Data([5, 6]), owner: albumOwner)
    #expect(try records.media.media(temporary)?.state == "unavailable")
    #expect(try await store.readAlbum(kept) == Data([1, 2]))
    try await store.collect(replacement, owner: albumOwner, metadata: albumMetadata())
    await #expect(throws: FileStorageError.capacityExceeded) { _ = try await store.save(Data([7]), owner: albumOwner) }
    #expect(try await store.albumPage().items.count == 2)
    try await records.shutdown()
}

@Test func albumPaginationOrdersEqualDatesByStableIDAndImportsKeepBytes() async throws {
    let records = try SQLiteRepositories.temporary()
    let files = try MemoryFileStore()
    let store = MediaStore(
        repository: records.media, files: files,
        limits: .init(maximumPhotos: 64, maximumBytes: 1024, overflowPolicy: .reject))
    let date = Date(timeIntervalSince1970: 12345)
    var ids: [String] = []
    for index in 0..<43 {
        let data = Data([UInt8(index), 0, 255])
        let id = try await store.importPhoto(data, owner: albumOwner, metadata: albumMetadata("image/png", date: date))
        ids.append(id)
        #expect(try await store.readAlbum(id) == data)
    }
    let first = try await store.albumPage()
    let second = try await store.albumPage(before: #require(first.next))
    #expect(first.items.count == 40)
    #expect(second.items.count == 3 && second.next == nil)
    #expect((first.items + second.items).map(\.id) == ids.reversed())
    #expect(first.items.allSatisfy { $0.metadata.mime == "image/png" && $0.sortDate == date })
    try await records.shutdown()
}

private actor AlbumFailingRemoveStore: FileStore {
    nonisolated let durability: StorageDurability = .memory
    let base: MemoryFileStore
    var fail = true
    init() throws { base = try MemoryFileStore() }
    func allowRemove() { fail = false }
    func read(_ key: String, maximumBytes: Int) async throws -> Data? {
        try await base.read(key, maximumBytes: maximumBytes)
    }
    func info(_ key: String) async throws -> BinaryObjectInfo? { try await base.info(key) }
    func putIfAbsent(_ data: Data, key: String) async throws { try await base.putIfAbsent(data, key: key) }
    func remove(_ key: String) async throws {
        if fail { throw FileStorageError.busy }
        try await base.remove(key)
    }
    func listObjects(cursor: String?, limit: Int) async throws -> BinaryObjectPage {
        try await base.listObjects(cursor: cursor, limit: limit)
    }
    func closeListing(_ cursor: String) async { await base.closeListing(cursor) }
}
@Test func albumDeleteCommitsBeforeCleanupAndRecoveryNeverResurrectsPhoto() async throws {
    let records = try SQLiteRepositories.temporary()
    let files = try AlbumFailingRemoveStore()
    let store = MediaStore(repository: records.media, files: files)
    let id = try await store.importPhoto(Data([1, 2]), owner: albumOwner, metadata: albumMetadata())
    await #expect(throws: (any Error).self) { try await store.deleteAlbum(id) }
    #expect(try records.media.albumMedia(id) == nil)
    #expect(try records.media.media(id)?.state == "deleting")
    await files.allowRemove()
    let reopened = MediaStore(repository: records.media, files: files)
    #expect(try await reopened.albumPage().items.isEmpty)
    #expect(try records.media.media(id)?.state == "deleted")
    #expect(try await reopened.readForInput(id, source: albumOwner.source, input: albumOwner.input) == nil)
    try await records.shutdown()
}

#if canImport(ImageIO)
    private func albumImage(_ type: UTType) throws -> Data {
        let pixels = Data(repeating: 128, count: 4 * 6)
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(
            CGImage(
                width: 2, height: 3, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
    @Test(arguments: [UTType.jpeg, .png, .heic])
    func albumNativeFormatsRemainUnmodifiedAndProduceBoundedThumbnails(_ type: UTType) async throws {
        let data = try albumImage(type)
        let info = try await NativeAlbumImage.inspect(data)
        #expect(info.width == 2 && info.height == 3)
        let records = try SQLiteRepositories.temporary()
        let store = MediaStore(repository: records.media, files: try MemoryFileStore())
        let service = PhotoAlbumService(photos: store, export: { _ in })
        _ = try await service.perform(.importPhotos([AlbumImportSource { data }]), owner: albumOwner)
        let id = try #require(try await store.albumPage().items.first?.id)
        #expect(try await store.readAlbum(id) == data)
        let thumbnail = try await NativeAlbumImage.thumbnail(data)
        #expect(try await NativeAlbumImage.inspect(thumbnail).mime == "image/jpeg")
        try await records.shutdown()
    }
    @Test func albumServiceImportsIndividualResultsPreservesFilesAndExportFailureRetainsPhoto() async throws {
        let records = try SQLiteRepositories.temporary()
        let store = MediaStore(repository: records.media, files: try MemoryFileStore())
        let service = PhotoAlbumService(photos: store, export: { _ in throw PhotoAlbumError.unavailable })
        let jpeg = try albumImage(.jpeg)
        let png = try albumImage(.png)
        let result = try await service.perform(
            .importPhotos([
                AlbumImportSource { jpeg }, AlbumImportSource { Data([0]) }, AlbumImportSource { png },
            ]), owner: albumOwner)
        guard case .imported(let count, let failures) = result else {
            Issue.record("Expected batch result")
            return
        }
        #expect(count == 2 && failures.count == 1)
        let page = try await store.albumPage()
        #expect(page.items.count == 2)
        for item in page.items {
            #expect(try await store.readAlbum(item.id) == (item.metadata.mime == "image/png" ? png : jpeg))
        }
        let id = try #require(page.items.first?.id)
        await #expect(throws: PhotoAlbumError.unavailable) {
            _ = try await service.perform(.export(id), owner: albumOwner)
        }
        #expect(try await store.albumPage().items.count == 2)
        guard case .image(let thumbnail) = try await service.perform(.image(id, thumbnail: true), owner: albumOwner)
        else {
            Issue.record("Expected thumbnail")
            return
        }
        #expect(try await NativeAlbumImage.inspect(thumbnail).width == 2)
        await #expect(throws: NativePhotoFailure.invalidImage) {
            _ = try await NativeAlbumImage.inspect(Data(repeating: 0, count: 32 * 1024 * 1024 + 1))
        }
        try await records.shutdown()
    }
#endif

#if canImport(SQLite3)
    import SQLite3

    @Test func oldSchemaIsDiscardedInsteadOfMigratingMediaAndHistory() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        let database = try #require(handle)
        let seed = """
            PRAGMA user_version=1;
            CREATE TABLE dialogs(id INTEGER PRIMARY KEY,body TEXT);
            INSERT INTO dialogs VALUES(1,'old assistant'),(2,'old writer');
            CREATE TABLE media_files(id INTEGER PRIMARY KEY,relative_path TEXT);
            INSERT INTO media_files VALUES(1,'legacy.jpg');
            CREATE TABLE tasks(id INTEGER PRIMARY KEY,goal TEXT);
            INSERT INTO tasks VALUES(1,'old task');
            CREATE TABLE devices(id INTEGER PRIMARY KEY,name TEXT);
            INSERT INTO devices VALUES(1,'old device');
            """
        let seeded = sqlite3_exec(database, seed, nil, nil, nil)
        sqlite3_close(database)
        #expect(seeded == SQLITE_OK)
        let records = try SQLiteRepositories(url: url)
        let files = try MemoryFileStore()
        try await files.putIfAbsent(Data([1, 2]), key: "legacy.jpg")
        let store = MediaStore(repository: records.media, files: files)
        #expect(try await store.albumPage().items.isEmpty)
        #expect(try await store.readForInput("media_1", source: "assistant", input: "album-input") == nil)
        #expect(try await records.chat.current(agent: "assistant").count == 0)
        await #expect(throws: RecordStorageError.missingRecord) { try await records.chat.current(agent: "writer") }
        #expect(try await records.tasks.delegatedTasks(agent: "writer", before: nil, limit: 50).isEmpty)
        #expect(try await records.devices.selectedDevice() == nil)
        try await records.shutdown()
    }
#endif

private actor AlbumExportGate {
    var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        waiter?.resume()
        waiter = nil
    }
}
@Test func albumExportRejectsOverlappingMutationAndJoinsCommittedWork() async throws {
    let records = try SQLiteRepositories.temporary()
    let store = MediaStore(repository: records.media, files: try MemoryFileStore())
    let id = try await store.importPhoto(Data([1, 2]), owner: albumOwner, metadata: albumMetadata())
    let gate = AlbumExportGate()
    let service = PhotoAlbumService(photos: store, export: { _ in await gate.wait() })
    let export = Task { try await service.perform(.export(id), owner: albumOwner) }
    for _ in 0..<1000 {
        if await gate.entered { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    guard await gate.entered else {
        export.cancel()
        await gate.release()
        Issue.record("Export did not enter")
        return
    }
    await #expect(throws: PhotoAlbumError.busy) { _ = try await service.perform(.delete(id), owner: albumOwner) }
    export.cancel()
    await gate.release()
    guard case .completed = try await export.value else {
        Issue.record("Committed export must finish")
        return
    }
    #expect(try await store.albumPage().items.count == 1)
    try await records.shutdown()
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func albumUIRequestsExecuteThroughPhotographerAndGateway() async throws {
    let ui = UIContainer()
    try ui.start()
    let records = try SQLiteRepositories.temporary()
    let store = MediaStore(repository: records.media, files: try MemoryFileStore())
    let id = try await store.importPhoto(Data([1, 2]), owner: albumOwner, metadata: albumMetadata())
    let service = PhotoAlbumService(photos: store, export: { _ in throw PhotoAlbumError.unavailable })
    let manager = AgentManager()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, configurations: AgentConfigurations.all())
    let inputs = InputGateway(manager: manager, policy: policy)
    let binding = try BehaviorProtocolBindings.bind(PhotoAlbumActions.function(using: service))
    let gateway = await OutputGateway(
        manager: manager, requests: inputs,
        tools: try ToolRegistry(modules: [AlbumTools(definitions: [binding])]),
        actions: ChannelScheduler(registry: try ActionRegistry(definitions: [])),
        policy: policy, sink: { _ in })
    let session = PhotographerExecutionSession(
        manager: manager, output: gateway,
        agent: try PhotographerAgent(
            sessionID: "album-ui", uiAlbum: ui.album,
            context: AgentContextRepository(
                agent: .photographer, scope: UUID().uuidString, state: PhotographerContextState())))
    try await session.prepareForInteraction()
    guard case .page(let items, _) = try await ui.album.requests.submit(.page(nil)) else {
        Issue.record("Missing page")
        return
    }
    #expect(items.map(\.id) == [id])
    _ = try await ui.album.requests.submit(.delete(id))
    #expect(try await store.albumPage().items.isEmpty)
    await session.shutdown()
    await ui.stop()
    try await records.shutdown()
}

private struct AlbumTools: ToolModule { let definitions: [ActionBinding] }

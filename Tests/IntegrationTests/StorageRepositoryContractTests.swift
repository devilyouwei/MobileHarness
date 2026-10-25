import AgentCore
import Agents
import Foundation
import ModelKitRuntime
import StorageChat
import StorageCore
import StorageFiles
import StorageSQLite
import StorageTasks
import Testing

@testable import StorageMedia

private struct ContractDocument: Codable, Sendable, Equatable { let text: String }

@Test func documentRepositoriesShareRevisionAndFailureContract() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try FileDocumentStore<ContractDocument>(
        url: root.appendingPathComponent("document.json"), maximumBytes: 4096)
    let memory = try MemoryDocumentStore<ContractDocument>(maximumBytes: 4096)
    let repositories: [any DocumentStore<ContractDocument>] = [file, memory]
    for repository in repositories {
        #expect(try await repository.load() == nil)
        let first = try await repository.save(.init(text: "original"), expecting: nil)
        await #expect(throws: DocumentStorageError.conflict) {
            _ = try await repository.save(.init(text: "stale"), expecting: nil)
        }
        #expect(try await repository.refresh()?.value == first.value)
        await repository.invalidate()
        #expect(try await repository.load()?.revision == first.revision)
        await #expect(throws: DocumentStorageError.capacityExceeded) {
            _ = try await repository.save(.init(text: String(repeating: "x", count: 8192)), expecting: first.revision)
        }
        #expect(try await repository.load()?.revision == first.revision)
        let second = try await repository.save(.init(text: "replacement"), expecting: first.revision)
        #expect(second.revision != first.revision)
    }
    let reopened: any DocumentStore<ContractDocument> = try FileDocumentStore(
        url: root.appendingPathComponent("document.json"))
    #expect(try await reopened.load()?.value.text == "replacement")
    #expect(file.durability == .persistent && memory.durability == .memory)
}

@Test func binaryRepositoriesSharePublicationConfinementAndPaginationContract() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try DiskFileStore(root: root)
    let memory = try MemoryFileStore()
    let repositories: [any FileStore] = [file, memory]
    for repository in repositories {
        try await repository.putIfAbsent(Data([1, 2, 3]), key: "original.bin")
        await #expect(throws: (any Error).self) { try await repository.putIfAbsent(Data([9]), key: "original.bin") }
        #expect(try await repository.read("original.bin", maximumBytes: 3) == Data([1, 2, 3]))
        await #expect(throws: (any Error).self) { _ = try await repository.read("original.bin", maximumBytes: 2) }
        await #expect(throws: (any Error).self) { try await repository.putIfAbsent(Data([9]), key: "../escape") }
        for index in 0..<5 { try await repository.putIfAbsent(Data([UInt8(index)]), key: "item-\(index).bin") }
        var cursor: String?
        var keys: Set<String> = []
        repeat {
            let page = try await repository.listObjects(cursor: cursor, limit: 2)
            #expect(page.keys.count <= 2)
            for key in page.keys { #expect(keys.insert(key).inserted) }
            cursor = page.next
        } while cursor != nil
        #expect(keys.count == 6)
        try await repository.remove("original.bin")
        #expect(try await repository.info("original.bin") == nil)
    }
}

@Test func chatRepositoryRejectsTaskNamespaceMixing() throws {
    let first = try SQLiteRepositories.temporary()
    let second = try SQLiteRepositories.temporary()
    #expect(throws: RecordStorageError.invalidRecord) {
        _ = try ConversationRecordStore(repository: first.chat, tasks: second.tasks)
    }
    _ = try ConversationRecordStore(repository: first.chat, tasks: first.tasks)
}

private actor PausedBinaryStore: FileStore {
    nonisolated let durability: StorageDurability = .memory
    let base: any FileStore
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    var publishing: Bool { continuation != nil }
    init(base: any FileStore) { self.base = base }
    func putIfAbsent(_ data: Data, key: String) async throws {
        if !released { await withCheckedContinuation { continuation = $0 } }
        try await base.putIfAbsent(data, key: key)
    }
    func resume() {
        released = true
        continuation?.resume()
        continuation = nil
    }
    func read(_ key: String, maximumBytes: Int) async throws -> Data? {
        try await base.read(key, maximumBytes: maximumBytes)
    }
    func info(_ key: String) async throws -> BinaryObjectInfo? { try await base.info(key) }
    func remove(_ key: String) async throws { try await base.remove(key) }
    func listObjects(cursor: String?, limit: Int) async throws -> BinaryObjectPage {
        try await base.listObjects(cursor: cursor, limit: limit)
    }
    func closeListing(_ cursor: String) async { await base.closeListing(cursor) }
}

@Test func mediaAsyncPublicationSerializesReadsAndRejectsQueueOverflow() async throws {
    let records = try SQLiteRepositories.temporary()
    let files = PausedBinaryStore(base: try MemoryFileStore())
    let store = CapturedPhotoStore(repository: records.media, files: files)
    let owner = StorageOwner(
        namespace: "photos", source: "fixture", session: UUID().uuidString, input: UUID().uuidString)
    let publication = Task { try await store.save(Data([1, 2]), owner: owner) }
    for _ in 0..<2000 {
        if await files.publishing { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await files.publishing)
    let reads = (0..<16).map { _ in
        Task { try await store.readForInput("media_1", source: owner.source, input: owner.input) }
    }
    for _ in 0..<2000 {
        if await store.waitingOperationCount == 16 { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    guard await store.waitingOperationCount == 16 else {
        await files.resume()
        _ = try await publication.value
        for read in reads { _ = try await read.value }
        Issue.record("Media waiters failed to enter the bounded gate")
        return
    }
    #expect(try records.media.media("media_1")?.state == "pending")
    await #expect(throws: (any Error).self) {
        _ = try await store.readForInput("media_1", source: owner.source, input: owner.input)
    }
    await files.resume()
    #expect(try await publication.value == "media_1")
    for read in reads { #expect(try await read.value == Data([1, 2])) }
    #expect(try records.media.media("media_1")?.state == "ready")
}

@Test func cancelledCallerStillCommitsTheReceivedMessageAndTerminalState() async throws {
    let records = try SQLiteRepositories.temporary()
    let adapter = try ConversationRecordStore(repository: records.chat, tasks: records.tasks)
    let store = ConversationHistoryStore(records: adapter)
    let current = try await store.readCurrent()
    let input = UUID().uuidString
    _ = try await store.begin(
        id: input, user: "cancel request", request: [], expecting: current.token, model: "fixture")
    try await store.beginModelRequest(
        .init(id: UUID().uuidString, input: "cancel request", requestJSON: "[]"), for: input)
    try await store.append("received before cancellation", to: input)
    let cancellation = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await store.finish(input, state: .cancelled)
    }
    try await cancellation.value
    let messages = try await records.chat.messages(dialog: current.current.id, after: nil)
    #expect(messages.last?.body == "received before cancellation")
    #expect(messages.last?.state == "cancelled")
    #expect(messages.first?.state == "completed")
}

@Test func modelTransferDocumentRetainsOriginalUUIDWireRepresentation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("transfers.json")
    let original = Data(
        #"{"version":1,"revision":"00000000-0000-0000-0000-000000000125","value":[{"id":"gemma4-e2b","generation":"00000000-0000-0000-0000-000000000126","source":{"endpoint":"https://hf-mirror.com","allowsCellular":true}}]}"#
            .utf8)
    try original.write(to: url)
    let store = try FileDocumentStore<[ModelArtifactTransferRecord]>(url: url)
    let snapshot = try #require(try await store.load())
    let transfer = try #require(snapshot.value.first)
    #expect(transfer.id == "gemma4-e2b")
    #expect(transfer.generation == "00000000-0000-0000-0000-000000000126")
    #expect(transfer.source.endpoint == "https://hf-mirror.com" && transfer.source.allowsCellular)
    #expect(try Data(contentsOf: url) == original)
    _ = try await store.save(snapshot.value, expecting: snapshot.revision)
    struct OriginalTransfer: Decodable {
        let generation: UUID
    }
    struct OriginalEnvelope: Decodable {
        let version: Int
        let value: [OriginalTransfer]
    }
    let emitted = try JSONDecoder().decode(OriginalEnvelope.self, from: Data(contentsOf: url))
    #expect(emitted.version == 1 && emitted.value.first?.generation.uuidString == transfer.generation)
}

@Test func runtimeMemoryEvidenceBudgetRejectsWithoutPublishingPartialMutation() async throws {
    let repository = try AgentContextRepository(
        agent: .assistant, scope: UUID().uuidString, state: AssistantContextState()
    )
    let payload = Data(repeating: 1, count: 524_288)
    try await repository.update { context in
        for _ in 0..<64 { try context.append(.init(kind: "fixture", data: payload)) }
    }
    let committed = try await repository.snapshot()
    await #expect(throws: CommunicationError.capacityExceeded) {
        try await repository.update { try $0.append(.init(kind: "fixture", data: Data([1]))) }
    }
    let retained = try await repository.snapshot()
    #expect(retained.revision == committed.revision && retained.records.count == 64)
}

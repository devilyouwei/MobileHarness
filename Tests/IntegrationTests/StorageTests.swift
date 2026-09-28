import Foundation
import Storage
import Testing

@Test func boundedMemoryStreamUsesBytesAndSingleReaderWithoutAudioTypes() async throws {
    let stream = BoundedMemoryStream<Data>(maximumBytes: 4, maximumItems: 2, waitTimeout: .seconds(1)) {
        $0.count
    }
    try await stream.append(Data([1, 2, 3]))
    await #expect(throws: StorageError.capacityExceeded) { try await stream.append(Data([4, 5])) }
    #expect(try await stream.next() == Data([1, 2, 3]))
    try await stream.append(Data([4, 5]))
    await stream.finish()
    #expect(try await stream.next() == Data([4, 5]))
    #expect(try await stream.next() == nil)
}

@Test func memoryHandlesFenceNamespaceAndRetainCheckedOutValuePastExpiry() async throws {
    let store = MemoryLeaseStore<String>(
        capacity: 1, queueTTL: .seconds(1), readyTTL: .milliseconds(20), errorTTL: .seconds(1),
        onRemove: { _, _ in })
    let owner = StorageOwner(namespace: "documents", source: "editor", session: UUID(), input: UUID())
    let foreign = StorageOwner(namespace: "images", source: "editor", session: owner.session, input: owner.input)
    let id = UUID()
    try await store.register(id, owner: owner, value: "draft", cancel: {})
    #expect(try await store.begin(id) == "draft")
    await store.complete(id)
    await #expect(throws: StorageError.forbidden) { _ = try await store.checkout(id, owner: foreign) }
    #expect(try await store.checkout(id, owner: owner) == "draft")
    try await Task.sleep(for: .milliseconds(40))
    try await store.validate(id, owner: owner)
    try await store.release(id, owner: owner)
    await #expect(throws: StorageError.missing) { try await store.validate(id, owner: owner) }
    await store.shutdown()
}

@Test func documentCacheRefreshAndConflictPreserveDurableValues() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("settings.json")
    let first = try LocalDocumentStore<String>(url: url)
    let second = try LocalDocumentStore<String>(url: url)
    #expect(try await first.load() == nil)
    let initial = try await first.save("first", expecting: nil)
    #expect(try await second.load()?.value == "first")
    let changed = try await first.save("second", expecting: initial.revision)
    #expect(try await second.load()?.value == "first")
    await #expect(throws: DocumentStorageError.conflict) {
        try await second.save("stale", expecting: initial.revision)
    }
    #expect(try await second.refresh()?.revision == changed.revision)
    await first.invalidate()
    #expect(try await first.load()?.value == "second")
    let reopened = try LocalDocumentStore<String>(url: url)
    #expect(try await reopened.load()?.value == "second")
}

@Test func documentLimitsAndCorruptionNeverReplaceValidCache() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("settings.json")
    let store = try LocalDocumentStore<String>(url: url, maximumBytes: 128)
    let saved = try await store.save("valid", expecting: nil)
    await #expect(throws: DocumentStorageError.capacityExceeded) {
        try await store.save(String(repeating: "x", count: 129), expecting: saved.revision)
    }
    #expect(try await store.load()?.value == "valid")
    try Data(repeating: 65, count: 129).write(to: url)
    await #expect(throws: DocumentStorageError.capacityExceeded) { try await store.refresh() }
    try Data("invalid json".utf8).write(to: url)
    await #expect(throws: (any Error).self) { try await store.refresh() }
    #expect(try await store.load()?.value == "valid")
}

@Test func documentConcurrentWritersHaveOneWinner() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("settings.json")
    let first = try LocalDocumentStore<Int>(url: url)
    let second = try LocalDocumentStore<Int>(url: url)
    let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        for store in [first, second] {
            group.addTask {
                do {
                    try await store.save(1, expecting: nil)
                    return true
                } catch { return false }
            }
        }
        var count = 0
        for await succeeded in group where succeeded { count += 1 }
        return count
    }
    #expect(successes == 1)
}

@Test func documentUnsupportedVersionsAndNonFilesFailExplicitly() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("settings.json")
    let data = try JSONSerialization.data(withJSONObject: [
        "version": 2, "revision": UUID().uuidString, "value": "future",
    ])
    try data.write(to: url)
    let store = try LocalDocumentStore<String>(url: url)
    await #expect(throws: DocumentStorageError.unsupportedVersion) { try await store.load() }
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    await #expect(throws: DocumentStorageError.invalidFile) { try await store.save("new", expecting: nil) }
}

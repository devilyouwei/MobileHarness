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

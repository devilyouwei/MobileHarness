import Foundation
import StorageCore
import StorageFiles
import Testing

@Test(.actionCatalog) func localFileStoreRejectsTraversalAndSymbolicLinks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try DiskFileStore(root: root)
    _ = try await store.directory("staging/task")
    await #expect(throws: FileStorageError.self) { try await store.directory("../outside") }
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
    await #expect(throws: FileStorageError.self) { try await store.directory("escape/directory") }
}
@Test(.actionCatalog) func localFileStorePublishesDirectoryWithoutOverwritingPriorInstall() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try DiskFileStore(root: root)
    let stage = try await store.directory("staging/task")
    try Data("verified".utf8).write(to: stage.appendingPathComponent("file"))
    try await store.publish(from: "staging/task", to: "installed/model")
    #expect(try await store.read("installed/model/file", maximumBytes: 16) == Data("verified".utf8))
    _ = try await store.directory("staging/next")
    await #expect(throws: FileStorageError.self) {
        try await store.publish(from: "staging/next", to: "installed/model")
    }
    #expect(try await store.read("installed/model/file", maximumBytes: 16) == Data("verified".utf8))
    try await store.remove("installed/model")
    #expect(try await store.read("installed/model/file", maximumBytes: 16) == nil)
}

@Test(.actionCatalog) func enumeratedFilePathsRemainRelativeAcrossTrustedRootAliases() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try DiskFileStore(root: root)
    let stage = try await store.directory("staging/task")
    let child = stage.appendingPathComponent("model/weights.bin")
    try FileManager.default.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: child)
    let enumerated = try enumeratedFiles(stage)
    let file = try #require(enumerated.first { $0.lastPathComponent == "weights.bin" })
    #expect(try DiskFileStore.relativePath(of: file, within: stage) == "model/weights.bin")
    #expect(throws: FileStorageError.self) {
        try DiskFileStore.relativePath(of: root.appendingPathComponent("outside.bin"), within: stage)
    }
}
private func enumeratedFiles(_ root: URL) throws -> [URL] {
    let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    return enumerator.compactMap { $0 as? URL }
}

import Foundation
@_spi(ModelManagement) import ModelKit
@_spi(ModelAssembly) import ModelKitRuntime
import Testing

@Test func downloadDomainValidationAndNormalization() throws {
    let mirror = try ModelDownloadSource(endpoint: "  hf-mirror.com \n")
    #expect(mirror.endpoint == "https://hf-mirror.com")
    for invalid in [
        "http://host", "https://host/path", "https://user:secret@host", "https://host?q=1", "https://host#fragment", "",
    ] {
        #expect(throws: ModelArtifactError.self) { try ModelDownloadSource(endpoint: invalid) }
    }
}

private func fixtureCatalog(path: String = "config.json", prefix: String? = nil) throws -> ModelArtifactCatalog {
    var source: [String: Any] = [
        "kind": "huggingface", "repoId": "owner/repo", "revision": "r1", "allowPatterns": ["config.json"],
    ]
    if let prefix { source["stripPrefix"] = prefix }
    let record: [String: Any] = [
        "id": "fixture", "name": "Fixture", "capability": "chat", "directory": "Fixture",
        "source": source, "minimumOS": 1, "requiresPhysicalDevice": false,
        "license": "MIT", "estimatedBytes": 3, "requiredFiles": [path],
    ]
    return try ModelArtifactCatalog.decode(
        JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "packages": [record]]))
}
@Test func catalogRejectsUnsafeMembersAndPrefixSelection() throws {
    #expect(try fixtureCatalog().packages.count == 1)
    for path in ["../config.json", "/config.json", "a//b", "a/./b", "a\\b"] {
        #expect(throws: ModelArtifactError.self) { try fixtureCatalog(path: path) }
    }
    #expect(throws: ModelArtifactError.self) { try fixtureCatalog(prefix: "ios") }
    #expect(throws: ModelArtifactError.self) { try ModelArtifactCatalog.decode(Data(repeating: 0, count: 1_048_577)) }
}

@Test func retainedResourceHandleIsBlockedThroughMaintenance() async throws {
    let context = try ModelContext(loadGate: ModelLoadGate(maximumConcurrentLoads: 4), maximumLoadWaiters: 32)
    let resource = try context.resource { 42 }
    let first = try await resource.acquire()
    await resource.release(first.id)
    try await context.beginMaintenance()
    try await context.unload()
    await #expect(throws: CapabilityError.self) { try await resource.acquire() }
    await context.endMaintenance()
    let next = try await resource.acquire()
    #expect(next.model == 42)
    await resource.release(next.id)
}

private actor ArtifactFixtureStorage: ModelArtifactStorage {
    var records: [ModelArtifactTransferRecord] = []
    var removed = false
    func restoreTransfers() -> [ModelArtifactTransferRecord] { records }
    func saveTransfers(_ records: [ModelArtifactTransferRecord]) { self.records = records }
    func installed(_ artifact: ModelArtifact) -> Bool { !removed }
    func stage(_ artifact: ModelArtifact, task: String) throws -> URL { throw ModelArtifactError.storage }
    func publish(_ artifact: ModelArtifact, task: String) {}
    func discard(task: String) {}
    func remove(_ artifact: ModelArtifact) { removed = true }
}
@Test func resourceRemovalPersistsDiskStateWithoutClosingManager() async throws {
    let storage = ArtifactFixtureStorage()
    let manager = try ModelManager()
    try await manager.configureArtifacts(catalog: fixtureCatalog(), storage: storage)
    let before = try await manager.artifactSnapshots()
    #expect(before.first?.phase == .installed)
    try await manager.removeArtifact("fixture", quiesce: {})
    #expect(await storage.removed)
    let after = try await manager.artifactSnapshots()
    #expect(after.first?.phase == .notInstalled)
    await manager.shutdown()
}

private actor ArtifactInstallFixture: ModelArtifactStorage {
    let root: URL
    var records: [ModelArtifactTransferRecord] = []
    var published = false
    var failCompletionSave = false
    var completionSaveFailures = 0
    var removalFails = false
    func setRemovalFailure(_ value: Bool) { removalFails = value }
    func failCompletedWrites() { failCompletionSave = true }
    init(root: URL, records: [ModelArtifactTransferRecord] = []) {
        self.root = root
        self.records = records
    }
    func restoreTransfers() -> [ModelArtifactTransferRecord] { records }
    func saveTransfers(_ records: [ModelArtifactTransferRecord]) throws {
        if published && failCompletionSave {
            completionSaveFailures += 1
            throw ModelArtifactError.storage
        }
        self.records = records
    }
    func installed(_ artifact: ModelArtifact) -> Bool { published }
    func stage(_ artifact: ModelArtifact, task: String) throws -> URL {
        let directory = root.appendingPathComponent(task)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    func publish(_ artifact: ModelArtifact, task: String) { published = true }
    func discard(task: String) throws {
        let directory = root.appendingPathComponent(task)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    func remove(_ artifact: ModelArtifact) throws {
        if removalFails { throw ModelArtifactError.storage }
        published = false
    }
}
private struct FixtureHubDownloader: ModelArtifactDownloader {
    let complete: Bool
    var expectsInterruptedStage = false
    func download(
        _ artifact: ModelArtifact, source: ModelDownloadSource, into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        #expect(source.endpoint == "https://hf-mirror.com")
        #expect(artifact.source.repoId == "owner/repo")
        #expect(artifact.revision == "r1")
        #expect(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("stale.partial").path)
                == expectsInterruptedStage)
        if complete { try Data("abc".utf8).write(to: directory.appendingPathComponent("config.json")) }
        progress(1)
    }
}
@Test(.timeLimit(.minutes(1))) func incompleteHubSnapshotCannotPublishInstallation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ArtifactInstallFixture(root: root)
    let store = ModelArtifactStore(
        catalog: try fixtureCatalog(), storage: storage, downloader: FixtureHubDownloader(complete: false))
    try await store.download("fixture", source: ModelDownloadSource(endpoint: "hf-mirror.com"))
    while try await store.snapshots().first?.phase != .failed { await Task.yield() }
    #expect(await storage.published == false)
    #expect(await storage.records.count == 1)
    try await store.cancel("fixture")
    #expect(await storage.records.isEmpty)
}
@Test(.timeLimit(.minutes(1))) func completeHubSnapshotPublishesAfterRequiredFileValidation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ArtifactInstallFixture(root: root)
    let store = ModelArtifactStore(
        catalog: try fixtureCatalog(), storage: storage, downloader: FixtureHubDownloader(complete: true))
    try await store.download("fixture", source: ModelDownloadSource(endpoint: "hf-mirror.com"))
    while try await store.snapshots().first?.phase != .installed { await Task.yield() }
    #expect(await storage.published)
}

@Test(.timeLimit(.minutes(1))) func archiveMemberIntegrityAndDeflateInstallation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ArtifactInstallFixture(root: root)
    let catalog = try ModelArtifactCatalog.decode(
        Data(
            #"{"schemaVersion":2,"packages":[{"id":"fixture","name":"Fixture","capability":"pose","directory":"Fixture","source":{"kind":"urlArchive","revision":"r1","url":"https://github.com/owner/archive.zip","sha256":"3d8304dd82b54f274828100fcd6791802721b26502cb8af4615e16251fc3aad8"},"minimumOS":1,"requiresPhysicalDevice":false,"license":"MIT","requiredFiles":["model.mlpackage/Manifest.json"],"estimatedBytes":161}]}"#
                .utf8))
    let raw = try #require(
        Data(
            base64Encoded:
                "UEsDBBQAAAAIAGxaQ13CQSQ1BQAAAAMAAAAdAAAAbW9kZWwubWxwYWNrYWdlL01hbmlmZXN0Lmpzb25LTEoGAFBLAQIUAxQAAAAIAGxaQ13CQSQ1BQAAAAMAAAAdAAAAAAAAAAAAAACAAQAAAABtb2RlbC5tbHBhY2thZ2UvTWFuaWZlc3QuanNvblBLBQYAAAAAAQABAEsAAABAAAAAAAA="
        ))
    let store = ModelArtifactStore(catalog: catalog, storage: storage) { url, destination, _ in
        #expect(url.host == "github.com")
        try raw.write(to: destination)
        return destination
    }
    try await store.download("fixture", source: ModelDownloadSource(endpoint: "hf-mirror.com"))
    while true {
        let snapshot = try await store.snapshots().first
        if snapshot?.phase == .failed {
            Issue.record("Archive install failed: \(snapshot?.failure ?? "unknown")")
            break
        }
        if snapshot?.phase == .installed { break }
        await Task.yield()
    }
    #expect(await storage.published)
}

private struct CancellableHubDownloader: ModelArtifactDownloader {
    func download(
        _ artifact: ModelArtifact, source: ModelDownloadSource, into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        do { try await Task.sleep(for: .seconds(60)) } catch { throw URLError(.cancelled) }
        try Data("abc".utf8).write(to: directory.appendingPathComponent("config.json"))
    }
}
@Test(.timeLimit(.minutes(1))) func cancelledHubDownloadNeverPublishes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ArtifactInstallFixture(root: root)
    let store = ModelArtifactStore(
        catalog: try fixtureCatalog(), storage: storage, downloader: CancellableHubDownloader())
    try await store.download("fixture", source: ModelDownloadSource())
    while try await store.snapshots().first?.phase != .downloading { await Task.yield() }
    try await store.cancel("fixture")
    #expect(await storage.published == false)
    #expect(await storage.records.isEmpty)
    #expect(try await store.snapshots().first?.phase == .notInstalled)
}

private struct SymlinkHubDownloader: ModelArtifactDownloader {
    func download(
        _ artifact: ModelArtifact, source: ModelDownloadSource, into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("config.json"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
    }
}
@Test(.timeLimit(.minutes(1))) func hubSnapshotSymlinkCannotPublish() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ArtifactInstallFixture(root: root)
    let store = ModelArtifactStore(
        catalog: try fixtureCatalog(), storage: storage, downloader: SymlinkHubDownloader())
    try await store.download("fixture", source: ModelDownloadSource())
    while try await store.snapshots().first?.phase != .failed { await Task.yield() }
    #expect(await storage.published == false)
}

@Test(.timeLimit(.minutes(1))) func restoredHubRequestPreservesInterruptedStageBeforeReattachment() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let generation = UUID().uuidString
    let interrupted = root.appendingPathComponent(generation)
    try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: true)
    try Data("partial".utf8).write(to: interrupted.appendingPathComponent("stale.partial"))
    let storage = ArtifactInstallFixture(
        root: root,
        records: [
            ModelArtifactTransferRecord(
                id: "fixture", generation: generation, source: try ModelDownloadSource(endpoint: "hf-mirror.com"))
        ])
    let store = ModelArtifactStore(
        catalog: try fixtureCatalog(), storage: storage,
        downloader: FixtureHubDownloader(complete: true, expectsInterruptedStage: true))
    while try await store.snapshots().first?.phase != .installed { await Task.yield() }
    #expect(await storage.published)
    #expect(await storage.records.isEmpty)
}

private actor UnreadableReceiptStorage: ModelArtifactStorage {
    let failure: ModelArtifactError
    init(failure: ModelArtifactError = .integrity) { self.failure = failure }
    func restoreTransfers() -> [ModelArtifactTransferRecord] { [] }
    func saveTransfers(_ records: [ModelArtifactTransferRecord]) {}
    func installed(_ artifact: ModelArtifact) throws -> Bool { throw failure }
    func stage(_ artifact: ModelArtifact, task: String) throws -> URL { throw ModelArtifactError.storage }
    func publish(_ artifact: ModelArtifact, task: String) {}
    func discard(task: String) {}
    func remove(_ artifact: ModelArtifact) {}
}
@Test func malformedReceiptIsAnExplicitPackageFailure() async throws {
    let store = ModelArtifactStore(catalog: try fixtureCatalog(), storage: UnreadableReceiptStorage())
    let snapshot = try #require(await store.snapshots().first)
    #expect(snapshot.phase == .failed)
    #expect(snapshot.failure == "integrity")
    try await store.remove("fixture")
}

@Test func cancellationAfterInstallationPreservesInstalledStatus() async throws {
    let store = ModelArtifactStore(catalog: try fixtureCatalog(), storage: ArtifactFixtureStorage())
    #expect(try await store.snapshots().first?.phase == .installed)
    try await store.cancel("fixture")
    #expect(try await store.snapshots().first?.phase == .installed)
}

@Test(.timeLimit(.minutes(1))) func installedFilesSurviveTransferIndexWriteFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ArtifactInstallFixture(root: root)
    await storage.failCompletedWrites()
    let store = ModelArtifactStore(
        catalog: try fixtureCatalog(), storage: storage, downloader: FixtureHubDownloader(complete: true))
    try await store.download(
        "fixture", source: ModelDownloadSource(endpoint: "https://hf-mirror.com", allowsCellular: false))
    while try await store.snapshots().first?.failure == nil { await Task.yield() }
    let snapshot = try #require(await store.snapshots().first)
    #expect(snapshot.phase == .installed)
    #expect(snapshot.failure == "transferIndex")
    #expect(await storage.published)
    try await store.cancel("fixture")
    #expect(try await store.snapshots().first?.phase == .installed)
}

@Test(.timeLimit(.minutes(1))) func failedRemovalKeepsInstalledFilesAndSpecificWarning() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ArtifactInstallFixture(root: root)
    let store = ModelArtifactStore(
        catalog: try fixtureCatalog(), storage: storage, downloader: FixtureHubDownloader(complete: true))
    try await store.download(
        "fixture", source: ModelDownloadSource(endpoint: "https://hf-mirror.com", allowsCellular: false))
    while try await store.snapshots().first?.phase != .installed { await Task.yield() }
    await storage.setRemovalFailure(true)
    await #expect(throws: ModelArtifactError.storage) { try await store.remove("fixture") }
    let snapshot = try #require(await store.snapshots().first)
    #expect(snapshot.phase == .installed)
    #expect(snapshot.failure == "removal")
    await storage.setRemovalFailure(false)
    try await store.remove("fixture")
    #expect(try await store.snapshots().first?.phase == .notInstalled)
    #expect(try await store.snapshots().first?.failure == nil)
}

@Test(.timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["HARNESS_TEST_YOLO_ARCHIVE"] != nil))
func productionYOLOArchiveInstallsWithNativeExtractor() async throws {
    let archive = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HARNESS_TEST_YOLO_ARCHIVE"]))
    let catalogURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("MobileHarness/Resources/Models/model-catalog.json")
    var declaration = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
    let packages = try #require(declaration["packages"] as? [[String: Any]])
    declaration["packages"] = packages.filter { $0["id"] as? String == "yolo26n-pose" }
    let catalog = try ModelArtifactCatalog.decode(JSONSerialization.data(withJSONObject: declaration))
    let artifact = try #require(catalog.packages.first)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ArtifactInstallFixture(root: root)
    let store = ModelArtifactStore(catalog: catalog, storage: storage) { _, destination, _ in
        try FileManager.default.copyItem(at: archive, to: destination)
        return destination
    }
    try await store.download(artifact.id, source: ModelDownloadSource(endpoint: "https://huggingface.co"))
    var snapshot = try #require(await store.snapshots().first)
    while [.queued, .downloading, .verifying].contains(snapshot.phase) {
        await Task.yield()
        snapshot = try #require(await store.snapshots().first)
    }
    #expect(snapshot.phase == .installed)
    #expect(snapshot.failure == nil)
    #expect(await storage.published)
}

@Test func oldReceiptRevisionRemainsAnExplicitIncompatibleFailure() async throws {
    let store = ModelArtifactStore(
        catalog: try fixtureCatalog(), storage: UnreadableReceiptStorage(failure: .incompatible))
    let snapshot = try #require(await store.snapshots().first)
    #expect(snapshot.phase == .failed)
    #expect(snapshot.failure == "incompatible")
}

private actor ResumableHubFixture: ModelArtifactDownloader {
    private(set) var calls = 0
    private(set) var roots: [URL] = []
    func download(
        _ artifact: ModelArtifact, source: ModelDownloadSource, into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        calls += 1
        roots.append(directory)
        let file = directory.appendingPathComponent("config.json")
        if calls == 1 {
            try Data("abc".utf8).write(to: file)
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        }
        #expect(try Data(contentsOf: file) == Data("abc".utf8))
        progress(1)
    }
}
@Test(.timeLimit(.minutes(1))) func networkRetryReusesGenerationAndCompletedFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ArtifactInstallFixture(root: root)
    let downloader = ResumableHubFixture()
    let store = ModelArtifactStore(catalog: try fixtureCatalog(), storage: storage, downloader: downloader)
    try await store.download("fixture", source: ModelDownloadSource())
    while try await store.snapshots().first?.phase != .failed { await Task.yield() }
    #expect(try await store.snapshots().first?.failure == "network:-1005")
    while await storage.records.isEmpty { await Task.yield() }
    try await store.download("fixture", source: ModelDownloadSource())
    while try await store.snapshots().first?.phase != .installed { await Task.yield() }
    #expect(await downloader.calls == 2)
    #expect(await Set(downloader.roots.map(\.path)).count == 1)
    #expect(await storage.records.isEmpty)
}

@Test func artifactStorageCanRebindAfterItsFileScopeEnds() async throws {
    let first = ArtifactFixtureStorage()
    let second = ArtifactFixtureStorage()
    let catalog = try fixtureCatalog()
    await second.remove(catalog.packages[0])
    let manager = try ModelManager()
    try await manager.configureArtifacts(catalog: catalog, storage: first)
    #expect(try await manager.artifactSnapshots().first?.phase == .installed)
    async let firstRelease: Void = manager.releaseArtifacts()
    async let secondRelease: Void = manager.releaseArtifacts()
    _ = try await (firstRelease, secondRelease)
    await #expect(throws: ModelArtifactError.missingArtifact) { try await manager.artifactSnapshots() }
    try await manager.configureArtifacts(catalog: catalog, storage: second)
    #expect(try await manager.artifactSnapshots().first?.phase == .notInstalled)
    await manager.shutdown()
}

@Test func closedArtifactStoreRejectsNewWork() async throws {
    let store = ModelArtifactStore(catalog: try fixtureCatalog(), storage: ArtifactFixtureStorage())
    _ = try await store.snapshots()
    async let first: Void = store.close()
    async let second: Void = store.close()
    _ = try await (first, second)
    await #expect(throws: ModelArtifactError.busy) { try await store.snapshots() }
    await #expect(throws: ModelArtifactError.busy) {
        try await store.download("fixture", source: ModelDownloadSource(endpoint: ModelDownloadSource.official))
    }
}

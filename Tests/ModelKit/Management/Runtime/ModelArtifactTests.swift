import Foundation
@_spi(ModelManagement) import ModelKit
import Synchronization
import Testing

@_spi(ModelAssembly) @testable import ModelKitRuntime

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
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
            "MobileHarness/ModelKit/Support/Config/model-catalog.json")
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

@Test func installedPathCharacterPolicyRetainsUnicodeAndRejectsUnsafeComponents() {
    for path in ["model/config.json", "Gemma_4-e2b/weights.bin", "模型/权重.bin", "version.1/config.json"] {
        #expect(ModelArtifactCatalog.validInstalledPath(path))
    }
    for path in [
        "", ".", "..", "a/../b", "a//b", "a b/file", "a:b/file", "a/\\b", "a/\nfile",
        String(repeating: "a", count: 201),
    ] {
        #expect(!ModelArtifactCatalog.validInstalledPath(path))
    }
}

@Test func artifactObservationIsBoundedAndEndsAtItsOwningLifetime() async throws {
    let store = ModelArtifactStore(catalog: try fixtureCatalog(), storage: ArtifactFixtureStorage())
    var changes = try await store.observeChanges().makeAsyncIterator()
    #expect(try await changes.next() == 0)
    var others: [ModelKit.StateSignalListener<UInt64>] = []
    for _ in 0..<15 { others.append(try await store.observeChanges()) }
    #expect(others.count == 15)
    await #expect(throws: ModelArtifactError.busy) { try await store.observeChanges() }
    try await store.remove("fixture")
    #expect(try #require(try await changes.next()) > 0)
    try await store.close()
    #expect(try await changes.next() == nil)
}

@Test func catalogSelectsArchitectureBeforeDownloadAndRetainsSourceForOtherDevices() throws {
    let base = try fixtureCatalog()
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
    var packages = try #require(json["packages"] as? [[String: Any]])
    let variant: [String: Any] = [
        "source": [
            "kind": "huggingface", "repoId": "owner/repo", "revision": "aot-r2",
            "allowPatterns": ["ios/h18p/*"], "stripPrefix": "ios/h18p",
        ],
        "requiredFiles": ["decision.h18p.aimodelc/main.hash"], "estimatedBytes": 1024,
    ]
    packages[0]["architectureVariants"] = ["h18p": variant]
    json["packages"] = packages
    let catalog = try ModelArtifactCatalog.decode(JSONSerialization.data(withJSONObject: json))
    let selected = try #require(catalog.resolvingArchitecture("h18p").packages.first)
    #expect(selected.revision == "aot-r2")
    #expect(selected.source.stripPrefix == "ios/h18p")
    #expect(selected.requiredFiles == ["decision.h18p.aimodelc/main.hash"])
    #expect(selected.estimatedBytes == 1024)
    #expect(selected.architectureVariants == nil)
    for architecture: String? in [nil, "h17p"] {
        let source = try #require(catalog.resolvingArchitecture(architecture).packages.first)
        #expect(source.revision == "r1")
        #expect(source.requiredFiles == ["config.json"])
    }
    var invalid = variant
    invalid["requiredFiles"] = ["../escape"]
    packages[0]["architectureVariants"] = ["other-device": invalid]
    json["packages"] = packages
    #expect(throws: ModelArtifactError.self) {
        try ModelArtifactCatalog.decode(JSONSerialization.data(withJSONObject: json))
    }
}

@Test func productionDecisionCatalogUsesEdgeSourceWithoutRemovedLite() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
            "MobileHarness/ModelKit/Support/Config/model-catalog.json")
    let catalog = try ModelArtifactCatalog.read(url)
    let compiled = try catalog.resolvingArchitecture("h18p")
    let source = try catalog.resolvingArchitecture(nil)
    let edge = try #require(compiled.packages.first { $0.id == "d3-edge" })
    let macEdge = try #require(source.packages.first { $0.id == "d3-edge" })
    #expect(edge.revision == macEdge.revision)
    #expect(edge.source.revision == "0690c04ee1640c1c3fa11a882323751dda6d086a")
    #expect(edge.source.repoId == "hugging-mac/d3-edge-CoreAI")
    #expect(edge.source.stripPrefix == nil)
    #expect(edge.requiredFiles == macEdge.requiredFiles)
    #expect(edge.requiredFiles.contains("decision.aimodel/main.mlirb"))
    #expect(!edge.requiredFiles.contains { $0.contains("aimodelc") })
    #expect(!catalog.packages.contains { $0.id == "d3-lite" })
}

@Test func modelKitDiskStorageOwnsInstallationAndTransferPersistence() async throws {
    let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try ModelArtifactDiskStorage(root: root)
    let artifact = try fixtureCatalog().packages[0]
    let source = try ModelDownloadSource()
    let records = [ModelArtifactTransferRecord(id: artifact.id, generation: "transfer-1", source: source)]
    try await storage.saveTransfers(records)
    let reopened = try ModelArtifactDiskStorage(root: root)
    #expect(try await reopened.restoreTransfers().map(\.generation) == ["transfer-1"])
    let stage = try await storage.stage(artifact, task: "transfer-1")
    try Data("abc".utf8).write(to: stage.appendingPathComponent("config.json"))
    try await storage.publish(artifact, task: "transfer-1")
    #expect(try await reopened.installed(artifact))
    #expect(try await reopened.installedBytes(artifact) == 3)
    try Data("changed".utf8).write(to: reopened.installedRoot.appendingPathComponent("Fixture/config.json"))
    #expect(try await reopened.installed(artifact) == false)
    try await reopened.remove(artifact)
    #expect(try await storage.installed(artifact) == false)
}

@Test func modelKitDiskStorageRejectsTraversalAndSymlinkStages() async throws {
    let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try ModelArtifactDiskStorage(root: root)
    let artifact = try fixtureCatalog().packages[0]
    await #expect(throws: ModelArtifactError.self) { try await storage.stage(artifact, task: "../../escape") }
    let stage = try await storage.stage(artifact, task: "safe")
    try FileManager.default.createSymbolicLink(
        at: stage.appendingPathComponent("config.json"), withDestinationURL: root)
    await #expect(throws: ModelArtifactError.self) { try await storage.publish(artifact, task: "safe") }
    try await storage.discard(task: "safe")
    #expect(!FileManager.default.fileExists(atPath: stage.path))
}

@Test func modelKitCatalogIsBundledAndCustomDeclarationsPersist() async throws {
    #expect(try ModelArtifactCatalog.bundled().packages.contains { $0.id == "gemma4-e2b" })
    let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try ModelArtifactDiskStorage(root: root)
    let defaults = try ModelArtifactCatalog.bundled()
    let store = ModelArtifactStore(catalog: defaults, storage: storage)
    let artifact = try fixtureCatalog().packages[0]
    try await store.upsert(artifact)
    var edited = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(artifact)) as? [String: Any])
    edited["name"] = "Updated fixture"
    let updated = try JSONDecoder().decode(ModelArtifact.self, from: JSONSerialization.data(withJSONObject: edited))
    try await store.upsert(updated)
    let reopened = ModelArtifactStore(catalog: defaults, storage: try ModelArtifactDiskStorage(root: root))
    #expect(try await reopened.snapshots().first { $0.artifact.id == "fixture" }?.artifact.name == "Updated fixture")
    #expect(try await reopened.snapshots().contains { $0.artifact.id == "fixture" })
    try await reopened.remove("fixture")
    #expect(try await reopened.snapshots().allSatisfy { $0.artifact.id != "fixture" })
    try await reopened.upsert(artifact)
    let stage = try await storage.stage(artifact, task: "installed")
    try Data("abc".utf8).write(to: stage.appendingPathComponent("config.json"))
    try await storage.publish(artifact, task: "installed")
    await #expect(throws: ModelArtifactError.self) { try await store.upsert(artifact) }
    try await reopened.close()
    try await store.close()
}

@Test func directURLFileUsesModelKitPublication() async throws {
    let data = Data(
        """
        {"schemaVersion":2,"packages":[{"id":"url","name":"URL model","capability":"chat",
        "directory":"URLModel","source":{"kind":"urlFile","revision":"r1","url":"https://example.com/model.bin"},
        "minimumOS":1,"requiresPhysicalDevice":false,"license":"MIT","estimatedBytes":3,"requiredFiles":["model.bin"]}]}
        """.utf8)
    let catalog = try ModelArtifactCatalog.decode(data)
    let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try ModelArtifactDiskStorage(root: root)
    let store = ModelArtifactStore(
        catalog: catalog, storage: storage,
        download: { _, destination, _ in
            try Data("abc".utf8).write(to: destination)
            return destination
        })
    try await store.download("url", source: ModelDownloadSource())
    for _ in 0..<500 {
        if try await store.snapshots().first?.phase == .installed { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await storage.installed(catalog.packages[0]))
    try await store.close()
}

@Test func urlResumeDataIsBoundToSourceAndLimit() throws {
    let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent(".incoming-test")
    let url = URL(string: "https://example.com/model.bin")!
    let record = ArtifactDownloadTransport.ResumeRecord(url: url, maximumBytes: 32, data: Data([1, 2, 3]))
    try JSONEncoder().encode(record).write(to: destination.appendingPathExtension("resume"))
    #expect(
        try ArtifactDownloadTransport.resumeData(for: url, destination: destination, maximumBytes: 32) == record.data)
    #expect(try ArtifactDownloadTransport.resumeData(for: url, destination: destination, maximumBytes: 64) == nil)
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathExtension("resume").path))
}

@Test @MainActor func backgroundHandoffCompletesOnceAndReportsPreparationFailure() async throws {
    let service = ModelDownloadBackgroundService()
    service.connect { throw ModelArtifactError.storage }
    let id = "dev.mobileharness.artifacts.test-" + UUID().uuidString
    var completions = 0
    service.handleEvents(identifier: id) { completions += 1 }
    for _ in 0..<100 where completions == 0 { await Task.yield() }
    #expect(completions == 1)
    #expect(service.lastFailure != nil)
    ModelArtifactBackgroundEvents.finished(id)
    await Task.yield()
    #expect(completions == 1)
    service.handleEvents(identifier: "unrelated.session") { completions += 1 }
    #expect(completions == 2)
}

@Test func removedCatalogTransferDoesNotBlockRemainingModels() async throws {
    let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try ModelArtifactDiskStorage(root: root)
    let artifact = try fixtureCatalog().packages[0]
    _ = try await storage.stage(artifact, task: "retired-transfer")
    try await storage.saveTransfers([
        ModelArtifactTransferRecord(id: "d3-lite", generation: "retired-transfer", source: ModelDownloadSource())
    ])
    let reported = ArtifactFailureProbe()
    let store = ModelArtifactStore(
        catalog: try fixtureCatalog(), storage: storage,
        onFailure: { id, _ in
            reported.ids.withLock { $0.append(id) }
        })
    #expect(try await store.snapshots().map(\.artifact.id) == ["fixture"])
    #expect(reported.ids.withLock { $0 } == ["d3-lite"])
    #expect(try await storage.restoreTransfers().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("staging/retired-transfer").path))
    try await store.close()
}

private final class ArtifactFailureProbe: Sendable {
    let ids = Mutex<[String]>([])
}

@Test func decisionCatalogIncludesFourNativeModelsWithRuntimeFilesOnly() throws {
    let catalog = try ModelArtifactCatalog.bundled()
    let decisions = catalog.packages.filter { $0.capability == "decision" }
    #expect(Set(decisions.map(\.id)) == Set(["d3-edge", "vela3-fast", "vela3.1-fast", "laya-multilingual"]))
    for artifact in decisions {
        #expect(
            !artifact.requiredFiles.contains { path in
                ["readme", "license", "reference", ".py"].contains { path.lowercased().contains($0) }
            })
    }
    let laya = try #require(decisions.first { $0.id == "laya-multilingual" })
    #expect(laya.source.stripPrefix == "ios/wfp16-s512")
    #expect(laya.requiredFiles.contains("tokenizer/tokenizer.json"))
    #expect(laya.requiredFiles.contains("laya_ml_wfp16_s512.aimodel/main.mlirb"))
    let vela = try #require(decisions.first { $0.id == "vela3.1-fast" })
    #expect(vela.requiredFiles.contains("weights/model.safetensors"))
    #expect(vela.requiredFiles.contains("graphs/decision/model.aimodel/main.mlirb"))
}

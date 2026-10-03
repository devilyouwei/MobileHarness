import Foundation
import HuggingFace
import ModelKitRuntime
import Synchronization
import Testing

@testable import ModelKitHub

private func entries(_ json: String) throws -> [Git.TreeEntry] {
    try JSONDecoder().decode([Git.TreeEntry].self, from: Data(json.utf8))
}
@Test func hubSelectionExcludesDirectoriesAndUnselectedFiles() throws {
    let values = try entries(
        """
        [{"path":"model","type":"directory"},{"path":"model/weights.bin","type":"file","size":100},
         {"path":"README.md","type":"file","size":50}]
        """)
    let selected = try HuggingFaceArtifactDownloader.selectedFiles(values, patterns: ["model/**"])
    #expect(selected.map(\.path) == ["model/weights.bin"])
}
@Test func hubRejectsUnsafeAndUnboundedRemoteMetadata() throws {
    for json in [
        "[{\"path\":\"../weights\",\"type\":\"file\",\"size\":1}]",
        "[{\"path\":\"weights\",\"type\":\"file\",\"size\":34359738369}]",
        "[{\"path\":\"weights\",\"type\":\"file\"}]",
        "[{\"path\":\"directory\",\"type\":\"directory\"}]",
    ] {
        #expect(throws: ModelArtifactError.self) {
            try HuggingFaceArtifactDownloader.selectedFiles(entries(json), patterns: [])
        }
    }
}
@Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_TEST_HUB_ENDPOINT"] != nil))
func liveHubDownloadPublishesFilesAndIntermediateProgress() async throws {
    let endpoint = try #require(ProcessInfo.processInfo.environment["HARNESS_TEST_HUB_ENDPOINT"])
    let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("MobileHarness/Resources/Models/model-catalog.json")
    let artifact = try #require(ModelArtifactCatalog.read(catalog).packages.first { $0.id == "silero" })
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let samples = Mutex<[Double]>([])
    try await HuggingFaceArtifactDownloader().download(
        artifact, source: ModelDownloadSource(endpoint: endpoint, allowsCellular: false), into: root
    ) { value in
        samples.withLock { values in
            if values.count < 4096 { values.append(value) }
        }
    }
    let values = samples.withLock { $0 }
    #expect(values.contains { $0 > 0 && $0 < 1 })
    #expect(values.last == 1)
    for file in artifact.requiredFiles {
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path))
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".hub-snapshot").path))
}

@Test func completedFilesAndPersistedPlanResumeWithoutNetwork() async throws {
    let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("MobileHarness/Resources/Models/model-catalog.json")
    let artifact = try #require(ModelArtifactCatalog.read(catalog).packages.first { $0.id == "silero" })
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let member = HubBackgroundTransfer.Member(
        path: "existing.bin", url: URL(string: "https://example.invalid/existing")!, bytes: 3)
    let plan = HubBackgroundTransfer.Plan(
        id: artifact.id, revision: artifact.revision, endpoint: "https://huggingface.co", members: [member])
    try JSONEncoder().encode(plan).write(to: root.appendingPathComponent(".hub-plan.json"))
    try Data("abc".utf8).write(to: root.appendingPathComponent(member.path))
    try await HuggingFaceArtifactDownloader().download(artifact, source: ModelDownloadSource(), into: root) { _ in }
    #expect(try Data(contentsOf: root.appendingPathComponent(member.path)) == Data("abc".utf8))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".hub-plan.json").path))
}
@Test func backgroundPlansRejectUnsafePathsAndOversizedFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    for member in [
        HubBackgroundTransfer.Member(path: "../escape", url: URL(string: "https://example.invalid/file")!, bytes: 1),
        HubBackgroundTransfer.Member(
            path: "large", url: URL(string: "https://example.invalid/file")!, bytes: 34_359_738_369),
        HubBackgroundTransfer.Member(
            path: ".hub-plan.json", url: URL(string: "https://example.invalid/file")!, bytes: 1),
    ] {
        #expect(throws: ModelArtifactError.self) {
            try HubBackgroundTransfer(
                root: root,
                plan: .init(id: "test", revision: "r1", endpoint: "https://example.invalid", members: [member]),
                allowsCellular: false
            ) { _ in }
        }
    }
}

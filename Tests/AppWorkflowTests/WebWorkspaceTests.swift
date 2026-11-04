import Actions
import Foundation
import FunctionContracts
import ModelKit
import StorageFiles
import Testing
import UI

@Test func webDraftRequiresReadAndUniqueMatchWithoutPartialMutation() throws {
    var draft = try ArtifactDraft(files: ["index.html": "<h1>old</h1>", "style.css": "a a"])
    #expect(throws: ArtifactWorkspaceError.readRequired) { try draft.replace("index.html", old: "old", new: "new") }
    _ = try draft.read("index.html")
    try draft.replace("index.html", old: "old", new: "新图")
    #expect(draft.files["index.html"] == "<h1>新图</h1>")
    _ = try draft.read("style.css")
    #expect(throws: ArtifactWorkspaceError.ambiguousMatch) { try draft.replace("style.css", old: "a", new: "b") }
    #expect(draft.files["style.css"] == "a a")
    for path in ["../a.html", "/a.html", "a/../../b.js", "a\\b.css", "a//b.js", ".hidden.js", "secret.exe"] {
        #expect(throws: ArtifactWorkspaceError.invalidPath) { try draft.create(path, content: "x") }
    }
    #expect(throws: ArtifactWorkspaceError.existingFile) { try draft.create("index.html", content: "new") }
}

@Test func artifactPersistenceRequiresCurrentEntryAndIndexFields() throws {
    let project = ArtifactProject(
        id: UUID(), revision: UUID(), title: "Current", files: ["index.html": "index.html"], previousVersions: [])
    let encoded = try JSONEncoder().encode(project)
    #expect(try JSONDecoder().decode(ArtifactProject.self, from: encoded) == project)
    var oldProject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    oldProject.removeValue(forKey: "entryPath")
    let oldProjectData = try JSONSerialization.data(withJSONObject: oldProject)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(ArtifactProject.self, from: oldProjectData) }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ArtifactWorkspaceIndex.self, from: Data(#"{"projects":[]}"#.utf8))
    }
    let index = try JSONDecoder().decode(
        ArtifactWorkspaceIndex.self, from: JSONEncoder().encode(ArtifactWorkspaceIndex()))
    #expect(index.projects.isEmpty && index.pendingDeletions.isEmpty && index.drafts.isEmpty)
}

@Test func webWorkspacePersistsVersionsAndRejectsStaleWrites() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let disk = try DiskFileStore(root: root)
    let index = try FileDocumentStore<ArtifactWorkspaceIndex>(url: root.appendingPathComponent("index.json"))
    let workspace = ArtifactWorkspace(disk: disk, index: index)
    let id = UUID()
    var draft = try ArtifactDraft(files: ["index.html": "<h1>First</h1>", "assets/style.css": "h1 {color:red}"])
    let first = try await workspace.publish(id: id, expecting: nil, title: "Graph", draft: draft)
    let firstURL = try await workspace.entry(first)
    _ = try draft.read("index.html")
    try draft.replace("index.html", old: "First", new: "Second")
    let second = try await workspace.publish(id: id, expecting: first.revision, title: "Graph", draft: draft)
    #expect(try String(contentsOf: firstURL, encoding: .utf8) == "<h1>First</h1>")
    let secondURL = try await workspace.entry(second)
    #expect(try String(contentsOf: secondURL, encoding: .utf8) == "<h1>Second</h1>")
    await #expect(throws: ArtifactWorkspaceError.conflict) {
        try await workspace.publish(id: id, expecting: first.revision, title: "Graph", draft: draft)
    }
    let reopened = ArtifactWorkspace(
        disk: disk, index: try FileDocumentStore(url: root.appendingPathComponent("index.json")))
    #expect(try await reopened.project(id).revision == second.revision)
    let restored = try await reopened.version(id, revision: first.revision)
    #expect(restored.files["index.html"] == "<h1>First</h1>")
    #expect(restored.files["assets/style.css"] == "h1 {color:red}")
    try await reopened.delete(id)
    #expect(try await reopened.list().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: firstURL.path))
}

@Test func webWorkspaceRetainsDeletionIdentityWhenConfinedCleanupFails() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    defer { try? files.removeItem(at: root) }
    let index = try MemoryDocumentStore<ArtifactWorkspaceIndex>()
    let workspace = ArtifactWorkspace(disk: try DiskFileStore(root: root), index: index)
    let id = UUID()
    _ = try await workspace.publish(
        id: id, expecting: nil, title: "Delete",
        draft: ArtifactDraft(files: ["index.html": "<p>safe</p>"]))
    let original = root.appendingPathComponent(id.uuidString)
    let held = root.appendingPathComponent("held")
    try files.moveItem(at: original, to: held)
    try files.createSymbolicLink(at: original, withDestinationURL: held)
    await #expect(throws: FileStorageError.invalidPath) { try await workspace.delete(id) }
    #expect(try await index.load()?.value.pendingDeletions == [id])
    #expect(files.fileExists(atPath: held.path))
    try files.removeItem(at: original)
    try files.moveItem(at: held, to: original)
    try await workspace.delete(id)
    #expect(try await index.load()?.value.pendingDeletions == [])
    #expect(!files.fileExists(atPath: original.path))
}

@Test func artifactStreamsAreAtomicAndRejectStaleRanges() async throws {
    let editor = ArtifactEditing(draft: try ArtifactDraft(files: ["document.md": "Hello 🌍, keep this."]))
    let read = try await editor.read(path: "document.md")
    let stream = try await editor.begin(path: "document.md", reference: read.reference, start: 6, end: 7)
    for scalar in "世界 & <tag>" { try await editor.append(String(scalar), to: stream) }
    #expect(await editor.snapshot().files["document.md"] == "Hello 🌍, keep this.")
    #expect(try await editor.preview(stream).files["document.md"] == "Hello 世界 & <tag>, keep this.")
    _ = try await editor.finish(stream)
    await #expect(throws: ArtifactWorkspaceError.readRequired) {
        try await editor.begin(path: "document.md", reference: read.reference)
    }
    await #expect(throws: ArtifactWorkspaceError.conflict) { try await editor.append("late", to: stream) }
    let cancelled = try await editor.begin(path: "new.txt")
    try await editor.append("partial", to: cancelled)
    try await editor.cancel(cancelled)
    #expect(await editor.snapshot().files["new.txt"] == nil)
}

@Test func artifactMarkdownPublishesAndCheckpointDoesNotReplaceVersion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let index = try MemoryDocumentStore<ArtifactWorkspaceIndex>()
    let workspace = ArtifactWorkspace(disk: try DiskFileStore(root: root), index: index)
    let id = UUID()
    let initial = try ArtifactDraft(files: ["document.md": "# Hello"])
    let saved = try await workspace.publish(id: id, expecting: nil, title: "Note", draft: initial, entry: "document.md")
    try await workspace.checkpoint(
        .init(
            projectID: id, baseRevision: saved.revision, title: "Note", entry: "document.md",
            draft: ArtifactDraft(files: ["document.md": "# Unfinished"]), interrupted: true))
    #expect(try await workspace.project(id).files == initial.files)
    #expect(try await workspace.checkpoint(for: id)?.interrupted == true)
    #expect(try await workspace.entry(saved).lastPathComponent == "document.md")
}

@Test func artifactZIPPreservesNestedUTF8SourcesWithoutShell() throws {
    let files = ["index.html": "<h1>中文 🌍</h1>", "assets/style.css": "body{color:red}", "notes.md": "# 文档"]
    let data = try ArtifactArchive.zip(files)
    #expect(Array(data.prefix(4)) == [0x50, 0x4b, 0x03, 0x04])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
    defer { try? FileManager.default.removeItem(at: root) }
    try data.write(to: root)
    // Independent native archive reader verifies the standard format and CRC in a desktop test only.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-t", root.path]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(String(decoding: data, as: UTF8.self).contains("assets/style.css"))
    #expect(throws: ArtifactWorkspaceError.invalidPath) { try ArtifactArchive.zip(["../bad.txt": "bad"]) }
}

@Test func workspaceKeepsProjectsAndVersionsBeyondFormerQuotas() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let index = try FileDocumentStore<ArtifactWorkspaceIndex>(
        url: root.appendingPathComponent("index.json"), maximumBytes: 8 * 1024 * 1024)
    let workspace = ArtifactWorkspace(disk: try DiskFileStore(root: root), index: index)
    let ids = (0..<10).map { _ in UUID() }
    for id in ids {
        let draft = try ArtifactDraft(files: ["index.html": "<h1>Project</h1>"])
        try await workspace.checkpoint(
            .init(
                projectID: id, baseRevision: nil, title: "Project", entry: "index.html", draft: draft, interrupted: true
            ))
        _ = try await workspace.publish(id: id, expecting: nil, title: "Project", draft: draft)
    }
    let id = try #require(ids.first)
    var project = try await workspace.project(id)
    let original = project.revision
    for revision in 0..<18 {
        project = try await workspace.publish(
            id: id, expecting: project.revision, title: "Revised",
            draft: ArtifactDraft(files: ["index.html": "<h1>Revision \(revision)</h1>"]))
    }
    #expect(project.previousVersions.count == 18)
    #expect(try await workspace.version(id, revision: original).files["index.html"] == "<h1>Project</h1>")
    let reopened = ArtifactWorkspace(
        disk: try DiskFileStore(root: root),
        index: try FileDocumentStore(url: root.appendingPathComponent("index.json"), maximumBytes: 8 * 1024 * 1024))
    #expect(try await reopened.list().count == 10)
    #expect(try await reopened.project(id).previousVersions.count == 18)
}

@Test func largeMultiFileDraftStreamsPublishesAndRestoresWithoutSourceQuota() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = "<h1>" + String(repeating: "中文🌍", count: 24_000) + "</h1>"
    let editor = ArtifactEditing(draft: try ArtifactDraft())
    let stream = try await editor.begin(path: "index.html")
    for chunk in ["<h1>", String(repeating: "中文🌍", count: 24_000), "</h1>"] {
        try await editor.append(chunk, to: stream)
    }
    var draft = try await editor.finish(stream)
    for number in 0..<40 { try draft.create("files/file\(number).txt", content: String(repeating: "x", count: 2048)) }
    #expect(draft.files.count > 32 && source.utf8.count > 65_536)
    let workspace = ArtifactWorkspace(
        disk: try DiskFileStore(root: root),
        index: try FileDocumentStore(url: root.appendingPathComponent("index.json"), maximumBytes: 8 * 1024 * 1024))
    let id = UUID()
    let first = try await workspace.publish(id: id, expecting: nil, title: "Large", draft: draft)
    let entry = try await workspace.entry(first)
    #expect(try String(contentsOf: entry, encoding: .utf8).hasSuffix(source))
    _ = try draft.read("index.html")
    try draft.replace("index.html", old: "<h1>", new: "<h1 class=updated>")
    _ = try await workspace.publish(id: id, expecting: first.revision, title: "Large", draft: draft)
    #expect(try await workspace.version(id, revision: first.revision).files["index.html"] == source)
}

@Test func archiveRejectsZIP64RequirementsBeforeWritingTruncatedCounts() throws {
    let files = Dictionary(uniqueKeysWithValues: (0..<Int(UInt16.max)).map { ("file\($0).txt", "") })
    #expect(throws: ArtifactWorkspaceError.archiveFormatLimit) { try ArtifactArchive.zip(files) }
    #expect(ArtifactWorkspaceError.archiveFormatLimit.description.contains("ZIP64"))
}

@MainActor private final class WebWindowPageProbe: WebPagePresenting {
    let text: String
    var snapshots = 0
    var reads = 0
    var navigation: [String] = []
    init(_ text: String) { self.text = text }
    func loadRemote(_ url: URL) async throws -> WebPageObservation { try await observe() }
    func loadLocal(_ entry: URL) async throws -> WebPageObservation { try await observe() }
    func observe() async throws -> WebPageObservation {
        reads += 1
        return .init(url: "file:///private/project/index.html", title: text, text: text, diagnostics: "")
    }
    func snapshot() async throws -> Data {
        snapshots += 1
        return Data(text.utf8)
    }
    func navigate(_ command: String) async throws -> WebPageObservation {
        navigation.append(command)
        return try await observe()
    }
    func close() {}
}
private func webWindowInput(_ command: String, windowID: String, extra: [String: String] = [:]) -> FunctionInvocation {
    .init(
        call: .init(
            actionPath: .init(domain: "Web", module: "Page", function: command),
            parameters: extra.merging(["windowID": windowID]) { _, value in value }),
        context: .init(source: "assistant", sessionID: "fixture", inputID: UUID().uuidString),
        executionID: UUID().uuidString, results: ActionReportStore())
}
@Test @MainActor func webQueriesTargetSharedWriterWindowsWithoutRootPageOrWindowCreation() async throws {
    let windows = WindowState()
    windows.layout(width: 390, height: 750)
    windows.setAvailable(true)
    func create(_ title: String) async throws -> UUID {
        let task = Task { try await windows.present(content: .artifact, title: title) }
        let deadline = ContinuousClock.now + .seconds(20)
        while windows.windows.first(where: { $0.title == title }) == nil {
            guard ContinuousClock.now < deadline else { throw WindowError.unavailable }
            await Task.yield()
        }
        let value = try #require(windows.windows.first { $0.title == title })
        windows.complete(value.id, revision: value.revision, generation: windows.generation, success: true)
        return try await task.value
    }
    let first = try await create("Writer A")
    let second = try await create("Writer B")
    let root = WebWindowPageProbe("Root")
    let a = WebWindowPageProbe("Diagram A")
    let b = WebWindowPageProbe("Diagram B")
    let pages = [first: a, second: b]
    let service = WebExecutionService(
        page: root, windows: windows, pageForWindow: { pages[$0] },
        saveImage: { _, _ in "media_1" })
    let result = try await service.perform("inspect", invocation: webWindowInput("inspect", windowID: first.uuidString))
    let values = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
    #expect(values["text"] as? String == "Diagram A")
    #expect(values["windowID"] as? String == first.uuidString)
    #expect(values["url"] == nil)
    let screenshot = try await service.perform(
        "snapshot", invocation: webWindowInput("snapshot", windowID: second.uuidString))
    #expect(screenshot.contains("media_1"))
    #expect(a.reads == 1 && a.snapshots == 0 && b.snapshots == 1 && root.reads == 0)
    #expect(windows.windows.count == 2)
    await #expect(throws: ActionExecutionError.self) {
        try await service.perform("inspect", invocation: webWindowInput("inspect", windowID: "not-a-uuid"))
    }
    await #expect(throws: WindowError.missing) {
        try await service.perform("inspect", invocation: webWindowInput("inspect", windowID: UUID().uuidString))
    }
    #expect(windows.windows.count == 2)
    await service.stop()
    await windows.stop()
}

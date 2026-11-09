import Actions
import Foundation
import FunctionContracts
import ModelKit
import StorageCore
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

@Test func artifactProjectEncodingRequiresEntryField() throws {
    let project = ArtifactProject(
        id: try #require(WorkspaceID(agent: "writer", taskID: "task_1")), revision: UUID(), title: "Current",
        files: ["index.html": "index.html"])
    let encoded = try JSONEncoder().encode(project)
    #expect(try JSONDecoder().decode(ArtifactProject.self, from: encoded) == project)
    var oldProject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    oldProject.removeValue(forKey: "entryPath")
    let oldProjectData = try JSONSerialization.data(withJSONObject: oldProject)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(ArtifactProject.self, from: oldProjectData) }

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
    var remote: URL?
    var closed = false
    init(_ text: String) { self.text = text }
    func loadRemote(_ url: URL) async throws -> WebPageObservation {
        remote = url
        return try await observe()
    }
    func loadLocal(_ entry: URL) async throws -> WebPageObservation { try await observe() }
    func observe() async throws -> WebPageObservation {
        reads += 1
        return .init(
            url: remote?.absoluteString ?? "file:///private/project/index.html", title: text, text: text,
            diagnostics: "")
    }
    func snapshot() async throws -> Data {
        snapshots += 1
        return Data(text.utf8)
    }
    func navigate(_ command: String) async throws -> WebPageObservation {
        navigation.append(command)
        return try await observe()
    }
    func close() { closed = true }
}
private func webWindowInput(_ command: String, windowID: String? = nil, extra: [String: String] = [:])
    -> FunctionInvocation
{
    .init(
        call: .init(
            actionPath: .init(domain: "Web", module: "Page", function: command),
            parameters: windowID.map { extra.merging(["windowID": $0]) { _, value in value } } ?? extra),
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
    let a = WebWindowPageProbe("Diagram A")
    let b = WebWindowPageProbe("Diagram B")
    let pages = [first: a, second: b]
    let service = WebExecutionService(
        windows: windows, pageForWindow: { pages[$0] },
        createPage: { _, _ in throw WebPageError.unavailable }, removePage: { _ in },
        saveImage: { _, _ in "media_1" })
    let result = try await service.perform(
        "inspect", invocation: webWindowInput("inspect", windowID: try #require(windows.reference(for: first))))
    let values = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
    #expect(values["text"] as? String == "Diagram A")
    #expect(values["windowID"] as? String == (try #require(windows.reference(for: first))))
    #expect(values["url"] == nil)
    let screenshot = try await service.perform(
        "snapshot", invocation: webWindowInput("snapshot", windowID: try #require(windows.reference(for: second))))
    #expect(screenshot.contains("media_1"))
    #expect(a.reads == 1 && a.snapshots == 0 && b.snapshots == 1)
    #expect(windows.windows.count == 2)
    await #expect(throws: WindowError.self) {
        try await service.perform("inspect", invocation: webWindowInput("inspect", windowID: "not-a-uuid"))
    }
    await #expect(throws: WindowError.missing) {
        try await service.perform("inspect", invocation: webWindowInput("inspect", windowID: UUID().uuidString))
    }
    #expect(windows.windows.count == 2)
    await service.stop()
    await windows.stop()
}

@MainActor private final class BrowserPages {
    var pages: [UUID: WebWindowPageProbe] = [:]
    func page(_ id: UUID) -> WebWindowPageProbe {
        if let existing = pages[id] { return existing }
        let page = WebWindowPageProbe("Web")
        pages[id] = page
        return page
    }
}

@Test @MainActor func webBrowseOpensDistinctWindowsAndRetargetsOnlySpecifiedPage() async throws {
    let windows = WindowState()
    windows.layout(width: 390, height: 750)
    windows.setAvailable(true)
    let pages = BrowserPages()
    let service = WebExecutionService(
        windows: windows, pageForWindow: { pages.pages[$0] },
        createPage: { id, _ in pages.page(id) },
        removePage: { pages.pages.removeValue(forKey: $0)?.close() },
        saveImage: { _, _ in "media_1" })
    func browse(_ url: String) async throws -> (id: UUID, reference: String) {
        let previous = Set(windows.windows.map(\.id))
        let task = Task {
            try await service.perform("browse", invocation: webWindowInput("browse", extra: ["url": url]))
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !windows.windows.contains(where: { !previous.contains($0.id) }) {
            guard ContinuousClock.now < deadline else {
                task.cancel()
                throw WindowError.unavailable
            }
            await Task.yield()
        }
        let item = try #require(windows.windows.first { !previous.contains($0.id) })
        windows.complete(item.id, revision: item.revision, generation: windows.generation, success: true)
        let reference = try #require(windows.reference(for: item.id))
        #expect(try await task.value.contains(reference))
        return (item.id, reference)
    }
    let first = try await browse("https://example.com")
    let second = try await browse("https://example.org")
    let firstPage = try #require(pages.pages[first.id])
    let secondPage = try #require(pages.pages[second.id])
    #expect(firstPage !== secondPage)
    _ = try await service.perform(
        "browse", invocation: webWindowInput("browse", windowID: first.reference, extra: ["url": "https://example.net"])
    )
    #expect(windows.windows.count == 2 && windows.focusedID == first.id)
    #expect(firstPage.remote?.host == "example.net")
    #expect(secondPage.remote?.host == "example.org")
    let recent = try await service.perform("inspect", invocation: webWindowInput("inspect"))
    #expect(recent.contains(first.reference))
    try await service.closeWindow(invocation: webWindowInput("close", windowID: first.reference))
    #expect(firstPage.closed && !secondPage.closed)
    await service.stop()
    #expect(secondPage.closed)
    await windows.stop()
}

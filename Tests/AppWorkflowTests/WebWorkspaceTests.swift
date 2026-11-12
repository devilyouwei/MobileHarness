import Actions
import Foundation
import FunctionContracts
import ModelKit
import StorageCore
import StorageFiles
import Testing
import UI

@testable import Agents

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
        id: try #require(WorkspaceID(rawValue: "workspace_1")), revision: UUID(), title: "Current",
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
    var identity: String? = UUID().uuidString
    var snapshotIdentity: String? { closed ? nil : identity }
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
        prepareImage: { .init(data: $0, width: 10, height: 10) })
    let result = try await service.perform(
        "inspect", invocation: webWindowInput("inspect", windowID: try #require(windows.reference(for: first))))
    let values = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
    #expect(values["text"] as? String == "Diagram A")
    #expect(values["windowID"] as? String == (try #require(windows.reference(for: first))))
    #expect(values["url"] == nil)
    let screenshot = try await service.perform(
        "snapshot", invocation: webWindowInput("snapshot", windowID: try #require(windows.reference(for: second))))
    #expect(screenshot.contains("screenshotID") && !screenshot.contains("mediaID"))
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
        prepareImage: { .init(data: $0, width: 10, height: 10) })
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

@MainActor private func currentWebScreenshotFixture(
    prepare: @escaping @Sendable (Data) async throws -> WebScreenshotImage = {
        .init(data: $0, width: 10, height: 10)
    }
) async throws -> (WindowState, WebWindowPageProbe, WebExecutionService, String) {
    let windows = WindowState()
    windows.layout(width: 390, height: 750)
    windows.setAvailable(true)
    let opening = Task { try await windows.present(content: .web, title: "Current screenshot") }
    let deadline = ContinuousClock.now + .seconds(20)
    while windows.windows.isEmpty {
        guard ContinuousClock.now < deadline else { throw WindowError.unavailable }
        await Task.yield()
    }
    let item = try #require(windows.windows.first)
    windows.complete(item.id, revision: item.revision, generation: windows.generation, success: true)
    let id = try await opening.value
    let page = WebWindowPageProbe("Current pixels")
    let service = WebExecutionService(
        windows: windows, pageForWindow: { $0 == id ? page : nil },
        createPage: { _, _ in throw WebPageError.unavailable }, removePage: { _ in page.close() },
        prepareImage: prepare)
    return (windows, page, service, try #require(windows.reference(for: id)))
}

@Test @MainActor func webScreenshotStateKeepsOnlyCurrentImageAndScopesReads() async throws {
    let (windows, page, service, window) = try await currentWebScreenshotFixture()
    let firstReceipt = try await service.perform("snapshot", invocation: webWindowInput("snapshot", windowID: window))
    let first = try service.screenshotSnapshot(scope: "fixture")
    let firstID = try #require(first.images.first?.id)
    #expect(first.images.count == 1 && firstReceipt.contains(firstID) && !firstReceipt.contains("mediaID"))
    #expect(try service.screenshotSnapshot(scope: "foreign").images.isEmpty)
    #expect(try service.screenshotSnapshot(scope: "fixture").images.first?.id == firstID)
    #expect(page.snapshots == 1)
    _ = try await service.perform("inspect", invocation: webWindowInput("inspect", windowID: window))
    #expect(try service.screenshotSnapshot(scope: "fixture").images.first?.id == firstID)
    _ = try await service.perform("snapshot", invocation: webWindowInput("snapshot", windowID: window))
    let second = try service.screenshotSnapshot(scope: "fixture")
    #expect(second.images.count == 1 && second.images.first?.id != firstID)
    #expect(!String(decoding: second.facts, as: UTF8.self).contains(firstID))
    let priorIdentity = page.identity
    page.identity = UUID().uuidString
    #expect(try service.screenshotSnapshot(scope: "fixture").images.isEmpty)
    page.identity = priorIdentity
    #expect(try service.screenshotSnapshot(scope: "fixture").images.isEmpty)
    await service.stop()
    await windows.stop()
}

@Test @MainActor func webScreenshotStateClearsForWindowLifecycleAndUnavailablePage() async throws {
    let (windows, page, service, window) = try await currentWebScreenshotFixture()
    func capture() async throws {
        _ = try await service.perform("snapshot", invocation: webWindowInput("snapshot", windowID: window))
        #expect(try service.screenshotSnapshot(scope: "fixture").images.count == 1)
    }
    try await capture()
    try await service.pauseWindow(invocation: webWindowInput("pause", windowID: window))
    #expect(try service.screenshotSnapshot(scope: "fixture").images.isEmpty)
    try await capture()
    page.identity = nil
    #expect(try service.screenshotSnapshot(scope: "fixture").images.isEmpty)
    page.identity = UUID().uuidString
    try await capture()
    try await service.closeWindow(invocation: webWindowInput("close", windowID: window))
    #expect(try service.screenshotSnapshot(scope: "fixture").images.isEmpty && page.closed)
    await service.stop()
    await windows.stop()
}

@MainActor private final class WebPreparationProbe {
    var invalid = false
    var preparing = false
    func begin() { preparing = true }
}

@Test @MainActor func webScreenshotPreparationFailureDropsOldImage() async throws {
    let probe = WebPreparationProbe()
    let (windows, _, service, window) = try await currentWebScreenshotFixture { data in
        .init(data: await probe.invalid ? Data() : data, width: 10, height: 10)
    }
    _ = try await service.perform("snapshot", invocation: webWindowInput("snapshot", windowID: window))
    probe.invalid = true
    await #expect(throws: WebPageError.snapshotFailed) {
        try await service.perform("snapshot", invocation: webWindowInput("snapshot", windowID: window))
    }
    #expect(try service.screenshotSnapshot(scope: "fixture").images.isEmpty)
    await service.stop()
    await windows.stop()
}

@Test @MainActor func webScreenshotStopJoinsPreparationAndRejectsLateImage() async throws {
    let probe = WebPreparationProbe()
    let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let (windows, _, service, window) = try await currentWebScreenshotFixture { data in
        await probe.begin()
        for await _ in release.stream { break }
        return .init(data: data, width: 10, height: 10)
    }
    let capture = Task {
        try await service.perform("snapshot", invocation: webWindowInput("snapshot", windowID: window))
    }
    let deadline = ContinuousClock.now + .seconds(20)
    while !probe.preparing {
        guard ContinuousClock.now < deadline else {
            capture.cancel()
            throw WebPageError.timedOut
        }
        await Task.yield()
    }
    #expect(try service.screenshotSnapshot(scope: "fixture").images.isEmpty)
    await #expect(throws: WebPageError.busy) {
        try await service.perform("snapshot", invocation: webWindowInput("snapshot", windowID: window))
    }
    await service.stop()
    release.continuation.finish()
    await #expect(throws: CancellationError.self) { try await capture.value }
    #expect(try service.screenshotSnapshot(scope: "fixture").images.isEmpty)
    await #expect(throws: WebPageError.unavailable) {
        try await service.perform("snapshot", invocation: webWindowInput("snapshot", windowID: window))
    }
    await windows.stop()
}

@Test @MainActor func webScreenshotStateProjectsOnlyCurrentPixelsAcrossRequests() async throws {
    let (windows, page, service, window) = try await currentWebScreenshotFixture()
    let state = AgentStateContext()
    try state.open(session: "fixture")
    try state.registerMedia(
        "actions.web.screenshot", read: { try await service.screenshotSnapshot(scope: $0) }, reset: { _ in })
    let selected = try AgentConfigurations.skill("web-browsing").useStates
    #expect(selected.contains("actions.web.screenshot"))
    // Other UI facts are deliberately unregistered: choose the selected image source only.
    let sources = selected.filter { $0 == "actions.web.screenshot" }
    var priorID: String?
    for turn in 1...2 {
        _ = try await service.perform("snapshot", invocation: webWindowInput("snapshot", windowID: window))
        await state.synchronize(session: "fixture", dialog: "dialog_1")
        let snapshot = try await state.multimodalSnapshot(session: "fixture", names: sources)
        let id = try #require(snapshot.images.first?.id)
        #expect(id != priorID && snapshot.images.count == 1)
        let base = [ChatMessage(role: .user, content: "current page \(turn)")]
        for supported in [true, false] {
            let projection = try AgentChatContextBuilder.applyingStateImages(
                snapshot.images, to: base, user: base[0].content, supportsImages: supported)
            let request = try ChatRequest(messages: projection.messages)
            #expect(request.messages.count == 1 && request.messages[0].content == base[0].content)
            #expect(request.messages.flatMap { $0.images ?? [] }.map(\.id) == (supported ? [id] : []))
            #expect(projection.manifest?.contains("actions.web.screenshot") == true)
            #expect(projection.manifest?.contains(supported ? "attached" : "unsupported") == true)
            if let priorID { #expect(projection.manifest?.contains(priorID) == false) }
            if supported {
                let audit = try AgentModelRequestRecording(request).snapshot().requestJSON
                #expect(audit.contains(id))
                #expect(audit.contains(snapshot.images[0].data.base64EncodedString()))
            }
        }
        #expect(base[0].images == nil)
        #expect(try await state.multimodalSnapshot(session: "fixture", names: []).images.isEmpty)
        #expect(try await state.multimodalSnapshot(session: "fixture", names: sources).images.first?.id == id)
        priorID = id
    }
    #expect(page.snapshots == 2)
    try await service.pauseWindow(invocation: webWindowInput("pause", windowID: window))
    #expect(try await state.multimodalSnapshot(session: "fixture", names: sources).images.isEmpty)
    await service.stop()
    await windows.stop()
}

@Test @MainActor func webScreenshotChangedPageRejectsLatePreparedPixels() async throws {
    let probe = WebPreparationProbe()
    let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let (windows, page, service, window) = try await currentWebScreenshotFixture { data in
        await probe.begin()
        for await _ in release.stream { break }
        return .init(data: data, width: 10, height: 10)
    }
    let capture = Task {
        try await service.perform("snapshot", invocation: webWindowInput("snapshot", windowID: window))
    }
    let deadline = ContinuousClock.now + .seconds(20)
    while !probe.preparing {
        guard ContinuousClock.now < deadline else {
            capture.cancel()
            throw WebPageError.timedOut
        }
        await Task.yield()
    }
    page.identity = UUID().uuidString
    release.continuation.finish()
    await #expect(throws: WebPageError.unavailable) { try await capture.value }
    #expect(try service.screenshotSnapshot(scope: "fixture").images.isEmpty)
    await service.stop()
    await windows.stop()
}

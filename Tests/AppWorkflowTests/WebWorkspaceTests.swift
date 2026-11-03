import Actions
import Foundation
import FunctionContracts
import ModelKit
import StorageFiles
import Testing
import UI

@Test func webDraftRequiresReadAndUniqueMatchWithoutPartialMutation() throws {
    var draft = try WebDraft(files: ["index.html": "<h1>old</h1>", "style.css": "a a"])
    #expect(throws: WebWorkspaceError.readRequired) { try draft.replace("index.html", old: "old", new: "new") }
    _ = try draft.read("index.html")
    try draft.replace("index.html", old: "old", new: "新图")
    #expect(draft.files["index.html"] == "<h1>新图</h1>")
    _ = try draft.read("style.css")
    #expect(throws: WebWorkspaceError.ambiguousMatch) { try draft.replace("style.css", old: "a", new: "b") }
    #expect(draft.files["style.css"] == "a a")
    #expect(throws: WebWorkspaceError.capacity) {
        try draft.replace("index.html", old: "新图", new: String(repeating: "x", count: 65_537))
    }
    #expect(draft.files["index.html"] == "<h1>新图</h1>")
    for path in ["../a.html", "/a.html", "a/../../b.js", "a\\b.css", "a//b.js", ".hidden.js", "secret.exe"] {
        #expect(throws: WebWorkspaceError.invalidPath) { try draft.create(path, content: "x") }
    }
    #expect(throws: WebWorkspaceError.existingFile) { try draft.create("index.html", content: "new") }
}

@Test func webWorkspacePersistsVersionsAndRejectsStaleWrites() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let disk = try DiskFileStore(root: root)
    let index = try FileDocumentStore<WebWorkspaceIndex>(url: root.appendingPathComponent("index.json"))
    let workspace = WebWorkspace(disk: disk, index: index)
    let id = UUID()
    var draft = try WebDraft(files: ["index.html": "<h1>First</h1>", "assets/style.css": "h1 {color:red}"])
    let first = try await workspace.publish(id: id, expecting: nil, title: "Graph", draft: draft)
    let firstURL = try await workspace.entry(first)
    _ = try draft.read("index.html")
    try draft.replace("index.html", old: "First", new: "Second")
    let second = try await workspace.publish(id: id, expecting: first.revision, title: "Graph", draft: draft)
    #expect(try String(contentsOf: firstURL, encoding: .utf8) == "<h1>First</h1>")
    let secondURL = try await workspace.entry(second)
    #expect(try String(contentsOf: secondURL, encoding: .utf8) == "<h1>Second</h1>")
    await #expect(throws: WebWorkspaceError.conflict) {
        try await workspace.publish(id: id, expecting: first.revision, title: "Graph", draft: draft)
    }
    let reopened = WebWorkspace(
        disk: disk, index: try FileDocumentStore(url: root.appendingPathComponent("index.json")))
    #expect(try await reopened.project(id).revision == second.revision)
    try await reopened.delete(id)
    #expect(try await reopened.list().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: firstURL.path))
}

@Test func webWorkspaceRetainsDeletionIdentityWhenConfinedCleanupFails() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    defer { try? files.removeItem(at: root) }
    let index = try MemoryDocumentStore<WebWorkspaceIndex>()
    let workspace = WebWorkspace(disk: try DiskFileStore(root: root), index: index)
    let id = UUID()
    _ = try await workspace.publish(
        id: id, expecting: nil, title: "Delete",
        draft: WebDraft(files: ["index.html": "<p>safe</p>"]))
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

private actor WebScriptedModel: ChatCapability {
    nonisolated var availability: CapabilityAvailability { .available }
    nonisolated var supportsImages: Bool { true }
    var requests: [ChatRequest] = []
    private var replies: [String]
    init(_ replies: [String]) { self.replies = replies }
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        requests.append(request)
        guard !replies.isEmpty else { throw WebEditorError.stepLimit }
        let pair = InferenceSession<ChatEvent>.make(limits: try .init(), estimatedBytes: { $0.estimatedBytes })
        try pair.emitter.yield(.text(replies.removeFirst()))
        try pair.emitter.yield(.finished(.stop))
        pair.emitter.finish()
        return pair.session
    }
}

@Test func webEditorFeedsLatestRenderImageIntoPrivateContinuation() async throws {
    let model = WebScriptedModel([
        #"{"operation":"render"}"#, #"{"operation":"render"}"#,
        #"{"operation":"finish","summary":"done"}"#,
    ])
    _ = try await WebEditor(model: model).run(
        task: "Inspect", draft: WebDraft(files: ["index.html": "x"]), scope: "x",
        snapshot: { Data([1, 2, 3]) }, render: { _ in "Rendered" })
    let requests = await model.requests
    #expect(requests[1].messages.last?.images?.count == 1)
    #expect(requests[2].messages.reduce(0) { $0 + ($1.images?.count ?? 0) } == 1)
}

private actor WebWaitingModel: ChatCapability {
    nonisolated var availability: CapabilityAvailability { .available }
    var session: InferenceSession<ChatEvent>?
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        let pair = InferenceSession<ChatEvent>.make(limits: try .init(), estimatedBytes: { $0.estimatedBytes })
        session = pair.session
        return pair.session
    }
}
@Test func webEditorCancellationEndsPendingModelStream() async throws {
    let model = WebWaitingModel()
    let task = Task {
        try await WebEditor(model: model).run(task: "Wait", draft: WebDraft(), scope: "cancel") { _ in "Rendered" }
    }
    let deadline = ContinuousClock.now + .seconds(2)
    while await model.session == nil {
        guard ContinuousClock.now < deadline else { throw WebEditorError.unfinished }
        await Task.yield()
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}
private actor WebRenderProbe {
    var drafts: [WebDraft] = []
    func render(_ draft: WebDraft) -> String {
        drafts.append(draft)
        return "Rendered. No JavaScript errors."
    }
}
@Test func webEditorRecoversFromUnobservedEditAndContinuesIndependentRequests() async throws {
    let model = WebScriptedModel([
        #"{"operation":"replace","path":"index.html","old":"First","new":"Second"}"#,
        #"{"operation":"read","path":"index.html"}"#,
        #"{"operation":"replace","path":"index.html","old":"First","new":"Second"}"#,
        #"{"operation":"finish","summary":"done"}"#,
        #"{"operation":"render"}"#,
        #"{"operation":"finish","summary":"完成局部修改"}"#,
    ])
    let probe = WebRenderProbe()
    let result = try await WebEditor(model: model).run(
        task: "Change heading", draft: WebDraft(files: ["index.html": "<h1>First</h1>", "app.js": "let a=1;"]),
        scope: "project"
    ) { await probe.render($0) }
    #expect(result.requests == 6)
    #expect(result.draft.files["index.html"] == "<h1>Second</h1>")
    #expect(result.draft.files["app.js"] == "let a=1;")
    #expect(await probe.drafts.count == 1)
    let requests = await model.requests
    #expect(Set(requests.map(\.context.requestID)).count == 6)
    #expect(requests.allSatisfy { $0.context.scopeID == "project" && $0.tools.isEmpty })
    #expect(requests.allSatisfy { $0.messages.last?.content.contains("USER TASK:\nChange heading") == true })
    #expect(requests[1].messages.last?.content.contains("readRequired") == true)
    #expect(requests[4].messages.last?.content.contains("unfinished") == true)
}

@Test func webEditorPropagatesRenderFailure() async throws {
    let model = WebScriptedModel([#"{"operation":"render"}"#])
    await #expect(throws: CocoaError.self) {
        try await WebEditor(model: model).run(task: "Render", draft: WebDraft(files: ["index.html": "x"]), scope: "x") {
            _ in throw CocoaError(.fileWriteNoPermission)
        }
    }
    let full = WebScriptedModel([#"{"operation":"render"}"#])
    await #expect(throws: WebWorkspaceError.capacity) {
        try await WebEditor(model: full).run(task: "Render", draft: WebDraft(files: ["index.html": "x"]), scope: "x") {
            _ in throw WebWorkspaceError.capacity
        }
    }
}

@MainActor private final class WebPageProbe: WebPagePresenting {
    var entries: [URL] = []
    var closed = false
    func loadRemote(_ url: URL) async throws -> WebPageObservation { try await observe() }
    func loadLocal(_ entry: URL) async throws -> WebPageObservation {
        entries.append(entry)
        return try await observe()
    }
    func observe() async throws -> WebPageObservation {
        .init(url: "file:///fixture/index.html", title: "Fixture", text: "Diagram", diagnostics: "")
    }
    func snapshot() async throws -> Data { Data([1, 2, 3]) }
    func navigate(_ command: String) async throws -> WebPageObservation { try await observe() }
    func close() { closed = true }
}

@Test @MainActor func webActionsCreateThenPartiallyReviseSameDurableProject() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = WebWorkspace(disk: try DiskFileStore(root: root), index: try MemoryDocumentStore())
    let model = WebScriptedModel([
        #"{"operation":"create","path":"index.html","content":"<h1>First</h1>"}"#,
        #"{"operation":"render"}"#, #"{"operation":"finish","summary":"Created"}"#,
        #"{"operation":"read","path":"index.html"}"#,
        #"{"operation":"replace","path":"index.html","old":"First","new":"Second"}"#,
        #"{"operation":"render"}"#, #"{"operation":"finish","summary":"Updated"}"#,
    ])
    let windows = WindowState()
    windows.setAvailable(true)
    windows.layout(width: 390, height: 750)
    let page = WebPageProbe()
    let service = WebExecutionService(page: page, windows: windows, workspace: workspace, model: model) {
        bytes, input in
        #expect(bytes == Data([1, 2, 3]))
        #expect(input.context.source == "assistant" && input.context.sessionID == "web-fixture")
        return "media_1"
    }
    func invocation(_ parameters: [String: String]) -> FunctionInvocation {
        .init(
            call: .init(actionPath: .init(domain: "Web", module: "Page", function: "develop"), parameters: parameters),
            context: .init(source: "assistant", sessionID: "web-fixture", inputID: UUID().uuidString),
            executionID: UUID().uuidString, results: ActionReportStore())
    }
    let first = Task {
        try await WebActions.develop(invocation: invocation(["task": "Create a diagram"]), using: service)
    }
    let deadline = ContinuousClock.now + .seconds(2)
    while windows.windows.isEmpty {
        guard ContinuousClock.now < deadline else { throw WebPageError.timedOut }
        await Task.yield()
    }
    let window = try #require(windows.windows.first)
    windows.complete(window.id, revision: window.revision, generation: windows.generation, success: true)
    let raw = try await first.value
    let receipt = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    let id = try #require(receipt["projectID"] as? String)
    #expect(receipt["mediaID"] as? String == "media_1")
    #expect(!raw.contains("<h1>"))
    let second = try await WebActions.develop(
        invocation: invocation(["task": "Change the heading", "projectID": id]), using: service)
    #expect(second.contains(id))
    #expect(page.entries.count == 2 && page.entries[0] != page.entries[1])
    let saved = try await workspace.project(#require(UUID(uuidString: id)))
    #expect(saved.files["index.html"] == "<h1>Second</h1>")
    #expect(saved.previousVersions.count == 1)
    await service.stop()
    #expect(page.closed)
    await windows.stop()
}

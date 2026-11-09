import Actions
import AgentCore
import Foundation
import ModelKit
import Testing

@testable import Agents

private actor WriterScriptModel: ChatCapability {
    nonisolated var availability: CapabilityAvailability { .available }
    nonisolated let supportsToolCalls = true
    private var scripts: [[ChatEvent]]
    var requests: [ChatRequest] = []
    init(_ scripts: [[ChatEvent]]) { self.scripts = scripts }
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        requests.append(request)
        guard !scripts.isEmpty else { throw WriterFailure.incomplete }
        let script = scripts.removeFirst()
        let pair = InferenceSession<ChatEvent>.make(
            limits: try .init(capacity: 256, maximumEventBytes: nil), estimatedBytes: { $0.estimatedBytes })
        for event in script { try pair.emitter.yield(event) }
        pair.emitter.finish()
        return pair.session
    }
}
private actor WriterStreamProbe {
    var chunks: [String] = []
    var completed = false
    var aborted = false
    func append(_ text: String) { chunks.append(text) }
    func complete() -> String {
        completed = true
        return "Saved draft"
    }
    func abort() { aborted = true }
}
private func writerDefinitions() throws -> [ChatToolDefinition] {
    try ["edit", "finish", "list", "read", "render", "replace"].map { name in
        try .init(
            declaration: JSONSerialization.data(withJSONObject: [
                "type": "function",
                "function": [
                    "name": name, "parameters": ["type": "object", "properties": [:]],
                ],
            ]))
    }
}
@Test(arguments: [false, true]) func writerSeparatesNativeControlAndUnescapedContentStream(large: Bool) async throws {
    let fragment = "<h1>中文 & \"emoji 🌍\"</h1>"
    let chunks =
        large ? Array(repeating: String(repeating: fragment, count: 1000), count: 12) : fragment.map(String.init)
    let source = chunks.joined()
    let model = WriterScriptModel([
        [
            .text(String(repeating: "Planning ", count: 1000)),
            .toolCall(.init(id: "edit", name: "edit", argumentsJSON: "{}")),
            .finished(.toolCalls),
        ],
        chunks.map(ChatEvent.text) + [.finished(.stop)],
        [
            .toolCall(.init(id: "finish", name: "finish", argumentsJSON: "{}")),
            .finished(.toolCalls),
        ],
    ])
    let probe = WriterStreamProbe()
    let tools = WriterTools(
        definitions: try writerDefinitions(),
        execute: { call in
            call.id == "edit"
                ? .write(streamID: "runtime-owned", instruction: "Create HTML", context: "") : .finished("完成")
        },
        append: { id, chunk in
            #expect(id == "runtime-owned")
            await probe.append(chunk)
        },
        complete: { _ in await probe.complete() }, abort: { _ in await probe.abort() })
    #expect(try await WriterWorkflow(model: model).run(goal: "画图", scope: "task", tools: tools) == "完成")
    #expect(await probe.chunks.joined() == source)
    #expect(await probe.completed)
    #expect(await !probe.aborted)
    let requests = await model.requests
    #expect(requests.count == 3)
    #expect(requests.allSatisfy { $0.maximumOutputTokens == nil })
    #expect(requests[1].tools.isEmpty)
    #expect(!requests[2].messages.contains { $0.content.contains(source) })
    #expect(requests[2].messages.contains { $0.role == .tool && $0.toolCallID == "edit" })
}
@Test func writerTruncatedContentAbortsWithoutCommitting() async throws {
    let model = WriterScriptModel([
        [
            .toolCall(.init(id: "edit", name: "edit", argumentsJSON: "{}")),
            .finished(.toolCalls),
        ],
        [.text("partial"), .finished(.lengthLimit)],
        [.text("partial"), .finished(.lengthLimit)],
        [.text("partial"), .finished(.lengthLimit)],
    ])
    let probe = WriterStreamProbe()
    let tools = WriterTools(
        definitions: try writerDefinitions(),
        execute: { _ in .write(streamID: "s", instruction: "Text", context: "") },
        append: { _, text in await probe.append(text) }, complete: { _ in await probe.complete() },
        abort: { _ in await probe.abort() })
    await #expect(throws: WriterRecoveryFailure.self) {
        try await WriterWorkflow(model: model).run(goal: "Write", scope: "t", tools: tools)
    }
    #expect(await probe.aborted)
    #expect(await !probe.completed)
}

@Test func artifactIncrementalCheckpointsHandleSplitQuotesFencesAndUnicode() throws {
    var html = Actions.ArtifactContentParser(path: "index.html")
    var source = ""
    for chunk in ["<h1 title=\"", "a>", "b\">中", "文 & e", "\u{301}", "</h1>"] {
        source += chunk
        html.append(chunk)
    }
    #expect(html.checkpoint(in: source) == source)
    var pending = Actions.ArtifactContentParser(path: "index.html")
    pending.append("<div title=\"unfinished>")
    #expect(pending.checkpoint(in: "<div title=\"unfinished>").isEmpty)
    var markdown = Actions.ArtifactContentParser(path: "document.md")
    var text = ""
    for chunk in ["`", "`", "`js\n", "const a = 1;", "\n", "```\n"] {
        text += chunk
        markdown.append(chunk)
    }
    #expect(markdown.checkpoint(in: text) == text)
}

@Test func writerCompletesWhenModelFinishesBeyondFormerRoundBudget() async throws {
    let steps = (0..<30).map { index -> [ChatEvent] in
        [
            .toolCall(.init(id: "read-\(index)", name: "list", argumentsJSON: "{}")),
            .finished(.toolCalls),
        ]
    }
    let model = WriterScriptModel(
        steps + [
            [
                .toolCall(.init(id: "finish", name: "finish", argumentsJSON: "{}")),
                .finished(.toolCalls),
            ]
        ])
    let tools = WriterTools(
        definitions: try writerDefinitions(),
        execute: { $0.id == "finish" ? .finished("完成") : .observation("Files checked") },
        append: { _, _ in }, complete: { _ in "" }, abort: { _ in })
    #expect(try await WriterWorkflow(model: model).run(goal: "检查多文件后完成", scope: "task", tools: tools) == "完成")
    #expect(await model.requests.count == 31)
    #expect(await model.requests.allSatisfy { $0.messages[1].content == "检查多文件后完成" })
}

@Test @MainActor func artifactMarkdownRendersStructuredContentAndEscapesMarkup() async throws {
    let rendered = try await ArtifactTextRendering.document(
        """
        # Title

        **bold** *italic* `code`
        [safe](https://example.com) [bad](javascript:alert)

        <script>bad</script>

        1. first
           - nested

        | 名称 | 状态 |
        | --- | --- |
        | 测试 | 完成 |
        """,
        markdown: true)
    #expect(rendered.html.contains("<strong>bold</strong>"))
    #expect(rendered.html.contains("<em>italic</em>"))
    #expect(rendered.html.contains("<code>code</code>"))
    #expect(rendered.html.contains("href=\"https://example.com\""))
    #expect(!rendered.html.contains("href=\"javascript:"))
    #expect(!rendered.html.contains("<script>"))
    #expect(rendered.html.contains("&lt;script&gt;"))
    #expect(rendered.html.contains("<ol>") && rendered.html.contains("<ul>"))
    #expect(rendered.html.contains("<table>") && rendered.html.contains("<td>完成</td>"))
    #expect(rendered.diagnostics.isEmpty)
}

@Test @MainActor func artifactMarkdownRendersMultipleMermaidImagesAndKeepsInvalidSource() async throws {
    let rendered = try await ArtifactTextRendering.document(
        """
        # 软件工程流程图

        ```mermaid
        flowchart TD
          A[开始] --> B{可行}
          B -->|是| C[需求分析]
          B -->|否| D[结束]
        ```

        ```mermaid
        flowchart TD
          A[broken
        ```

        ~~~MERMAID
        sequenceDiagram
          开发者->>系统: 提交
        ~~~

        ```text
        flowchart TD
        ```
        """,
        markdown: true)
    let pattern = try NSRegularExpression(pattern: #"data:image/svg\+xml;base64,([A-Za-z0-9+/=]+)"#)
    let html = rendered.html as NSString
    let images = pattern.matches(in: rendered.html, range: NSRange(location: 0, length: html.length))
    try #require(images.count == 2, "Diagnostics: \(rendered.diagnostics)")
    let charts = try images.map { match in
        String(decoding: try #require(Data(base64Encoded: html.substring(with: match.range(at: 1)))), as: UTF8.self)
    }
    #expect(charts[0].contains("<svg") && charts[0].contains("需求分析"))
    #expect(charts[1].contains("<svg") && charts[1].contains("提交"))
    #expect(rendered.diagnostics.contains("Mermaid 图表 2 无法渲染"))
    #expect(rendered.html.contains("A[broken"))
    #expect(rendered.html.contains("<code class=\"language-text\">flowchart TD"))
    #expect(!rendered.html.contains("<script"))
}
@Test func artifactRemovalPreservesUnrelatedReadReferences() async throws {
    let editor = ArtifactEditing(draft: try .init(files: ["index.html": "home", "old.css": "red"]))
    let reference = try await editor.read(path: "old.css")
    let home = try await editor.read(path: "index.html")
    let next = try await editor.remove(path: "old.css", reference: reference.reference)
    #expect(next.files["old.css"] == nil)
    #expect(next.files["index.html"] == "home")
    let stream = try await editor.begin(path: "index.html", reference: home.reference)
    try await editor.cancel(stream)
    await #expect(throws: ArtifactWorkspaceError.readRequired) {
        try await editor.begin(path: "old.css", reference: reference.reference)
    }
}

@Test func writerCancellationJoinsUncancelledDraftCleanup() async throws {
    let model = WriterScriptModel([
        [
            .toolCall(.init(id: "edit", name: "edit", argumentsJSON: "{}")),
            .finished(.toolCalls),
        ],
        [.text("partial"), .finished(.stop)],
    ])
    let probe = WriterStreamProbe()
    let tools = WriterTools(
        definitions: try writerDefinitions(),
        execute: { _ in .write(streamID: "s", instruction: "Write", context: "") },
        append: { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }, complete: { _ in await probe.complete() },
        abort: { _ in
            #expect(!Task.isCancelled)
            await probe.abort()
        })
    let task = Task { try await WriterWorkflow(model: model).run(goal: "Write", scope: "task", tools: tools) }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await probe.aborted)
    #expect(await !probe.completed)
}

@Test func writerRelatedContextAndLineReadsKeepUnicodeAndFileVersions() async throws {
    let editor = ArtifactEditing(
        draft: try .init(files: [
            "index.html": "<div class=diagram>🌍</div>\nkeep\nend", "style.css": ".diagram {color:red}",
        ]))
    let html = try await editor.readLines(path: "index.html", line: 2, count: 1)
    #expect(html.content == "keep\n")
    #expect(html.startLine == 2)
    let css = try await editor.read(path: "style.css")
    #expect(try await editor.relatedContext([css.reference]).contains(".diagram {color:red}"))
    let stream = try await editor.begin(path: "index.html", reference: html.reference)
    try await editor.append("changed\n", to: stream)
    _ = try await editor.finish(stream)
    #expect(try await editor.relatedContext([css.reference]).contains(".diagram"))
    await #expect(throws: ArtifactWorkspaceError.readRequired) { try await editor.relatedContext([html.reference]) }
    #expect(await editor.snapshot().files["index.html"] == "<div class=diagram>🌍</div>\nchanged\nend")
}

@Test func writerSubtreeMovesAreAtomicAndRequireEveryAffectedRead() async throws {
    let initial = try ArtifactDraft(files: ["assets/a.css": "red", "assets/b.js": "ok", "index.html": "home"])
    let editor = ArtifactEditing(draft: initial)
    _ = try await editor.read(path: "assets/a.css")
    await #expect(throws: ArtifactWorkspaceError.readRequired) {
        try await editor.relocate(path: "assets", destination: "styles")
    }
    #expect(await editor.snapshot().files == initial.files)
    _ = try await editor.read(path: "assets/b.js")
    await #expect(throws: ArtifactWorkspaceError.invalidPath) {
        try await editor.relocate(path: "assets", destination: "../outside")
    }
    #expect(await editor.snapshot().files == initial.files)
    let moved = try await editor.relocate(path: "assets", destination: "styles")
    #expect(moved.files["styles/a.css"] == "red")
    #expect(moved.files["assets/a.css"] == nil)
    try await editor.restore(initial)
    #expect(await editor.snapshot().files == initial.files)
}

@Test func writerContentReceivesUpdatedGoalRelatedSourceAndFormatPolicy() async throws {
    let model = WriterScriptModel([
        [
            .toolCall(.init(id: "edit", name: "edit", argumentsJSON: "{}")),
            .finished(.toolCalls),
        ],
        [.text(".diagram {color:red}"), .finished(.stop)],
        [
            .toolCall(.init(id: "finish", name: "finish", argumentsJSON: "{}")),
            .finished(.toolCalls),
        ],
    ])
    let probe = WriterStreamProbe()
    let tools = WriterTools(
        definitions: try writerDefinitions(),
        execute: { call in
            call.id == "edit"
                ? .write(streamID: "s", instruction: "File: style.css\nUpdate style", context: "<div class=diagram>")
                : .finished("done")
        }, append: { _, text in await probe.append(text) }, complete: { _ in await probe.complete() },
        abort: { _ in await probe.abort() })
    let updates = WriterOneShotRevision()
    _ = try await WriterWorkflow(model: model).run(
        goal: "draw", scope: "task", tools: tools, revisions: { await updates.take() })
    let request = try #require(await model.requests.dropFirst().first)
    #expect(request.messages.contains { $0.content.contains("Use red") && $0.content.contains("class=diagram") })
    #expect(request.messages.contains { $0.role == .system && $0.content.contains("WebKit") })
}

private actor WriterFailureProbe {
    var renders = 0
    func render() throws -> WriterToolOutcome {
        renders += 1
        if renders == 1 { throw WriterToolFailure("Render failed; correct the draft") }
        return .observation("Rendered")
    }
}

@Test(arguments: [false, true]) func writerDoesNotRepeatFailedEffectsUntilDraftChanges(repair: Bool) async throws {
    func control(_ id: String, _ name: String) -> [ChatEvent] {
        [.toolCall(.init(id: id, name: name, argumentsJSON: "{}")), .finished(.toolCalls)]
    }
    var script = [control("first", "render")]
    if repair {
        script += [control("edit", "edit"), [.text("Fixed"), .finished(.stop)]]
    }
    script.append(control("second", "render"))
    if repair {
        script.append(control("finish", "finish"))
    } else {
        script.append(control("third", "render"))
    }
    let model = WriterScriptModel(script)
    let probe = WriterFailureProbe()
    let tools = WriterTools(
        definitions: try writerDefinitions(),
        execute: { call in
            if ["first", "second"].contains(call.id) { return try await probe.render() }
            if call.id == "edit" { return .write(streamID: "s", instruction: "Fix", context: "") }
            return .finished("Done")
        }, append: { _, _ in }, complete: { _ in "Draft changed" }, abort: { _ in })
    if repair {
        #expect(try await WriterWorkflow(model: model).run(goal: "Draw", scope: "t", tools: tools) == "Done")
        #expect(await probe.renders == 2)
    } else {
        await #expect(throws: WriterRecoveryFailure.self) {
            try await WriterWorkflow(model: model).run(goal: "Draw", scope: "t", tools: tools)
        }
        #expect(await probe.renders == 1)
        #expect(await model.requests.count == 3)
    }
}

@Test func invalidReadRangesDoNotMasqueradeAsStorageCapacity() async throws {
    let editor = ArtifactEditing(draft: try ArtifactDraft(files: ["index.html": "hello"]))
    await #expect(throws: ArtifactWorkspaceError.invalidReadRange) {
        try await editor.readLines(path: "index.html", line: 1, count: 0)
    }
    await #expect(throws: ArtifactWorkspaceError.invalidReadRange) {
        try await editor.read(path: "index.html", offset: 6)
    }
    #expect(ArtifactWorkspaceError.invalidReadRange.description.contains("line/offset"))
    #expect(!ArtifactWorkspaceError.invalidReadRange.description.contains("capacity"))
}

private struct WriterRetryModelError: Error, ChatFailureProviding {
    let chatFailure: ChatFailureDiagnostic
}
private actor WriterRetryModel: ChatCapability {
    enum Step: Sendable {
        case events([ChatEvent])
        case failure(ChatFailureDiagnostic)
    }
    nonisolated var availability: CapabilityAvailability { .available }
    nonisolated let supportsToolCalls = true
    var requests: [ChatRequest] = []
    var steps: [Step]
    init(_ steps: [Step]) { self.steps = steps }
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        requests.append(request)
        guard !steps.isEmpty else { throw WriterFailure.incomplete }
        switch steps.removeFirst() {
        case .failure(let error): throw WriterRetryModelError(chatFailure: error)
        case .events(let events):
            let pair = InferenceSession<ChatEvent>.make(limits: try .init(), estimatedBytes: { $0.estimatedBytes })
            for event in events { try pair.emitter.yield(event) }
            pair.emitter.finish()
            return pair.session
        }
    }
}
private func writerControl(_ id: String, _ command: String) -> [ChatEvent] {
    [
        .toolCall(.init(id: id, name: command, argumentsJSON: "{}")),
        .finished(.toolCalls),
    ]
}
private func writerFinishTools() throws -> WriterTools {
    WriterTools(
        definitions: try writerDefinitions(), execute: { _ in .finished("Done") },
        append: { _, _ in }, complete: { _ in "" }, abort: { _ in })
}

@Test(arguments: [408, 429, 503, 401, 403, 422]) func writerRetriesTransientHTTPButNotPermanentRejections(status: Int)
    async throws
{
    let transient = [408, 429, 503].contains(status)
    let model = WriterRetryModel([
        .failure(.init(.httpStatus, stage: .http, statusCode: status)), .events(writerControl("finish", "finish")),
    ])
    if transient {
        #expect(
            try await WriterWorkflow(model: model).run(goal: "Demo", scope: "run", tools: writerFinishTools()) == "Done"
        )
    } else {
        await #expect(throws: WriterRetryModelError.self) {
            try await WriterWorkflow(model: model).run(goal: "Demo", scope: "run", tools: writerFinishTools())
        }
    }
    #expect(await model.requests.count == (transient ? 2 : 1))
    #expect(await model.requests.allSatisfy { $0.maximumOutputTokens == nil })
}

@Test func writerStopsAfterThreeTransportAttemptsWithOriginalCause() async throws {
    let model = WriterRetryModel(
        Array(
            repeating: .failure(.init(.transport, stage: .stream, networkReason: .timeout, networkCode: -1001)),
            count: 3))
    do {
        _ = try await WriterWorkflow(model: model).run(goal: "Demo", scope: "run", tools: writerFinishTools())
        Issue.record("Expected exhausted recovery")
    } catch let failure as WriterRecoveryFailure {
        #expect(failure.attempts == 3 && failure.phase == "控制请求")
        #expect((failure.underlying as? WriterRetryModelError)?.chatFailure.networkCode == -1001)
    }
    #expect(await model.requests.count == 3)
}

@Test func writerCorrectsPlainTextControlAndInvalidTerminalBatchBeforeEffects() async throws {
    let model = WriterScriptModel([
        [.text("I will draw it"), .finished(.stop)],
        [
            .toolCall(.init(id: "finish-early", name: "finish", argumentsJSON: "{}")),
            .toolCall(.init(id: "edit-early", name: "edit", argumentsJSON: "{}")),
            .finished(.toolCalls),
        ],
        writerControl("finish", "finish"),
    ])
    #expect(
        try await WriterWorkflow(model: model).run(goal: "Demo", scope: "run", tools: writerFinishTools()) == "Done")
    let requests = await model.requests
    #expect(requests.count == 3)
    #expect(requests[1].messages.contains { $0.content.contains("the delegation is still active") })
    for id in ["finish-early", "edit-early"] {
        #expect(
            requests[2].messages.contains {
                $0.role == .tool && $0.toolCallID == id && $0.content.contains("Not executed")
            })
    }
}

private actor WriterRetryEditor {
    let editor: ArtifactEditing
    var streams: [String] = []
    var aborted = 0
    var commits = 0
    let commitFails: Bool
    init(commitFails: Bool = false) throws {
        self.commitFails = commitFails
        editor = ArtifactEditing(draft: try ArtifactDraft(files: [:]))
    }
    func begin() async throws -> WriterToolOutcome {
        let id = try await editor.begin(path: "index.html")
        streams.append(id.uuidString)
        return .write(streamID: id.uuidString, instruction: "File: index.html\nCreate demo", context: "New file")
    }
    func append(_ id: String, _ text: String) async throws {
        try await editor.append(text, to: #require(UUID(uuidString: id)))
    }
    func abort(_ id: String) async throws {
        #expect(!Task.isCancelled)
        aborted += 1
        try await editor.cancel(#require(UUID(uuidString: id)))
    }
    func complete(_ id: String) async throws -> String {
        commits += 1
        if commitFails { throw WriterToolFailure("Commit uncertain") }
        _ = try await editor.finish(#require(UUID(uuidString: id)))
        return "Saved"
    }
}

@Test func writerRegeneratesInterruptedContentInFreshTransactionWithoutDuplicatingPrefix() async throws {
    let model = WriterScriptModel([
        writerControl("edit", "edit"), [.text("partial"), .finished(.lengthLimit)],
        [.text("<h1>Complete 🌍</h1>"), .finished(.stop)], writerControl("finish", "finish"),
    ])
    let probe = try WriterRetryEditor()
    let tools = WriterTools(
        definitions: try writerDefinitions(),
        execute: { call in
            call.id == "edit" ? try await probe.begin() : .finished("Done")
        }, append: { try await probe.append($0, $1) }, complete: { try await probe.complete($0) },
        abort: { try await probe.abort($0) })
    #expect(try await WriterWorkflow(model: model).run(goal: "Demo", scope: "run", tools: tools) == "Done")
    let requests = await model.requests
    #expect(
        requests[2].messages.contains {
            $0.role == .user && $0.content.contains("writer.incomplete")
                && $0.content.contains("Failed source stream aborted")
        })
    let streams = await probe.streams
    #expect(streams.count == 2 && Set(streams).count == 2)
    #expect(await probe.aborted == 1)
    #expect(await probe.commits == 1)
    #expect(await probe.editor.snapshot().files["index.html"] == "<h1>Complete 🌍</h1>")
}

@Test func writerNeverReplaysAnUncertainCommit() async throws {
    let model = WriterScriptModel([writerControl("edit", "edit"), [.text("complete"), .finished(.stop)]])
    let probe = try WriterRetryEditor(commitFails: true)
    let tools = WriterTools(
        definitions: try writerDefinitions(), execute: { _ in try await probe.begin() },
        append: { try await probe.append($0, $1) }, complete: { try await probe.complete($0) },
        abort: { try await probe.abort($0) })
    await #expect(throws: WriterToolFailure.self) {
        try await WriterWorkflow(model: model).run(goal: "Demo", scope: "run", tools: tools)
    }
    #expect(await probe.streams.count == 1)
    #expect(await probe.commits == 1)
    #expect(await probe.aborted == 1)
    #expect(await model.requests.count == 2)
}

@Test func writerCancellationDuringBackoffDoesNotStartAnotherRequest() async throws {
    let model = WriterRetryModel([.failure(.init(.transport, stage: .http, networkReason: .connection))])
    let tools = try writerFinishTools()
    let task = Task { try await WriterWorkflow(model: model).run(goal: "Demo", scope: "run", tools: tools) }
    while await model.requests.isEmpty { await Task.yield() }
    try await Task.sleep(for: .milliseconds(30))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await model.requests.count == 1)
}

@Test func writerAbortFailurePreservesBothCausesAndStopsRecovery() async throws {
    let model = WriterScriptModel([writerControl("edit", "edit"), [.text("partial"), .finished(.lengthLimit)]])
    let tools = WriterTools(
        definitions: try writerDefinitions(),
        execute: { _ in .write(streamID: "s", instruction: "Create demo", context: "") },
        append: { _, _ in }, complete: { _ in "not committed" }, abort: { _ in throw WriterToolFailure("abort failed") }
    )
    do {
        _ = try await WriterWorkflow(model: model).run(goal: "Demo", scope: "run", tools: tools)
        Issue.record("Expected cleanup failure")
    } catch let failure as WriterCleanupFailure {
        #expect(failure.primary as? WriterFailure == .incomplete)
        #expect((failure.cleanup as? WriterToolFailure)?.description == "abort failed")
    }
    #expect(await model.requests.count == 2)
}

@Test(arguments: ["html", "css", "js", "svg", "json"])
func writerRejectsSplitOuterCodeFencesBeforeCommit(format: String) throws {
    var prefix = WriterContentPrefix(instruction: "File: demo.\(format)\nCreate source")
    #expect(try prefix.consume(" \n`") == " \n")
    #expect(try prefix.consume("`") == "")
    #expect(throws: WriterContentFormatFailure.self) { try prefix.consume("`\(format)\nsource") }
    let failure = WriterDiagnostics.make(WriterContentFormatFailure(), stage: "文件内容请求")
    #expect(failure.code == "writer.content.markdownWrapper")
    #expect(WriterRecovery.retryable(WriterContentFormatFailure()))
}

@Test func writerContentPrefixPreservesMarkdownAndLegitimateTemplateLiterals() throws {
    var markdown = WriterContentPrefix(instruction: "File: document.md")
    #expect(try markdown.consume("```js\nconsole.log('你好')\n```\n") == "```js\nconsole.log('你好')\n```\n")
    var javascript = WriterContentPrefix(instruction: "File: app.js")
    #expect(try javascript.consume("`hello 🌍`;") == "`hello 🌍`;")
    var emptyTemplate = WriterContentPrefix(instruction: "File: app.js")
    #expect(try emptyTemplate.consume("``") == "")
    #expect(emptyTemplate.finish() == "``")
}

@Test func writerWrappedContentRetriesWithCorrectionAndFreshStream() async throws {
    let model = WriterScriptModel([
        writerControl("edit", "edit"), [.text("`"), .text("``html\n<h1>Wrong wrapper</h1>\n```"), .finished(.stop)],
        [.text("<h1>你好 🌍</h1>"), .finished(.stop)], writerControl("finish", "finish"),
    ])
    let probe = try WriterRetryEditor()
    let tools = WriterTools(
        definitions: try writerDefinitions(),
        execute: { call in
            call.id == "edit" ? try await probe.begin() : .finished("Done")
        }, append: { try await probe.append($0, $1) }, complete: { try await probe.complete($0) },
        abort: { try await probe.abort($0) })
    #expect(try await WriterWorkflow(model: model).run(goal: "Demo", scope: "run", tools: tools) == "Done")
    #expect(await probe.aborted == 1)
    #expect(await probe.commits == 1)
    #expect(await probe.editor.snapshot().files["index.html"] == "<h1>你好 🌍</h1>")
    #expect(await model.requests[2].messages.first?.content.contains("Previous attempt failed") == true)
}

@Test func writerRepeatedOuterWrappersExhaustRecoveryWithoutPublishing() async throws {
    let wrapped: [ChatEvent] = [.text("```html\n<h1>Wrong</h1>\n```"), .finished(.stop)]
    let model = WriterScriptModel([writerControl("edit", "edit"), wrapped, wrapped, wrapped])
    let probe = try WriterRetryEditor()
    let tools = WriterTools(
        definitions: try writerDefinitions(), execute: { _ in try await probe.begin() },
        append: { try await probe.append($0, $1) }, complete: { try await probe.complete($0) },
        abort: { try await probe.abort($0) })
    do {
        _ = try await WriterWorkflow(model: model).run(goal: "Demo", scope: "run", tools: tools)
        Issue.record("Expected format recovery exhaustion")
    } catch let error as WriterRecoveryFailure {
        #expect(error.attempts == 3)
        #expect(error.underlying is WriterContentFormatFailure)
    }
    #expect(await probe.aborted == 3)
    #expect(await probe.commits == 0)
    #expect(await probe.editor.snapshot().files.isEmpty)
}

@Test func writerExactPatchesPreserveUnicodeAndAllSurroundingBytes() async throws {
    let source = "<!doctype html>\n  <title>计数器 🌍</title>\n<!-- KEEP_ME -->\n"
    let editor = ArtifactEditing(draft: try .init(files: ["index.html": source, "app.js": "const n = 0;\n"]))
    let read = try await editor.readLines(path: "index.html", line: 2, count: 1)
    let unchanged = try await editor.read(path: "app.js")
    let changed = try await editor.replace(
        path: "index.html", reference: read.reference, old: "计数器 🌍", new: "中文测试计数器 🌍")
    #expect(changed.files["index.html"] == source.replacingOccurrences(of: "计数器 🌍", with: "中文测试计数器 🌍"))
    #expect(changed.files["app.js"] == "const n = 0;\n")
    await #expect(throws: ArtifactWorkspaceError.readRequired) {
        try await editor.replace(path: "index.html", reference: read.reference, old: "中文测试计数器", new: "标题")
    }
    _ = try await editor.replace(path: "app.js", reference: unchanged.reference, old: "const n = 0;", new: "")
    #expect(await editor.snapshot().files["app.js"] == "\n")
}

@Test func writerExactPatchesRejectAmbiguityAndCrossRangeWithoutMutation() async throws {
    let original = try ArtifactDraft(files: ["index.html": "same same\nunique\n", "other.txt": "same"])
    let editor = ArtifactEditing(draft: original)
    let first = try await editor.readLines(path: "index.html", line: 1, count: 1)
    for old in ["same", "absent", "unique", ""] {
        await #expect(throws: ArtifactWorkspaceError.ambiguousMatch) {
            try await editor.replace(path: "index.html", reference: first.reference, old: old, new: "changed")
        }
        #expect(await editor.snapshot().files == original.files)
    }
    await #expect(throws: ArtifactWorkspaceError.readRequired) {
        try await editor.replace(path: "other.txt", reference: first.reference, old: "same", new: "changed")
    }
    let narrow = try await editor.read(path: "index.html", offset: 0, limit: 4)
    _ = try await editor.replace(path: "index.html", reference: narrow.reference, old: "same", new: "different")
    #expect(await editor.snapshot().files["index.html"] == "different same\nunique\n")
}

private actor WriterOneShotRevision {
    private var pending = true
    func take() -> [String] {
        defer { pending = false }
        return pending ? ["Use red"] : []
    }
}

private actor WriterNaturalFinishProbe {
    var commits = 0
    var progress: [WriterRequestProgress] = []
    func commit() -> String {
        commits += 1
        return "Published"
    }
    func report(_ fact: WriterRequestProgress) { progress.append(fact) }
}
@Test func writerRequiresAnExplicitFinishAfterPlainText() async throws {
    let model = WriterScriptModel([[.text("Ready"), .finished(.stop)], writerControl("finish", "finish")])
    let probe = WriterNaturalFinishProbe()
    let tools = WriterTools(
        definitions: try writerDefinitions(),
        execute: { call in
            #expect(call.id == "finish")
            return .finished(await probe.commit())
        }, append: { _, _ in }, complete: { _ in "unused" }, abort: { _ in })
    #expect(
        try await WriterWorkflow(model: model, requestProgress: { await probe.report($0) }).run(
            goal: "Done", scope: "run", tools: tools) == "Published")
    #expect(await model.requests.count == 2)
    #expect(await probe.commits == 1)
    #expect(await probe.progress.map(\.number) == [1, 2])
}

private actor WriterRoundBoundaryProbe {
    var events: [String] = []
    func add(_ value: String) { events.append(value) }
}
@Test func writerReportsCompletedStepsAfterCommitAndRefreshBeforeNextLoop() async throws {
    let model = WriterScriptModel([
        [
            .toolCall(.init(id: "edit", name: "edit", argumentsJSON: #"{"path":"index.html"}"#)),
            .finished(.toolCalls),
        ],
        [.text("<h1>Ready</h1>"), .finished(.stop)],
        [
            .toolCall(.init(id: "render", name: "render", argumentsJSON: "{}")),
            .finished(.toolCalls),
        ],
        [
            .toolCall(.init(id: "finish", name: "finish", argumentsJSON: "{}")),
            .finished(.toolCalls),
        ],
    ])
    let probe = WriterRoundBoundaryProbe()
    let tools = WriterTools(
        definitions: try writerDefinitions(),
        execute: { call in
            await probe.add(call.id)
            switch call.id {
            case "edit": return .write(streamID: "stream", instruction: "File: index.html", context: "")
            case "render": return .observation(#"{"status":"observed"}"#)
            default: return .finished("Done")
            }
        },
        append: { _, _ in await probe.add("append") },
        complete: { _ in
            await probe.add("commit")
            return "Saved"
        },
        abort: { _ in },
        refresh: { await probe.add("refresh") })
    _ = try await WriterWorkflow(
        model: model,
        requestProgress: { fact in await probe.add("start" + String(fact.number)) },
        roundCompleted: { fact, summary in
            await probe.add("report" + String(fact?.number ?? 0))
            #expect(summary.contains("已准备编辑") || summary.contains("已更新文件") || summary.contains("已完成页面渲染检查"))
        }
    ).run(goal: "A heading", scope: "run", tools: tools)
    #expect(
        await probe.events == [
            "start1", "edit", "refresh", "report1", "start2", "append", "commit", "refresh", "report2",
            "start3", "render", "refresh", "report3", "start4", "finish",
        ])
}

@Test func writerRequestRecoveryFeedsActualCauseAndRetainsItAfterSuccess() async throws {
    let model = WriterRetryModel([
        .failure(.init(.invalidToolArguments, stage: .toolArguments, field: "arguments")),
        .events(writerControl("read", "read")), .events(writerControl("finish", "finish")),
    ])
    let tools = WriterTools(
        definitions: try writerDefinitions(),
        execute: { $0.id == "finish" ? .finished("Done") : .observation("File is ready") },
        append: { _, _ in }, complete: { _ in "" }, abort: { _ in })
    #expect(try await WriterWorkflow(model: model).run(goal: "Demo", scope: "run", tools: tools) == "Done")
    let requests = await model.requests
    #expect(requests.count == 3)
    for index in [1, 2] {
        #expect(
            requests[index].messages.contains {
                $0.role == .user && $0.content.contains("tool.invalidArguments")
                    && $0.content.contains("No workspace tool") && $0.content.contains("arguments")
            })
    }
    #expect(requests[2].messages.contains { $0.role == .tool && $0.toolCallID == "read" })
}

@Test func writerAcceptsLargeNativePatchAndCarriesItIntoNextRequest() async throws {
    let arguments = String(
        decoding: try JSONEncoder().encode(
            ["newText": String(repeating: "source", count: 20000)]), as: UTF8.self)
    let call = ChatToolCall(id: "large", name: "replace", argumentsJSON: arguments)
    let model = WriterScriptModel([[.toolCall(call), .finished(.toolCalls)], writerControl("finish", "finish")])
    let tools = WriterTools(
        definitions: try writerDefinitions(),
        execute: { $0.id == "finish" ? .finished("Done") : .observation("Patch saved") },
        append: { _, _ in }, complete: { _ in "" }, abort: { _ in })
    #expect(try await WriterWorkflow(model: model).run(goal: "Patch", scope: "run", tools: tools) == "Done")
    let request = try #require(await model.requests.last)
    #expect(request.messages.flatMap(\.toolCalls).contains { $0.argumentsJSON == arguments })
}

@Test func writerLongObservationDoesNotFailAnExecutedToolAndKeepsAContextExcerpt() async throws {
    let result = String(repeating: "long file contents ", count: 10000)
    let model = WriterScriptModel([writerControl("read", "read"), writerControl("finish", "finish")])
    let tools = WriterTools(
        definitions: try writerDefinitions(),
        execute: { $0.id == "finish" ? .finished("Done") : .observation(result) },
        append: { _, _ in }, complete: { _ in "" }, abort: { _ in })
    #expect(try await WriterWorkflow(model: model).run(goal: "Inspect", scope: "run", tools: tools) == "Done")
    let request = try #require(await model.requests.last)
    let observation = try #require(request.messages.last { $0.role == .tool })
    #expect(observation.content.contains("Runtime context excerpt"))
    #expect(observation.content.contains("complete tool result is recorded"))
    #expect(observation.toolCallID == "read")
}

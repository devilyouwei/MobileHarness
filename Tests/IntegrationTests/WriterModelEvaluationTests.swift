import Actions
import AgentCore
import CallRuntime
import Foundation
import FunctionContracts
import Gateway
@_spi(ModelManagement) import ModelKit
import ModelKitOpenAI
import StorageChat
import StorageCore
import StorageFiles
import StorageSQLite
import StorageTasks
import Testing
import UI
import WebKit

@testable import Agents

private enum WriterEvaluationError: Error { case requestBudget, renderTimeout, deadline, missingTask, invalidThinking }

/// Evaluation-only observation and paid-experiment budget; production requests are unchanged.
private actor WriterEvaluationChat: ChatCapability {
    nonisolated let availability: CapabilityAvailability = .available
    nonisolated let supportsToolCalls = true
    nonisolated let supportsImages = false
    let provider: OpenAIChat
    let trace: URL
    var records: [[String: String]] = []
    var count = 0
    init(provider: OpenAIChat, trace: URL) {
        self.provider = provider
        self.trace = trace
    }
    func reset() { count = 0 }
    func save() throws {
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            .write(to: trace, options: .atomic)
    }
    func update(_ index: Int, _ values: [String: String]) throws {
        records[index].merge(values) { _, new in new }
        try save()
    }
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        guard count < 36 else { throw WriterEvaluationError.requestBudget }
        count += 1
        let index = records.count
        let started = Date()
        records.append([
            "phase": request.tools.isEmpty ? "content" : "control", "started": started.ISO8601Format(),
            "scope": request.context.scopeID, "state": "requesting",
            "maximumOutputTokens": request.maximumOutputTokens.map(String.init) ?? "provider default",
        ])
        try save()
        print("WRITER_REQUEST \(index) \(request.tools.isEmpty ? "content" : "control") start")
        let upstream: InferenceSession<ChatEvent>
        do { upstream = try await provider.chat(request) } catch {
            try update(index, ["state": "failed", "error": String(describing: error)])
            throw error
        }
        let pair = InferenceSession<ChatEvent>.make(
            limits: try .init(), estimatedBytes: { $0.estimatedBytes },
            onTermination: { reason in
                if case .finished = reason { return }
                upstream.cancel()
            })
        Task {
            var bytes = 0
            var first = true
            var checkpoint = Date()
            do {
                for try await event in upstream.events {
                    if first {
                        first = false
                        try self.update(index, ["firstEventSeconds": String(Date().timeIntervalSince(started))])
                    }
                    switch event {
                    case .text(let value): bytes += value.utf8.count
                    case .toolCall(let call):
                        try self.update(index, ["tool.\(call.id)": call.argumentsJSON])
                        print("WRITER_TOOL \(index) \(call.argumentsJSON)")
                    case .finished(let reason): try self.update(index, ["finish": String(describing: reason)])
                    case .usage(let usage): try self.update(index, ["usage": String(describing: usage)])
                    }
                    if Date().timeIntervalSince(checkpoint) >= 1 {
                        checkpoint = Date()
                        try self.update(index, ["bytes": String(bytes), "state": "streaming"])
                    }
                    try await pair.emitter.yieldSuspending(event)
                }
                try self.update(
                    index,
                    [
                        "state": "finished", "bytes": String(bytes),
                        "seconds": String(Date().timeIntervalSince(started)),
                    ])
                print("WRITER_REQUEST \(index) done bytes=\(bytes) seconds=\(Date().timeIntervalSince(started))")
                pair.emitter.finish()
            } catch {
                try? self.update(
                    index,
                    [
                        "state": "failed", "bytes": String(bytes),
                        "seconds": String(Date().timeIntervalSince(started)), "error": String(describing: error),
                    ])
                print("WRITER_REQUEST \(index) failed \(error)")
                pair.emitter.fail(error)
            }
        }
        return pair.session
    }
}

/// Real macOS WebKit execution, independent of iOS window composition. No screenshot claim.
@MainActor private final class WriterEvaluationRenderer: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let root: URL
    var completion: CheckedContinuation<Void, any Error>?
    var generation = UUID()
    var renders: [[String: String]] = []
    private var executesScripts = false
    init(root: URL) {
        self.root = root
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(
            WKUserScript(
                source:
                    "window.__writerErrors=[];window.addEventListener('error',e=>window.__writerErrors.push(e.message||'resource error'),true);window.addEventListener('unhandledrejection',e=>window.__writerErrors.push(String(e.reason)));",
                injectionTime: .atDocumentStart, forMainFrameOnly: false))
        web = WKWebView(frame: .init(x: 0, y: 0, width: 390, height: 844), configuration: config)
        super.init()
        web.navigationDelegate = self
    }
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        preferences.allowsContentJavaScript = executesScripts
        decisionHandler(.allow, preferences)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { settle(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { settle(error) }
    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) { settle(error) }
    func settle(_ error: (any Error)?) {
        let pending = completion
        completion = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
    func show(_ id: UUID, entry: String, files: [String: String], preview: Bool) async throws -> String {
        let directory = root.appendingPathComponent(id.uuidString).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, content) in files {
            let file = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: file, options: .atomic)
        }
        var page = directory.appendingPathComponent(entry)
        if page.pathExtension != "html" {
            let text = (files[entry] ?? "").replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            page = directory.appendingPathComponent("__evaluation.html")
            try Data("<!doctype html><meta charset='utf-8'><pre>\(text)</pre>".utf8).write(to: page)
        }
        executesScripts = !preview
        let token = UUID()
        generation = token
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            web.loadFileURL(page, allowingReadAccessTo: directory)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.generation == token, self.completion != nil else { return }
                self.web.stopLoading()
                self.settle(WriterEvaluationError.renderTimeout)
            }
        }
        let raw =
            try await web.evaluateJavaScript(
                "(()=>{const b=document.getElementById('increment'),c=document.getElementById('count');let before=c?.textContent;if(b&&c)b.click();return JSON.stringify({errors:window.__writerErrors||[],text:document.body?.innerText||'',title:document.title,svg:document.querySelectorAll('svg').length,button:document.querySelectorAll('button').length,nodes:document.querySelectorAll('[class*=node],[class*=step],svg rect,svg polygon').length,counterBefore:before,counterAfter:c?.textContent})})()"
            ) as? String ?? "{}"
        let info = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] ?? [:]
        let errors = info["errors"] as? [String] ?? []
        let result = [
            "text": info["text"] as? String ?? "",
            "status": preview ? "preview" : errors.isEmpty ? "ok" : "errors", "engine": "macOS WebKit (no screenshot)",
            "diagnostics": raw,
        ]
        renders.append([
            "entry": entry, "preview": String(preview), "diagnostics": raw, "at": String(Date().timeIntervalSince1970),
        ])
        return String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    }
    func stop() {
        web.stopLoading()
        settle(CancellationError())
    }
}

private actor WriterEvaluationSink: Agent {
    nonisolated let descriptor = AgentDescriptor(
        id: .assistant, name: "Evaluation requester", inputs: [.observation, .communicationReceipt],
        outputs: [.communication])
    nonisolated let outputs = AsyncStream<OutputEnvelope> { $0.finish() }
    var signals: [AgentTaskSignal] = []
    func start() {}
    func pause() {}
    func resume() {}
    func stop() {}
    func receive(_ input: AgentInput) {
        guard case .observation(let message) = input.payload,
            let signal = message.content(as: WriterTaskCompletion.self)?.signal
                ?? message.content(as: AgentTaskSignal.self)
        else { return }
        signals.append(signal)
    }
    func status() -> AgentStatus { .init(lifecycle: .running, queuedInputs: 0, processedInputs: signals.count) }
}

private struct WriterEvaluationCase {
    let id: String
    let goal: String
    let entry: String
    var resumes: String? = nil
}
private let writerEvaluationCases = [
    WriterEvaluationCase(
        id: "diagram", goal: "绘制一份简单的测试流程图",
        entry: "index.html"),
    WriterEvaluationCase(
        id: "multifile",
        goal:
            "制作一个极简计数器demo，恰好三个文件index.html、style.css、app.js。标题是计数器，按钮id=increment，数字id=count，初始0，点击加1。HTML用相对路径引用CSS和JS。HTML里保留注释KEEP_ME。不要额外功能。",
        entry: "index.html"),
    WriterEvaluationCase(
        id: "partial-resume",
        goal: "继续已有计数器，只将页面标题和主标题改为“中文测试计数器”；先读取并使用reference局部修改。保留KEEP_ME注释，app.js与style.css必须逐字节不变，其余内容不变。",
        entry: "index.html", resumes: "multifile"),
    WriterEvaluationCase(
        id: "file-operations",
        goal:
            "在现有计数器项目先list并search定位app.js引用，用move将app.js移到assets/main.js，然后读取index.html并仅修改脚本路径。新增notes.txt内容临时备注，读取它，再用remove删除notes.txt。保留计数器功能和KEEP_ME。最后render检查再finish。",
        entry: "index.html", resumes: "multifile"),
    WriterEvaluationCase(
        id: "markdown", goal: "写一个简短Markdown测试报告document.md，标题Writer测试报告，包含三个步骤的有序列表、一个两列表格和一段JS代码示例，总共不超过20行。不需要HTML。",
        entry: "document.md"),
    WriterEvaluationCase(
        id: "javascript-repair",
        goal:
            "创建最小两个文件index.html和app.js。为了测试修复循环，先让app.js执行throw new Error(\"WRITER_TEST\")，调用render观察错误；随后读取app.js，用reference修复为给按钮id=increment添加点击计数逻辑，count初始0。重新render确认无错误，最后finish。无其他功能。",
        entry: "index.html"),
]

@Test(.actionCatalog, .enabled(if: ProcessInfo.processInfo.environment["MH_WRITER_EVAL"] == "1"))
func writerRealModelWorkflowRegression() async throws {
    let env = ProcessInfo.processInfo.environment
    let modelID = try #require(env["MH_WRITER_EVAL_MODEL"])
    let thinking = env["MH_WRITER_EVAL_THINKING"] ?? "enabled"
    guard ["enabled", "minimum"].contains(thinking) else { throw WriterEvaluationError.invalidThinking }
    let root = URL(fileURLWithPath: try #require(env["MH_WRITER_EVAL_ROOT"]))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let context = try ModelContext(loadGate: ModelLoadGate(maximumConcurrentLoads: 1), maximumLoadWaiters: 4)
    let provider = try OpenAIChat(
        context: context,
        configuration: OpenAIChatConfiguration(
            baseURL: OpenAIChatConfiguration.endpoint(try #require(env["MH_WRITER_EVAL_API_URL"])),
            apiKey: try #require(env["MH_WRITER_EVAL_API_KEY"]), model: modelID,
            thinking: thinking == "minimum" ? .minimum : .enabled))
    let model = WriterEvaluationChat(provider: provider, trace: root.appendingPathComponent("requests.json"))
    let records = try SQLiteRepositories(url: root.appendingPathComponent("records.sqlite"))
    let disk = try DiskFileStore(root: root.appendingPathComponent("workspaces"))
    let workspace = ArtifactWorkspace(
        disk: disk,
        index: try FileDocumentStore<ArtifactWorkspaceIndex>(
            url: root.appendingPathComponent("workspace-index.json"), maximumBytes: Int.max - 1))
    let renderer = await WriterEvaluationRenderer(root: root.appendingPathComponent("render"))
    let artifacts = ArtifactService(
        workspace: workspace,
        present: { id, _, entry, files, preview in
            try await renderer.show(id, entry: entry, files: files, preview: preview)
        })
    let journal = ConversationHistoryStore(
        records: try ConversationRecordStore(repository: records.chat, tasks: records.tasks, agent: "writer"))
    let writer = try WriterAgent(
        model: { ChatModel(capability: model, modelName: modelID) }, streaming: artifacts, history: journal,
        tasks: records.tasks)
    let sink = WriterEvaluationSink()
    let island = await IslandState()
    await island.setAvailable(true)
    let islandService = await IslandPresentationService(state: island)
    let session = UUID().uuidString
    let manager = AgentManager()
    try await manager.register(sink, sessionID: session)
    try await manager.register(writer)
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, configurations: AgentConfigurations.all())
    let input = InputGateway(manager: manager, policy: policy)
    let assembly = try BehaviorAssembly(capabilityModules: [
        ArtifactsModule(artifacts: artifacts), IslandModule(island: islandService),
    ])
    let output = await OutputGateway(
        manager: manager, requests: input, tools: assembly.tools, policy: policy, sink: { _ in })
    await writer.bind(try await output.consumer(for: writer))
    try await manager.start(.writer)
    let messaging = try await output.messaging(for: .assistant)
    var results: [[String: Any]] = []
    var tasks: [String: DelegatedTaskRecord] = [:]
    let selected = env["MH_WRITER_EVAL_CASES"].map { Set($0.split(separator: ",").map(String.init)) }
    let seconds = Double(env["MH_WRITER_EVAL_SECONDS"] ?? "600") ?? 600
    for scenario in writerEvaluationCases where selected == nil || selected!.contains(scenario.id) {
        await model.reset()
        let start = Date()
        var issues: [String] = []
        var item: [String: Any] = ["id": scenario.id, "goal": scenario.goal]
        print("WRITER_CASE \(modelID) \(scenario.id) START")
        do {
            let previous = scenario.resumes.flatMap { tasks[$0] }
            if scenario.resumes != nil, previous?.status != "completed" { throw WriterEvaluationError.missingTask }
            var before: ArtifactProject?
            if let raw = previous?.projectID, let id = UUID(uuidString: raw) {
                before = try await workspace.project(id)
            }
            let task = try await records.tasks.beginDelegation(
                taskID: previous?.id, goal: scenario.goal, input: scenario.goal, sourceDialog: nil, agent: "writer")
            item["taskID"] = task.id
            item["runID"] = task.runID
            let scope = AgentTaskScope(
                id: task.runID, requester: .assistant, executor: .writer, sessionID: session, execution: .background)
            var data = ["request": scenario.goal, "goal": scenario.goal, "entry": scenario.entry, "taskID": task.id]
            if let project = task.projectID { data["projectID"] = project }
            let signal = try AgentTaskSignal(
                kind: .request, scope: scope, businessContract: "writer.author", data: JSONEncoder().encode(data))
            let receipt = try await messaging.send(
                signal.message(),
                parent: .init(id: UUID().uuidString, sessionID: session, payload: .text(scenario.goal)), to: .writer)
            guard receipt.rejected.isEmpty else { throw WriterFailure.unavailable }
            while true {
                let current = try await records.tasks.delegatedTask(task.id, agent: "writer")
                if !["running", "pending", "finishing"].contains(current.status) {
                    item["status"] = current.status
                    item["failure"] = current.failure
                    tasks[scenario.resumes ?? scenario.id] = current
                    if current.status != "completed" { issues.append("Writer terminal: \(current.status)") }
                    break
                }
                if Date().timeIntervalSince(start) > seconds {
                    issues.append("Evaluation deadline exceeded; explicit cancel, not production timeout")
                    let cancel = try AgentTaskContent(text: "Evaluation deadline").signal(.cancel, scope: scope)
                    _ = try await messaging.send(
                        cancel.message(),
                        parent: .init(id: UUID().uuidString, sessionID: session, payload: .text("cancel")), to: .writer)
                    let until = Date().addingTimeInterval(20)
                    while Date() < until, await writer.observationSnapshot().business["phase"] != .text("idle") {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    item["status"] = "evaluationTimeout"
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            if let current = tasks[scenario.resumes ?? scenario.id], let raw = current.projectID,
                let id = UUID(uuidString: raw)
            {
                if let project = try? await workspace.project(id) {
                    item["projectID"] = raw
                    item["files"] = project.files.mapValues { $0.utf8.count }
                    let html = project.files[scenario.entry] ?? ""
                    if html.isEmpty { issues.append("Missing entry") }
                    if scenario.id == "multifile" || scenario.resumes != nil {
                        if !html.contains("KEEP_ME") { issues.append("Missing preserved marker") }
                    }
                    if scenario.id == "multifile",
                        Set(project.files.keys) != Set(["index.html", "style.css", "app.js"])
                    {
                        issues.append("Incorrect multi-file inventory")
                    }
                    if scenario.id == "partial-resume", let before {
                        for path in ["app.js", "style.css"] where before.files[path] != project.files[path] {
                            issues.append("Unrelated file changed: \(path)")
                        }
                        if !html.contains("中文测试计数器") { issues.append("Title not modified") }
                        if previous?.id != current.id || previous?.projectID != current.projectID
                            || previous?.runID == current.runID
                        {
                            issues.append("Resume identity mismatch")
                        }
                    }
                    if scenario.id == "file-operations",
                        project.files["assets/main.js"] == nil || project.files["app.js"] != nil
                            || project.files["notes.txt"] != nil
                    {
                        issues.append("Move/remove result mismatch")
                    }
                } else {
                    issues.append("No published artifact")
                }
            }
            let rendered = await renderer.renders
            let caseRenders = rendered.filter { Double($0["at"] ?? "0") ?? 0 >= start.timeIntervalSince1970 }
            if let first = caseRenders.first(where: { row in
                guard let raw = row["diagnostics"],
                    let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
                else { return false }
                let text = json["text"] as? String ?? ""
                return !text.isEmpty && !text.contains("正在准备创作")
            }), let at = Double(first["at"] ?? "") {
                item["firstVisibleSeconds"] = at - start.timeIntervalSince1970
            }
            item["previewFrames"] = caseRenders.filter { $0["preview"] == "true" }.count
            item["renderCount"] = rendered.count
            if let last = rendered.last?["diagnostics"],
                let dom = try JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any]
            {
                item["lastDOM"] = dom
                if (dom["errors"] as? [String] ?? []).isEmpty == false { issues.append("WebKit runtime errors") }
                if scenario.id == "diagram" {
                    if (dom["svg"] as? Int ?? 0) == 0 && (dom["nodes"] as? Int ?? 0) < 3 {
                        issues.append("Diagram structure missing")
                    }
                    for label in ["开始", "结束"] where !(dom["text"] as? String ?? "").contains(label) {
                        issues.append("Diagram label missing: " + label)
                    }
                }
                if ["multifile", "partial-resume", "file-operations", "javascript-repair"].contains(scenario.id) {
                    if dom["counterBefore"] as? String != "0" || dom["counterAfter"] as? String != "1" {
                        issues.append("Counter click behavior failed")
                    }
                }
            }
            try JSONSerialization.data(withJSONObject: rendered, options: [.prettyPrinted, .sortedKeys]).write(
                to: root.appendingPathComponent("renders.json"), options: .atomic)
            let archive = try await journal.readCurrent()
            try JSONEncoder().encode(archive.current).write(
                to: root.appendingPathComponent("\(scenario.id)-history.json"), options: .atomic)
            let calls = archive.current.turns.flatMap { $0.modelRequests ?? [] }.flatMap(\.toolCalls)
            if calls.contains(where: { $0.state == .received }) { issues.append("Unpaired tool call") }
        } catch { issues.append(String(describing: error)) }
        let requestRecords = await model.records.filter { $0["scope"] == item["runID"] as? String }
        item["requests"] = requestRecords.count
        item["contentRequests"] = requestRecords.filter { $0["phase"] == "content" }.count
        item["seconds"] = Date().timeIntervalSince(start)
        item["issues"] = issues
        item["passed"] = issues.isEmpty
        results.append(item)
        let report: [String: Any] = [
            "version": 1, "model": modelID, "thinking": thinking,
            "scope":
                "Production Writer/Gateway/Artifacts/SQLite, real provider, macOS WebKit; no iOS UI or screenshots",
            "cases": results,
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: root.appendingPathComponent("report.json"), options: .atomic)
        print("WRITER_CASE \(modelID) \(scenario.id) \(issues.isEmpty ? "PASS" : "FAIL") \(issues)")
        #expect(issues.isEmpty, "\(modelID)/\(scenario.id): \(issues)")
    }
    await writer.stop()
    await output.shutdown()
    await renderer.stop()
    await island.stop()
    try await records.shutdown()
    try await context.unload()
    let reopened = try SQLiteRepositories(url: root.appendingPathComponent("records.sqlite"))
    let restored = try ConversationRecordStore(repository: reopened.chat, tasks: reopened.tasks, agent: "writer")
    let projects = tasks.values.compactMap(\.projectID)
    #expect(Set(projects).count == projects.count)
    for task in tasks.values {
        #expect(try await reopened.tasks.delegatedTask(task.id, agent: "writer").projectID == task.projectID)
        let history = try await restored.read(task.dialogID)
        let calls = history.turns.flatMap { $0.modelRequests ?? [] }.flatMap(\.toolCalls)
        #expect(!history.turns.isEmpty)
        #expect(calls.allSatisfy { $0.state != .received })
    }
    try await reopened.shutdown()
    try JSONSerialization.data(withJSONObject: await renderer.renders, options: [.prettyPrinted, .sortedKeys]).write(
        to: root.appendingPathComponent("renders.json"))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MH_WRITER_RENDER_EVAL"] == "1"))
func writerEvaluationWebKitReloadsLocalResourcesAndChecksClick() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let renderer = await WriterEvaluationRenderer(root: root)
    let id = UUID()
    let html =
        "<!doctype html><meta charset='utf-8'><button id='increment'>+</button><span id='count'>0</span><script src='app.js'></script>"
    _ = try await renderer.show(
        id, entry: "index.html", files: ["index.html": html, "app.js": "throw new Error('WRITER_TEST')"], preview: false
    )
    _ = try await renderer.show(
        id, entry: "index.html",
        files: [
            "index.html": html,
            "app.js":
                "document.getElementById('increment').onclick=()=>document.getElementById('count').textContent='1';",
        ], preview: false)
    let values = await renderer.renders
    let beforeJSON = try #require(values.first?["diagnostics"])
    let afterJSON = try #require(values.last?["diagnostics"])
    let before = try #require(JSONSerialization.jsonObject(with: Data(beforeJSON.utf8)) as? [String: Any])
    let after = try #require(JSONSerialization.jsonObject(with: Data(afterJSON.utf8)) as? [String: Any])
    #expect(!(before["errors"] as? [String] ?? []).isEmpty)
    #expect((after["errors"] as? [String] ?? []).isEmpty)
    #expect(after["counterBefore"] as? String == "0")
    #expect(after["counterAfter"] as? String == "1")
    await renderer.stop()
}

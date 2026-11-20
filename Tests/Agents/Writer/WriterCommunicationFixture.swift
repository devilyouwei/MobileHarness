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

@testable import Actions
@testable import Agents

enum WriterEvaluationError: Error { case requestBudget, renderTimeout, deadline, missingTask, invalidThinking }

/// Evaluation-only observation and paid-experiment budget; production requests are unchanged.
actor WriterEvaluationChat: ChatCapability {
    nonisolated let availability: CapabilityAvailability = .available
    nonisolated let supportsToolCalls = true
    nonisolated let supportsImages: Bool
    let provider: OpenAIChat
    let trace: URL
    var records: [[String: String]] = []
    var count = 0
    let requestLimit: Int
    init(provider: OpenAIChat, trace: URL, supportsImages: Bool = false, requestLimit: Int? = nil) throws {
        guard
            let limit = requestLimit
                ?? Int(ProcessInfo.processInfo.environment["MH_WRITER_EVAL_REQUEST_LIMIT"] ?? "36"), limit > 0
        else {
            throw WriterEvaluationError.requestBudget
        }
        self.requestLimit = limit
        self.supportsImages = supportsImages
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
        guard count < requestLimit else {
            throw WriterEvaluationError.requestBudget
        }
        count += 1
        let index = records.count
        let started = Date()
        records.append([
            "phase": request.tools.isEmpty ? "content" : "control", "started": started.ISO8601Format(),
            "scope": request.context.scopeID, "state": "requesting",
            "messagesJSON": String(
                decoding: try JSONSerialization.data(
                    withJSONObject: request.messages.map { ["role": $0.role.rawValue, "content": $0.content] }),
                as: UTF8.self),
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
                    case .text(let value):
                        bytes += value.utf8.count
                        self.records[index]["response", default: ""] += value
                    case .toolCall(let call):
                        var evidence = ["tool.\(call.id)": call.argumentsJSON, "toolName.\(call.id)": call.name]
                        if self.records[index]["firstTool"] == nil {
                            evidence["firstTool"] = call.name
                            evidence["firstToolArguments"] = call.argumentsJSON
                        }
                        try self.update(index, evidence)
                        print("WRITER_TOOL \(index) \(call.name) \(call.argumentsJSON)")
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
@MainActor final class WriterEvaluationRenderer: NSObject, WKNavigationDelegate {
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
    func show(_ id: WorkspaceID, entry: String, files: [String: String], preview: Bool) async throws -> String {
        let directory = root.appendingPathComponent(id.storagePath).appendingPathComponent(UUID().uuidString)
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

actor WriterEvaluationSink: Agent {
    nonisolated let descriptor = AgentDescriptor(
        category: .cognition,
        id: .assistant, name: "Evaluation requester", inputs: [.observation],
        outputs: [.communication])
    nonisolated let outputs = AsyncStream<OutputEnvelope> { $0.finish() }
    var signals: [AgentTaskSignal] = []
    func start() {}
    func pause() {}
    func resume() {}
    func stop() {}
    func receive(_ input: AgentInput) {
        guard case .observation(let message) = input.payload,
            let signal = message.content(as: AgentTaskResponse.self)?.signal
                ?? message.content(as: AgentTaskSignal.self)
        else { return }
        signals.append(signal)
    }
    func status() -> AgentStatus { .init(lifecycle: .running, queuedInputs: 0, processedInputs: signals.count) }
}

struct WriterPromptSeed: Decodable {
    let name: String
    let title: String
    let entry: String
    let files: [String: String]
}
struct WriterPromptCase: Decodable {
    let id: String
    let goal: String
    let entry: String
    var seeds: [WriterPromptSeed]? = nil
    var resumeSeed: String? = nil
    var targetSeed: String? = nil
    var deleteSeed: String? = nil
    var contains: [String: [String]]? = nil
    var notContains: [String: [String]]? = nil
    var requiredFiles: [String]? = nil
    var forbiddenFiles: [String]? = nil
    var unchangedFiles: [String]? = nil
    var exactReplacement: [String: String]? = nil
    var firstCommand: String? = nil
    var requiredCommands: [String]? = nil
    var forbiddenCommands: [String]? = nil
    var domContains: [String]? = nil
    var library: Bool? = nil
    var diagram: Bool? = nil
    var counter: Bool? = nil
    var noNewWorkspace: Bool? = nil
    var windowRule: String? = nil
    var hostEvent: String? = nil
    var answer: String? = nil
    var expectWaiting: Bool? = nil
    var expectCancelled: Bool? = nil
}

/// Actual presentation/window owners; only animation completion is synthesized by this desktop host.
@MainActor final class WriterPromptHost {
    let pages = WebPageContainer()
    let windows = WindowState()
    let presentation: ArtifactPresentation
    let root: URL
    var events: [[String: String]] = []
    var renders: [[String: String]] = []
    var animation: Task<Void, Never>?
    var lastState = ""
    var hostEvent: String?
    var fired = false
    init(root: URL, event: String?) throws {
        self.root = root
        hostEvent = event
        pages.setAvailable(true)
        windows.layout(width: 390, height: 844)
        windows.setAvailable(true)
        presentation = ArtifactPresentation(pages: pages, windows: windows, disk: try DiskFileStore(root: root))
        animation = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let state = self.windows.windows.map { "\($0.id):\($0.phase):\($0.mode)" }.joined(separator: ",")
                if state != self.lastState {
                    self.events.append(["kind": "windows", "value": state, "at": String(Date().timeIntervalSince1970)])
                    self.lastState = state
                }
                for item in self.windows.windows where item.phase != .settled {
                    self.windows.complete(
                        item.id, revision: item.revision, generation: self.windows.generation, success: true)
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }
    func present(_ id: WorkspaceID, title: String, entry: String, files: [String: String], preview: Bool) async throws
        -> String
    {
        events.append([
            "kind": "present", "workspace": id.rawValue, "preview": String(preview),
            "at": String(Date().timeIntervalSince1970),
        ])
        let raw = try await presentation.present(id: id, title: title, entry: entry, files: files, preview: preview)
        var row = (try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8))) ?? [:]
        row["preview"] = String(preview)
        row["workspace"] = id.rawValue
        row["at"] = String(Date().timeIntervalSince1970)
        if let ref = row["windowID"], let window = try? windows.resolve(reference: ref),
            let page = pages.sessions[window]
        {
            page.webView.frame = .init(x: 0, y: 0, width: 390, height: 844)
            if let dom = try? await page.webView.evaluateJavaScript(
                "(()=>{let b=document.getElementById('increment'),c=document.getElementById('count');let before=c?.textContent;if(b&&c)b.click();return JSON.stringify({text:document.body?.innerText||'',svg:document.querySelectorAll('svg').length,counterBefore:before,counterAfter:c?.textContent,overflow:document.documentElement.scrollWidth>innerWidth+2})})()"
            ) as? String {
                row["dom"] = dom
            }
            if !preview, let png = try? await presentation.snapshot(id: id) {
                let path = root.appendingPathComponent("render-\(renders.count).png")
                try png.write(to: path)
                row["screenshot"] = path.path
            }
        }
        renders.append(row)
        if preview, !fired, !(files[entry] ?? "").contains("Preparing the draft"),
            ["closeOnPreview", "minimizeOnPreview"].contains(hostEvent ?? ""), let window = windows.windows.first?.id
        {
            fired = true
            if hostEvent == "closeOnPreview" {
                try await close(window)
            } else {
                try await windows.change(window, command: .minimize)
            }
            events.append(["kind": hostEvent!, "at": String(Date().timeIntervalSince1970)])
        }
        return raw
    }
    func close(_ window: UUID) async throws {
        let reference = try #require(windows.reference(for: window))
        let invocation = FunctionInvocation(
            call: .init(
                actionPath: .init(domain: "UI", module: "Window", function: "close"),
                parameters: ["windowID": reference]),
            context: .init(source: "writer", sessionID: "evaluation", inputID: "close"),
            executionID: UUID().uuidString, results: ActionReportStore())
        try await presentation.closeWindow(invocation: invocation)
        try await windows.change(window, command: .close)
    }
    func stop() async {
        animation?.cancel()
        await animation?.value
        animation = nil
        pages.closeSessions()
        windows.setAvailable(false)
    }
}

func writerPromptCase(_ scenario: WriterPromptCase, env: [String: String], root: URL, requestLimit: Int? = nil)
    async throws -> [String:
    Any]
{
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let started = Date()
    let modelID = try #require(env["MH_WRITER_EVAL_MODEL"])
    let context = try ModelContext(loadGate: ModelLoadGate(maximumConcurrentLoads: 1), maximumLoadWaiters: 4)
    let provider = try OpenAIChat(
        context: context,
        configuration: OpenAIChatConfiguration(
            baseURL: OpenAIChatConfiguration.endpoint(try #require(env["MH_WRITER_EVAL_API_URL"])),
            apiKey: try #require(env["MH_WRITER_EVAL_API_KEY"]), model: modelID,
            thinking: env["MH_WRITER_EVAL_THINKING"] == "enabled" ? .enabled : .minimum))
    let model = try WriterEvaluationChat(
        provider: provider, trace: root.appendingPathComponent("requests.json"), supportsImages: true,
        requestLimit: requestLimit)
    let records = try SQLiteRepositories(url: root.appendingPathComponent("records.sqlite"))
    let workspace = ArtifactWorkspace(
        disk: try DiskFileStore(root: root.appendingPathComponent("workspaces")), catalog: records.workspaces)
    let host = try await WriterPromptHost(root: root.appendingPathComponent("presentation"), event: scenario.hostEvent)
    let artifacts = ArtifactService(
        workspace: workspace,
        prepare: { id, deleting in try await host.presentation.prepare(id: id, deleting: deleting) },
        capture: { id in try await host.presentation.snapshot(id: id) },
        describe: { id, title, subtitle in await host.presentation.describe(id: id, title: title, subtitle: subtitle) },
        present: { id, title, entry, files, preview in
            try await host.present(id, title: title, entry: entry, files: files, preview: preview)
        })
    let journal = WriterHistoryStore(
        records: try WriterRecordStore(repository: records.writerMessages, logs: records.logs))
    let writer = try WriterAgent(
        model: { ChatModel(capability: model, modelName: modelID) }, streaming: artifacts, history: journal,
        executions: records.writerExecutions, communications: records.agentMessages)
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
    try await output.bindCommunications(records.agentMessages)
    await writer.bind(try await output.consumer(for: writer), messaging: try await output.messaging(for: .writer))
    try await manager.start(.writer)
    _ = try await output.consumer(for: sink)
    let messaging = WriterTestRequester(
        port: try await output.messaging(for: .assistant), receiver: sink, records: records)
    var issues: [String] = []
    var item: [String: Any] = ["id": scenario.id, "goal": scenario.goal]
    var seeds: [String: WriterWorkspaceRecord] = [:]
    var before: [String: ArtifactProject] = [:]
    do {
        for seed in scenario.seeds ?? [] {
            let task = try await records.seedDelegation(
                workspaceID: nil, goal: seed.title, input: "Synthetic fixture", sourceDialog: nil, agent: "writer")
            let id = try #require(WorkspaceID(rawValue: task.workspaceID))
            before[seed.name] = try await workspace.publish(
                id: id, expecting: nil, title: seed.title, draft: ArtifactDraft(files: seed.files), entry: seed.entry)
            try await records.writerExecutions.prepareWorkspace(
                workspaceID: task.id, delegateID: task.delegateID, agent: "writer")
            try await records.endSeedDelegation(task.delegateID, status: "completed")
            seeds[seed.name] = task.workspace
        }
        if scenario.hostEvent == "precloseSeed", let seed = before.values.first {
            _ = try await host.present(seed.id, title: seed.title, entry: seed.entry, files: seed.files, preview: false)
            if let window = await host.windows.windows.first?.id { try await host.close(window) }
        }
        if scenario.hostEvent == "hidden" {
            await host.presentation.setSceneActive(false)
            await writer.setSceneActive(false)
        }
        let eventStart = Date().timeIntervalSince1970
        let previous = scenario.resumeSeed.flatMap { seeds[$0] }
        let delegateID = UUID().uuidString
        let requestGoal = scenario.goal + (previous.map { " 已知作品引用：" + $0.workspaceID } ?? "")
        let scope = AgentTaskScope(
            id: delegateID, requester: .assistant, executor: .writer, sessionID: session, execution: .background)
        item["delegateID"] = delegateID
        let receipt = try await sendWriterMessage(
            AgentTaskRequest(id: delegateID, text: requestGoal), through: messaging, records: records, session: session)
        guard receipt.rejected.isEmpty else {
            item["admissionRejected"] = String(describing: receipt.rejected)
            throw WriterFailure.unavailable
        }
        var terminal = ""
        var answered = false
        var cancelled = false
        var waitingSeen = false
        var busyChecked = false
        while true {
            let phase = await writer.observationSnapshot().business["phase"]
            if !busyChecked, scenario.expectCancelled == true, phase == .text("running") {
                let competing = AgentTaskRequest(text: "Create a separate, independent new document")
                _ = try await sendWriterMessage(competing, through: messaging, records: records, session: session)
                item["busyMessageID"] = competing.id
                busyChecked = true
            }
            if phase == .text("waitingUser") {
                waitingSeen = true
                if let answer = scenario.answer, !answered {
                    let signals = await sink.signals
                    let content = signals.reversed().compactMap { try? AgentTaskContent.decode($0) }.first {
                        $0.interactionID != nil
                    }
                    if let content {
                        let reply = AgentTaskRequest(
                            text: answer, replyTo: scope.id, interactionID: content.interactionID)
                        _ = try await sendWriterMessage(reply, through: messaging, records: records, session: session)
                        answered = true
                    }
                } else if scenario.answer == nil {
                    terminal = "waitingUser"
                    break
                }
            }
            if scenario.expectCancelled == true, !cancelled,
                await model.records.contains(where: { $0["phase"] == "content" })
            {
                let cancel = AgentTaskRequest(text: "Cancel this assignment")
                _ = try await sendWriterMessage(cancel, through: messaging, records: records, session: session)
                cancelled = true
            }
            guard let current = try? await records.writerExecutions.request(delegateID, agent: "writer") else {
                guard Date().timeIntervalSince(started) <= Double(env["MH_WRITER_EVAL_SECONDS"] ?? "300")! else {
                    throw WriterFailure.incomplete
                }
                try await Task.sleep(for: .milliseconds(20))
                continue
            }
            item["workspaceID"] = current.workspaceID
            if ["completed", "failed", "cancelled", "interrupted"].contains(current.status) {
                terminal = current.status
                item["failure"] = current.failure
                break
            }
            if Date().timeIntervalSince(started) > Double(env["MH_WRITER_EVAL_SECONDS"] ?? "300")! {
                terminal = "evaluationTimeout"
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        if let busyID = item["busyMessageID"] as? String {
            let consumed = try await records.agentMessages.isAgentMessageConsumed(busyID)
            let started = (try? await records.writerExecutions.request(busyID, agent: "writer")) != nil
            let rejected = consumed && !started
            item["busyRejected"] = rejected
            if !rejected { issues.append("Busy assignment was accepted") }
        }
        item["status"] = terminal
        item["waitingSeen"] = waitingSeen
        if scenario.expectWaiting == true {
            if terminal != "waitingUser" { issues.append("Expected clarification before effects") }
        } else if scenario.expectCancelled == true {
            if terminal != "cancelled" { issues.append("Expected cancelled, got \(terminal)") }
        } else if terminal != "completed" {
            issues.append("Writer terminal: \(terminal)")
        }
        if scenario.answer != nil && !answered { issues.append("Required question/follow-up did not occur") }
        if terminal == "waitingUser" || terminal == "evaluationTimeout" {
            let interaction = await sink.signals.reversed().compactMap { signal in
                try? AgentTaskContent.decode(signal).interactionID
            }.first
            let cancel = AgentTaskRequest(
                text: "Cancel this assignment", replyTo: terminal == "waitingUser" ? scope.id : nil,
                interactionID: terminal == "waitingUser" ? interaction : nil)
            _ = try await sendWriterMessage(cancel, through: messaging, records: records, session: session)
        }
        // Join all owned work before examining final files and late window effects.
        await writer.stop()
        let inventory = try await workspace.inventory()
        item["inventory"] = inventory
        let selectedRequest = try await records.writerExecutions.request(delegateID, agent: "writer")
        let selectedTask =
            selectedRequest.workspaceID.isEmpty
            ? nil : try await records.writerExecutions.workspace(selectedRequest.workspaceID, agent: "writer")
        let target = scenario.targetSeed.flatMap { seeds[$0] } ?? previous ?? selectedTask
        var files: [String: String] = [:]
        if let target, let id = WorkspaceID(rawValue: target.workspaceID),
            let project = try? await workspace.project(id)
        {
            files = project.files
        }
        item["files"] = files
        var seedAfter: [String: [String: String]] = [:]
        for (name, original) in before {
            let after = try? await workspace.project(original.id)
            seedAfter[name] = after?.files
            if name == scenario.deleteSeed {
                if after != nil { issues.append("Requested deletion did not remove target") }
            } else if scenario.library == true || (scenario.resumeSeed != name && scenario.targetSeed != name) {
                if after?.files != original.files { issues.append("Unrelated saved work changed: \(name)") }
            }
        }
        item["seedFilesAfter"] = seedAfter
        if scenario.library == true, let selectedTask,
            !before.values.contains(where: { $0.id.rawValue == selectedTask.workspaceID })
        {
            issues.append("Library-only operation created a workspace")
        }
        if scenario.noNewWorkspace == true, inventory.count != before.count {
            issues.append("Lookup/edit created another workspace")
        }
        for (path, values) in scenario.contains ?? [:] {
            for value in values where !writerPromptContains(files[path] ?? "", expected: value) {
                issues.append("Missing content \(path): \(value)")
            }
        }
        for (path, values) in scenario.notContains ?? [:] {
            for value in values where (files[path] ?? "").contains(value) {
                issues.append("Forbidden content \(path): \(value)")
            }
        }
        for path in scenario.requiredFiles ?? [] where files[path] == nil { issues.append("Missing file: \(path)") }
        for path in scenario.forbiddenFiles ?? [] where files[path] != nil {
            issues.append("Unrequested file: \(path)")
        }
        let original = (scenario.resumeSeed ?? scenario.targetSeed).flatMap { before[$0] }
        for path in scenario.unchangedFiles ?? [] where files[path] != original?.files[path] {
            issues.append("Unrelated file changed: \(path)")
        }
        if let replacement = scenario.exactReplacement, let path = replacement["path"], let old = replacement["old"],
            let new = replacement["new"],
            files[path] != original?.files[path]?.replacingOccurrences(of: old, with: new)
        {
            issues.append("Local replacement changed unrelated bytes")
        }
        let archive = try await journal.readCurrent()
        try JSONEncoder().encode(archive.current).write(
            to: root.appendingPathComponent("history.json"), options: .atomic)
        let trace = await model.records
        let commands = trace.flatMap { record in
            record.filter { $0.key.hasPrefix("toolName.") }.map(\.value)
        }
        item["commands"] = commands
        if let firstRequest = trace.first(where: { $0["firstTool"] != nil }),
            let firstTool = firstRequest["firstTool"]
        {
            item["firstTool"] = firstTool
            item["firstToolArguments"] = firstRequest["firstToolArguments"]
            if let expected = scenario.firstCommand, firstTool != expected {
                issues.append("Expected first operation \(expected), got \(firstTool)")
            }
        } else if let expected = scenario.firstCommand {
            issues.append("Expected first operation \(expected), no tool called")
        }
        for command in scenario.requiredCommands ?? [] where !commands.contains(command) {
            issues.append("Required operation missing: \(command)")
        }
        for command in scenario.forbiddenCommands ?? [] where commands.contains(command) {
            issues.append("Forbidden operation: \(command)")
        }
        let renders = await host.renders.filter { Double($0["at"] ?? "0") ?? 0 >= eventStart }
        let events = await host.events.filter { Double($0["at"] ?? "0") ?? 0 >= eventStart }
        item["renders"] = renders
        item["windowEvents"] = events
        let windows = await host.windows.windows
        item["finalWindowModes"] = windows.map { $0.mode.rawValue }
        let windowIDs = Set(renders.compactMap { $0["windowID"] }.filter { !$0.isEmpty })
        let hostEventFired = await host.fired
        switch scenario.windowRule {
        case "none": if !renders.isEmpty || !windows.isEmpty { issues.append("Unexpected window/presentation") }
        case "one": if windowIDs.count != 1 || windows.count != 1 { issues.append("Expected one stable window") }
        case "closed":
            if !windows.isEmpty || !hostEventFired {
                issues.append("Closed window resurrected or event not exercised")
            }
        case "minimized":
            if windows.first?.mode != .minimized || !hostEventFired {
                issues.append("Minimized preference lost or event not exercised")
            }
        case "deferred":
            if !windows.isEmpty || !renders.contains(where: { $0["status"] == "deferred" }) {
                issues.append("Hidden scene did not defer rendering")
            }
        default: break
        }
        if let raw = renders.last(where: { $0["preview"] == "false" })?["dom"],
            let dom = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        {
            item["lastDOM"] = dom
            for text in scenario.domContains ?? [] where !(dom["text"] as? String ?? "").contains(text) {
                issues.append("Rendered text missing: \(text)")
            }
            if scenario.counter == true
                && (dom["counterBefore"] as? String != "0" || dom["counterAfter"] as? String != "1")
            {
                issues.append("Counter interaction failed")
            }
            if scenario.diagram == true && (dom["svg"] as? Int ?? 0) == 0
                && !files.values.contains(where: { $0.contains("<canvas") || $0.contains("border") })
            {
                issues.append("Diagram structure missing")
            }
            if dom["overflow"] as? Bool == true { issues.append("Horizontal overflow at mobile viewport") }
        } else if scenario.counter == true || scenario.domContains != nil {
            issues.append("No final rendered DOM evidence")
        }
        if scenario.hostEvent == "hidden" {
            await host.presentation.setSceneActive(true)
            await host.presentation.waitForSceneRestoration()
            item["restoredWindowCount"] = await host.windows.windows.count
            if await host.windows.windows.count != 1 { issues.append("Foreground restore did not show saved work") }
        }
    } catch { issues.append(String(describing: error)) }
    await writer.stop()
    try await artifacts.shutdown()
    await host.stop()
    try await records.shutdown()
    item["requests"] = await model.records.count
    item["contentRequests"] = await model.records.filter { $0["phase"] == "content" }.count
    item["requestTrace"] = await model.records
    item["seconds"] = Date().timeIntervalSince(started)
    item["issues"] = issues
    item["passed"] = issues.isEmpty
    return item
}

// Numeric content assertions accept standard thousands separators; exactReplacement remains byte-exact.
func writerPromptContains(_ text: String, expected: String) -> Bool {
    if text.contains(expected) { return true }
    guard !expected.isEmpty, expected.allSatisfy({ $0.isNumber }) else { return false }
    return text.replacingOccurrences(of: ",", with: "").contains(expected)
}

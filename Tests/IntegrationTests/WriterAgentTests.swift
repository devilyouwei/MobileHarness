import Actions
import AgentCore
import CallRuntime
import Foundation
import FunctionContracts
import Gateway
import ModelKit
import StorageChat
import StorageCore
import StorageFiles
import StorageMedia
import StorageSQLite
import StorageTasks
import Testing
import UI

@testable import Agents

private actor WriterNativeFixture: ChatCapability {
    nonisolated var availability: CapabilityAvailability { .available }
    nonisolated let supportsToolCalls = true
    let asks: Bool
    let failsNetwork: Bool
    let invalidArguments: Bool
    let exactPatch: Bool
    let slowContent: Bool
    let naturalEnd: Bool
    let observe: @Sendable (Int) async throws -> Void
    init(
        asks: Bool, failsNetwork: Bool = false, invalidArguments: Bool = false, exactPatch: Bool = false,
        slowContent: Bool = false, naturalEnd: Bool = false,
        observe: @escaping @Sendable (Int) async throws -> Void = { _ in }
    ) {
        self.asks = asks
        self.failsNetwork = failsNetwork
        self.invalidArguments = invalidArguments
        self.exactPatch = exactPatch
        self.slowContent = slowContent
        self.naturalEnd = naturalEnd
        self.observe = observe
    }
    var requests = 0
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        requests += 1
        try await observe(requests)
        if failsNetwork, requests >= 2 { throw WriterNetworkFixtureFailure() }
        let pair = InferenceSession<ChatEvent>.make(limits: try .init(), estimatedBytes: { $0.estimatedBytes })
        if request.tools.isEmpty {
            if slowContent {
                try pair.emitter.yield(.text("# Hello\n"))
                Task {
                    do {
                        try await Task.sleep(for: .seconds(2))
                        try await pair.emitter.yieldSuspending(.text("流式创作"))
                        try await pair.emitter.yieldSuspending(.finished(.stop))
                        pair.emitter.finish()
                    } catch { pair.emitter.fail(error) }
                }
                return pair.session
            }
            try pair.emitter.yield(.text("# Hello\n流式创作"))
            try pair.emitter.yield(.finished(.stop))
        } else {
            if naturalEnd, requests == 4 {
                try pair.emitter.yield(.text("作品已经完成。"))
                try pair.emitter.yield(.finished(.stop))
                pair.emitter.finish()
                return pair.session
            }
            let policy = request.messages.first(where: { $0.role == .system })?.content ?? ""
            #expect(policy.contains("Assistant delegates the goal and owns user conversation"))
            #expect(policy.contains("Your private workflow uses tools, never XML scheduling"))
            #expect(policy.contains("Do not invent extra features"))
            let schema = try #require(
                try JSONSerialization.jsonObject(with: request.tools[0].declaration) as? [String: Any])
            let function = try #require(schema["function"] as? [String: Any])
            let parameters = try #require(function["parameters"] as? [String: Any])
            let properties = try #require(parameters["properties"] as? [String: [String: Any]])
            #expect((properties["start"]?["description"] as? String)?.contains("decimal") == true)
            #expect((properties["command"]?["enum"] as? [String])?.contains("move") == true)
            let command: [String: String]
            if exactPatch, requests == 3 {
                command = ["command": "read", "path": "document.md"]
            } else if exactPatch, requests == 4 {
                let text = try #require(request.messages.last(where: { $0.role == .tool })?.content)
                let read = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                let reference = try #require(read["reference"] as? String)
                command = [
                    "command": "replace", "path": "document.md", "reference": reference,
                    "oldText": "Hello", "newText": "Hello 修订",
                ]
            } else if exactPatch, requests == 5 {
                command = ["command": "render"]
            } else {
                switch failsNetwork ? -1 : requests - (asks || invalidArguments ? 1 : 0) {
                case -1: command = ["command": "list"]
                case 0:
                    command =
                        invalidArguments
                        ? ["command": "list", "verification": "ok"] : ["command": "ask", "summary": "希望用什么语言？"]
                case 1: command = ["command": "edit", "path": "document.md", "instruction": "Write greeting"]
                case 3: command = ["command": "render"]
                default: command = ["command": "finish", "summary": "已完成"]
                }
            }
            try pair.emitter.yield(
                .toolCall(
                    .init(
                        id: UUID().uuidString, name: "workspace",
                        argumentsJSON: String(decoding: try JSONEncoder().encode(command), as: UTF8.self))))
            try pair.emitter.yield(.finished(.toolCalls))
        }
        pair.emitter.finish()
        return pair.session
    }
}
private struct WriterNetworkFixtureFailure: Error, ChatFailureProviding {
    var chatFailure: ChatFailureDiagnostic {
        .init(.transport, stage: .stream, networkReason: .timeout, networkCode: -1001)
    }
}
private actor WriterFailureOutputProbe {
    var values: [AgentFailureDiagnostic] = []
    func append(_ envelope: OutputEnvelope) { if let failure = envelope.failure { values.append(failure) } }
}
private actor WriterResultSink: Agent {
    nonisolated let descriptor = AgentDescriptor(
        id: .assistant, name: "Assistant fixture", inputs: [.observation, .communicationReceipt],
        outputs: [.communication])
    nonisolated let outputs = AsyncStream<OutputEnvelope> { $0.finish() }
    var signals: [AgentTaskSignal] = []
    var rejectedCompletion: String?
    var blocksReports: Bool
    var rejectedReports: [String] = []
    var retirements: [AgentTaskSignal] = []
    let blocksRetirement: Bool
    init(blocksReports: Bool = false, blocksRetirement: Bool = false) {
        self.blocksReports = blocksReports
        self.blocksRetirement = blocksRetirement
    }
    func allowReports() { blocksReports = false }
    func start() {}
    func pause() {}
    func resume() {}
    func stop() {}
    func receive(_ input: AgentInput) throws {
        if case .observation(let message) = input.payload {
            if let signal = message.content(as: AgentTaskSignal.self), signal.kind == .result {
                retirements.append(signal)
                if blocksRetirement { throw CommunicationError.unavailableTarget }
                return
            }
            guard
                let signal = message.content(as: WriterTaskCompletion.self)?.signal
                    ?? message.content(as: AgentTaskSignal.self)
            else { return }
            if blocksReports {
                if let event = try AgentTaskContent.decode(signal).writerEvent { rejectedReports.append(event.eventID) }
                throw CommunicationError.unavailableTarget
            }
            if message.content(as: WriterTaskCompletion.self) != nil,
                let event = try AgentTaskContent.decode(signal).writerEvent,
                event.kind == .completed, rejectedCompletion == nil
            {
                rejectedCompletion = event.eventID
                throw HarnessError.queueFull
            }
            signals.append(signal)
        }
    }
    func status() -> AgentStatus { .init(lifecycle: .running, queuedInputs: 0, processedInputs: signals.count) }
}
@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
func writerBackgroundRoleUsesDirectGatewayAndPublishesActualArtifact(mode: Int)
    async throws
{
    let asks = [1, 2, 4].contains(mode)
    let cancels = mode == 2
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = ArtifactWorkspace(
        disk: try DiskFileStore(root: root), index: try MemoryDocumentStore<ArtifactWorkspaceIndex>())
    let startup = WriterStartupProbe()
    let expectedSource = mode == 9 ? "# Hello 修订\n流式创作" : "# Hello\n流式创作"
    let artifacts = ArtifactService(
        workspace: workspace,
        present: { _, _, _, files, preview in
            let previous = await startup.shown
            await startup.mark()
            if mode == 5 && !previous { throw WriterFailure.unavailable }
            if mode == 10, preview, files["document.md"] == "# Hello\n" { await startup.sawPartial() }
            if !preview {
                #expect(files["document.md"] == expectedSource)
                if mode == 10 { #expect(await startup.partial) }
            }
            return "Rendered fixture"
        })
    let islandState = await IslandState()
    await islandState.setAvailable(true)
    let islandService = await IslandPresentationService(state: islandState)
    let model = WriterNativeFixture(
        asks: asks, failsNetwork: mode == 6, invalidArguments: mode == 8, exactPatch: mode == 9,
        slowContent: mode == 10, naturalEnd: mode == 11
    ) { request in
        guard mode == 7, request == 1 || request == 3 else { return }
        let expected = request == 1 ? "第1轮" : "第3轮"
        let deadline = ContinuousClock.now + .seconds(3)
        while await islandState.detailActivity?.content.detail?.text?.contains(expected) != true {
            guard ContinuousClock.now < deadline else { throw WriterFailure.incomplete }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await islandState.detailActivity?.content.subtitle == "正在创作")
    }
    let records = try SQLiteRepositories.temporary()
    let journal = ConversationHistoryStore(
        records: try ConversationRecordStore(repository: records.chat, tasks: records.tasks, agent: "writer"))
    let writer = try WriterAgent(
        model: {
            #expect(await startup.shown)
            let inventory = try await workspace.inventory()
            let project = try #require(inventory.first?["projectID"])
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(project).path))
            if mode == 3 { throw CancellationError() }
            return ChatModel(capability: model, modelName: "writer-fixture")
        }, streaming: artifacts, history: journal, tasks: records.tasks)
    let sink = WriterResultSink(blocksReports: mode == 7)
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
    let failureOutput = WriterFailureOutputProbe()
    let output = await OutputGateway(
        manager: manager, requests: input, tools: assembly.tools, policy: policy,
        sink: { await failureOutput.append($0) })
    await writer.bind(try await output.consumer(for: writer))
    try await manager.start(.writer)
    let task = try await records.tasks.beginDelegation(
        taskID: nil, goal: "写一段问候", input: "写一段问候", sourceDialog: nil, agent: "writer")
    let scope = try AgentTaskScope(
        id: task.runID, requester: .assistant, executor: .writer, sessionID: session, execution: .background)
    let signal = try AgentTaskSignal(
        kind: .request, scope: scope, businessContract: "writer.author",
        data: JSONEncoder().encode(["request": "写一段问候", "entry": "document.md", "taskID": task.id]))
    let messaging = try await output.messaging(for: .assistant)
    let report = try await messaging.send(
        signal.message(), parent: AgentInput(id: UUID().uuidString, sessionID: session, payload: .text("写作")),
        to: .writer)
    #expect(report.rejected.isEmpty)
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    var answered = false
    var pausedDelivery = false
    var verifiedIndependent = false
    while !(await sink.signals.contains { $0.kind == .result }) {
        if mode == 7, !verifiedIndependent, await model.requests == 4, !(try await workspace.list()).isEmpty {
            let saved = try await records.tasks.delegatedTask(task.id, agent: "writer")
            let presented = await islandState.detailActivity == nil
            if saved.status == "completed", presented {
                #expect(await sink.signals.isEmpty)
                #expect(await !sink.rejectedReports.isEmpty)
                let firstEvent = await sink.rejectedReports.first
                #expect(await writer.observationSnapshot().business["phase"] == .text("idle"))
                await sink.allowReports()
                verifiedIndependent = true
                // All retries retain their identity; no extra model/file execution.
                #expect(await model.requests == 4)
                #expect(firstEvent != nil)
            }
        }
        if !asks, !pausedDelivery, await sink.rejectedCompletion != nil {
            try await writer.pause()
            #expect(await writer.status().lifecycle == .paused)
            try await writer.resume()
            pausedDelivery = true
        }
        if asks, !answered, let pending = await sink.signals.last(where: { $0.kind == .progress }),
            let content = try? AgentTaskContent.decode(pending), content.stage == .waitingUser
        {
            if mode == 4 {
                await writer.stop()
                #expect(try await records.tasks.delegatedTask(task.id, agent: "writer").status == "interrupted")
                #expect(try await records.tasks.taskNotification(scope.id, agent: "writer") != nil)
                await output.shutdown()
                try await records.shutdown()
                await islandState.stop()
                return
            }
            let competing = try AgentTaskScope(
                id: UUID().uuidString, requester: .assistant, executor: .writer,
                sessionID: session, execution: .background)
            let competingRequest = try AgentTaskSignal(
                kind: .request, scope: competing, businessContract: "writer.author",
                data: JSONEncoder().encode(["request": "another"]))
            #expect(
                !(try await messaging.send(
                    competingRequest.message(),
                    parent: .init(
                        id: UUID().uuidString,
                        sessionID: session, payload: .text("another")), to: .writer)).rejected.isEmpty)
            let wrong = try AgentTaskContent(text: "wrong", interactionID: UUID().uuidString).signal(
                .input, scope: scope)
            #expect(
                !(try await messaging.send(
                    wrong.message(),
                    parent: .init(
                        id: UUID().uuidString,
                        sessionID: session, payload: .text("wrong")), to: .writer)).rejected.isEmpty)
            let answer = try AgentTaskContent(text: cancels ? "取消" : "中文", interactionID: content.interactionID).signal(
                cancels ? .cancel : .input, scope: scope)
            let receipt = try await messaging.send(
                answer.message(),
                parent: AgentInput(id: UUID().uuidString, sessionID: session, payload: .text("中文")), to: .writer)
            #expect(receipt.rejected.isEmpty)
            answered = true
        }
        guard ContinuousClock.now < deadline else { throw WriterFailure.incomplete }
        try await Task.sleep(for: .milliseconds(10))
    }
    let result = try #require(await sink.signals.last { $0.kind == .result })
    let resultText = try AgentTaskContent.decode(result).text
    if mode == 5 {
        #expect(result.status == .failed)
        let pending = try await records.tasks.delegatedTask(task.id, agent: "writer")
        let project = try #require(pending.projectID)
        #expect(!pending.workspaceReady)
        let retry = try await records.tasks.beginDelegation(
            taskID: task.id, goal: "重试", input: "继续原任务", sourceDialog: nil, agent: "writer")
        let nextScope = try AgentTaskScope(
            id: retry.runID, requester: .assistant, executor: .writer, sessionID: session, execution: .background)
        let next = try AgentTaskSignal(
            kind: .request, scope: nextScope, businessContract: "writer.author",
            data: JSONEncoder().encode([
                "request": "继续原任务", "entry": "document.md", "taskID": task.id, "projectID": project,
            ]))
        let receipt = try await messaging.send(
            next.message(), parent: .init(id: UUID().uuidString, sessionID: session, payload: .text("重试")), to: .writer)
        #expect(receipt.rejected.isEmpty)
        let until = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await sink.signals.contains { $0.kind == .result && $0.scope.id == retry.runID }) {
            guard ContinuousClock.now < until else { throw WriterFailure.incomplete }
            try await Task.sleep(for: .milliseconds(10))
        }
        let completed = try await records.tasks.delegatedTask(task.id, agent: "writer")
        #expect(completed.projectID == project && completed.workspaceReady && completed.status == "completed")
        let roots = try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
            UUID(uuidString: $0) != nil
        }
        #expect(roots == [project])
        await writer.stop()
        await output.shutdown()
        try await records.shutdown()
        await islandState.stop()
        return
    }
    if [3, 4, 6].contains(mode) {
        if mode == 6 {
            let diagnostic = try #require(try AgentTaskContent.decode(result).writerEvent?.failure)
            #expect(diagnostic.category == "modelTransport" && diagnostic.code == "writer.network.timeout")
            #expect(diagnostic.stage == "控制请求" && diagnostic.details["networkCode"] == "-1001")
            #expect(diagnostic.details["model"] == "writer-fixture" && diagnostic.details["inputID"] != nil)
            #expect(diagnostic.details["elapsedSeconds"] != nil && diagnostic.details["providerStage"] == "stream")
            #expect(await failureOutput.values.last?.category == .modelTransport)
            let saved = try await journal.readCurrent().current.turns.last?.modelRequests?.last
            #expect(saved?.failureDiagnostic == diagnostic.storageValue)
            #expect(await model.requests == 4)
            #expect(
                try await records.tasks.delegatedTask(task.id, agent: "writer").failure?.contains(
                    "code=writer.network.timeout") == true)
        }

        #expect(result.status == .failed)
        #expect(try AgentTaskContent.decode(result).writerEvent?.kind == .failed)
        #expect(
            try await records.tasks.delegatedTask(task.id, agent: "writer").status
                == (mode == 4 ? "interrupted" : "failed"))
        await writer.stop()
        await output.shutdown()
        try await records.shutdown()
        await islandState.stop()
        return
    }
    if cancels {
        #expect(result.status == .cancelled)
        #expect(try AgentTaskContent.decode(result).writerEvent?.kind == .cancelled)
        #expect(await model.requests == 1)
        #expect(try await workspace.list().isEmpty)
        await writer.stop()
        await output.shutdown()
        try await records.shutdown()
        await islandState.stop()
        return
    }
    #expect(result.status == .succeeded, "\(resultText)")
    if mode == 7 { #expect(verifiedIndependent) }
    let saved = try await records.tasks.delegatedTask(task.id, agent: "writer")
    #expect(saved.status == "completed" && saved.projectID != nil)
    if !asks { #expect(pausedDelivery) }
    #expect(try AgentTaskContent.decode(result).writerEvent?.eventID == (await sink.rejectedCompletion))
    let evidence = await sink.signals.filter {
        $0.kind == .result && (try? AgentTaskContent.decode($0).writerEvent?.kind) == .completed
    }
    #expect(evidence.count == 1)
    #expect(try await workspace.list().first?.files["document.md"] == expectedSource)
    #expect(await model.requests == (mode == 9 ? 6 : asks || mode == 8 ? 5 : 4))
    #expect(try AgentTaskContent.decode(result).artifactID != nil)
    let current = try await journal.readCurrent().current
    #expect(current.turns.count == (mode == 9 ? 6 : asks || mode == 8 ? 5 : 4))
    #expect(current.turns.flatMap { $0.modelRequests ?? [] }.contains { $0.response.contains("流式创作") })
    if mode == 11 {
        let last = try #require(current.turns.last?.modelRequests?.last)
        #expect(last.toolCalls.isEmpty)
        #expect(current.turns.last?.generationRounds?.first?.resultsJSON.contains("writer.runtime") == true)
    }
    let facts = await sink.signals.compactMap { try? AgentTaskContent.decode($0).writerEvent?.request }
    if mode != 7 { #expect(!facts.isEmpty) }

    let recordedCalls = current.turns.flatMap { $0.modelRequests ?? [] }.flatMap(\.toolCalls)
    #expect(recordedCalls.allSatisfy { $0.state == .completed || mode == 8 && $0.state == .failed })
    if mode == 8 {
        let failure = try #require(recordedCalls.first?.failureDiagnostic)
        #expect(failure.category == "tool")
        #expect(failure.details["validationCode"] == "invalidParameters")
        #expect(failure.details["executed"] == "false")
    }
    await writer.stop()
    await output.shutdown()
    try await records.shutdown()
    await islandState.stop()
}

@Test(.actionCatalog) func artifactServiceIsolatesProjectsAndRejectsCrossTaskStreams() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = ArtifactWorkspace(
        disk: try DiskFileStore(root: root), index: try MemoryDocumentStore<ArtifactWorkspaceIndex>())
    let service = ArtifactService(workspace: workspace, present: { _, _, _, _, _ in "Rendered fixture" })
    func invocation(_ task: String, _ parameters: [String: String]) throws -> FunctionInvocation {
        .init(
            call: .init(
                actionPath: ActionIdentifier(domain: "Artifacts", module: "Workspace", function: "perform"),
                parameters: parameters),
            context: .init(source: "writer", sessionID: "session", inputID: task, taskID: task),
            executionID: UUID().uuidString, results: ActionReportStore())
    }
    let first = try await service.perform(invocation: invocation("one", ["command": "start"]))
    let project = try #require(JSONDecoder().decode([String: String].self, from: Data(first.utf8))["projectID"])
    await #expect(throws: ArtifactWorkspaceError.busy) {
        try await service.perform(invocation: invocation("two", ["command": "start", "projectID": project]))
    }
    await #expect(throws: ArtifactWorkspaceError.busy) {
        try await service.perform(invocation: invocation("two", ["command": "start", "entry": "document.txt"]))
    }
    await #expect(throws: ArtifactWorkspaceError.busy) {
        try await service.perform(invocation: invocation("three", ["command": "start"]))
    }
    let edit = try await service.perform(
        invocation: invocation("one", ["command": "edit", "path": "index.html", "instruction": "Create"]))
    let stream = try #require(JSONDecoder().decode([String: String].self, from: Data(edit.utf8))["streamID"])
    await #expect(throws: ArtifactWorkspaceError.conflict) {
        try await service.append(streamID: stream, taskID: "two", text: "wrong owner")
    }
    try await service.append(streamID: stream, taskID: "one", text: "<p>draft")
    try await service.release(taskID: "one")
    await #expect(throws: ArtifactWorkspaceError.conflict) {
        try await service.append(streamID: stream, taskID: "one", text: "late")
    }
    let projectID = try #require(UUID(uuidString: project))
    let checkpoint = try #require(await workspace.checkpoint(for: projectID))
    #expect(checkpoint.draft.files["index.html"] == "<p>draft")
    #expect(try await workspace.list().isEmpty)
    _ = try await service.perform(invocation: invocation("three", ["command": "start", "projectID": project]))
    try await service.release(taskID: "two")
    try await service.release(taskID: "three")
}

private actor WriterRenderProbe {
    var prepared = 0
    func prepare() { prepared += 1 }
    var frames: [([String: String], Bool)] = []
    var status = "observed"
    func present(_ files: [String: String], _ preview: Bool) -> String {
        frames.append((files, preview))
        return "{\"status\":\"\(status)\"}"
    }
    func fail() { status = "errors" }
}

@Test(.actionCatalog) func writerControlsPreviewAndSearchPaginationAndDraftRecovery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = ArtifactWorkspace(
        disk: try DiskFileStore(root: root), index: try MemoryDocumentStore<ArtifactWorkspaceIndex>())
    let probe = WriterRenderProbe()
    let service = ArtifactService(
        workspace: workspace, prepare: { _, _ in await probe.prepare() },
        present: { _, _, _, files, preview in await probe.present(files, preview) })
    func call(_ parameters: [String: String]) async throws -> String {
        try await service.perform(
            invocation: FunctionInvocation(
                call: .init(
                    actionPath: ActionIdentifier(domain: "Artifacts", module: "Workspace", function: "perform"),
                    parameters: parameters),
                context: .init(source: "writer", sessionID: "s", inputID: "t", taskID: "t"),
                executionID: UUID().uuidString, results: ActionReportStore()))
    }
    func strings(_ value: String) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: Data(value.utf8))
    }
    let started = try strings(await call(["command": "start"]))
    let projectID = try #require(started["projectID"])
    #expect(await probe.prepared == 1)
    let first = try strings(await call(["command": "edit", "path": "index.html", "instruction": "Create"]))
    let stream = try #require(first["streamID"])
    try await Task.sleep(for: .milliseconds(210))
    try await service.append(streamID: stream, taskID: "t", text: "<h1 class=diagram>Hello</h1>")
    _ = try await service.complete(streamID: stream, taskID: "t")
    #expect(await probe.frames.count == 1)  // Only the startup placeholder, no edit-driven render.
    let read = try #require(
        JSONSerialization.jsonObject(with: Data(try await call(["command": "read", "path": "index.html"]).utf8))
            as? [String: Any])
    let reference = try #require(read["reference"] as? String)
    await #expect(throws: ArtifactWorkspaceError.invalidPath) {
        try await call(["command": "move", "path": "index.html", "destination": "entry.css"])
    }

    let edit = try strings(
        await call([
            "command": "edit", "path": "styles/a.css", "instruction": "Use selector", "contextReferences": reference,
        ]))
    #expect(edit["context"]?.contains("class=diagram") == true)
    let live = try #require(edit["streamID"])
    let css = (0..<40).map { ".diagram { --value: \($0); }" }.joined(separator: "\n")
    try await service.append(streamID: live, taskID: "t", text: css)
    _ = try await service.complete(streamID: live, taskID: "t")
    _ = try await call(["command": "preview"])
    #expect(await probe.frames.last?.0["styles/a.css"] == css)
    #expect(await probe.frames.last?.1 == true)
    // Opt-in belongs to one edit, not the next one or another project.
    let count = await probe.frames.count
    let next = try strings(await call(["command": "edit", "path": "note.txt", "instruction": "Write"]))
    let nextID = try #require(next["streamID"])
    try await service.append(streamID: nextID, taskID: "t", text: "note")
    _ = try await service.complete(streamID: nextID, taskID: "t")
    #expect(await probe.frames.count == count)
    let search = try #require(
        JSONSerialization.jsonObject(
            with: Data(try await call(["command": "search", "query": ".diagram", "path": "styles"]).utf8))
            as? [String: Any])
    #expect(search["total"] as? Int == 40)
    #expect(search["nextOffset"] as? Int == 16)
    let page = try #require(
        JSONSerialization.jsonObject(
            with: Data(
                try await call(["command": "search", "query": ".diagram", "path": "styles", "offset": "32"]).utf8))
            as? [String: Any])
    #expect((page["matches"] as? [[String: String]])?.count == 8)
    #expect(page["nextOffset"] == nil)
    let point = try #require(strings(await call(["command": "savepoint"]))["savepoint"])
    _ = try await call(["command": "read", "path": "styles/a.css"])
    _ = try await call(["command": "move", "path": "styles", "destination": "assets"])
    #expect(
        try JSONDecoder().decode([[String: String]].self, from: Data(await call(["command": "list"]).utf8)).contains {
            $0["path"] == "assets/a.css"
        })
    let diff = try await call(["command": "diff", "savepoint": point])
    #expect(diff.contains("firstChangedLine"))
    _ = try await call(["command": "restore", "savepoint": point])
    #expect(
        try JSONDecoder().decode([[String: String]].self, from: Data(await call(["command": "list"]).utf8)).contains {
            $0["path"] == "styles/a.css"
        })
    await #expect(throws: ArtifactWorkspaceError.renderRequired) { try await call(["command": "finish"]) }
    _ = try await call(["command": "render"])
    let result = try strings(await call(["command": "finish"]))
    #expect(result["verification"] == "observed")
    let versions = try await call(["command": "versions"])
    #expect(versions.contains(try #require(result["revision"])))
    await probe.fail()
    _ = try await call(["command": "render"])
    await #expect(throws: ArtifactWorkspaceError.renderRequired) { try await call(["command": "finish"]) }
    try await service.release(taskID: "t")
    _ = try await call(["command": "resume", "projectID": projectID])
    #expect(await probe.prepared == 1)
    try await service.release(taskID: "t")
    _ = try await call(["command": "start", "projectID": projectID])
    #expect(await probe.prepared == 2)
    try await service.release(taskID: "t")
}

@Test func writerHistoryPersistsExactRequestsAndSeparatesAssistantInSQLite() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let database = try SQLiteRepositories(url: url)
    let assistant = try await database.chat.current(agent: "assistant")
    let store = ConversationHistoryStore(
        records: try ConversationRecordStore(repository: database.chat, tasks: database.tasks, agent: "writer"))
    let task = try await database.tasks.beginDelegation(
        taskID: nil, goal: "绘图", input: "画一张图", sourceDialog: assistant.id, agent: "writer")
    let history = WriterHistory(store: store, taskID: task.id, goal: "画一张图 · project abc")
    let request = try ChatRequest(
        messages: [.init(role: .system, content: "Writer policy"), .init(role: .user, content: "<h1>中文 🌍</h1>")],
        maximumOutputTokens: 2048, temperature: 0.2)
    let id = try await history.begin(request, phase: "内容")
    try await history.event(.text("<h1>完成</h1>"), id: id)
    try await history.event(.toolCall(.init(id: "call", name: "workspace", argumentsJSON: "{}")), id: id)
    try await history.event(.usage(try .init(input: 5, generated: 7, total: 12)), id: id)
    try await history.event(.finished(.stop), id: id)
    try await history.finish(id)
    try await history.toolOutcome("call", output: "Saved artifact abc")
    let cancelled = try await history.begin(request, phase: "控制")
    try await history.event(.text("partial"), id: cancelled)
    try await history.finish(cancelled, error: CancellationError())
    let failed = try await history.begin(request, phase: "控制请求")
    let diagnostic = WriterDiagnostics.make(
        WriterNetworkFixtureFailure(), stage: "控制请求", details: ["model": "fixture", "elapsedSeconds": "60.030"])
    try await history.finish(failed, error: WriterNetworkFixtureFailure(), diagnostic: diagnostic)
    let dialog = try await store.readCurrent().current.id
    #expect(dialog != assistant.id)
    #expect(try database.chat.messages(dialog: assistant.id, after: nil, limit: 20).isEmpty)
    try await database.tasks.endTask(task.runID, status: "failed", failure: "fixture")
    try await database.shutdown()
    let reopened = try SQLiteRepositories(url: url)
    let restored = ConversationHistoryStore(
        records: try ConversationRecordStore(repository: reopened.chat, tasks: reopened.tasks, agent: "writer"))
    let restoredTask = try await reopened.tasks.delegatedTask(task.id, agent: "writer")
    #expect(restoredTask.dialogID == dialog)
    let value = try await restored.conversation(dialog)
    let record = try #require(value.turns.first { $0.id == id })
    #expect(record.temperature == 0.2)
    #expect(record.maximumOutputTokens == 2048)
    let modelRequest = try #require(record.modelRequests?.first)
    #expect(modelRequest.requestJSON.contains("中文 🌍"))
    #expect(modelRequest.response == "<h1>完成</h1>")
    #expect(modelRequest.decisionMetadata?.taskID == task.id)
    #expect(modelRequest.historyTaskID == nil)
    #expect(modelRequest.toolCalls.first?.output == "Saved artifact abc")
    #expect(modelRequest.toolCalls.first?.state == .completed)
    #expect(modelRequest.tokenUsage?.total == 12)
    #expect(modelRequest.finishReason == "stop")
    #expect(value.turns.first { $0.id == cancelled }?.state == .cancelled)
    let failure = try #require(value.turns.first { $0.id == failed }?.modelRequests?.last?.failureDiagnostic)
    #expect(failure == diagnostic.storageValue && failure.details["networkCode"] == "-1001")
    let projection = try JSONDecoder().decode(HistoryConversation.self, from: JSONEncoder().encode(value))
    let projected = try #require(projection.turns.first { $0.id == failed }?.modelRequests?.last?.failureDiagnostic)
    #expect(projected.category == failure.category && projected.details == failure.details)
    try await reopened.shutdown()
}

@Test func writerHistoryStoresImageReferencesWithWriterInputOwnership() async throws {
    let records = try SQLiteRepositories.temporary()
    let files = try MemoryFileStore()
    let photos = CapturedPhotoStore(repository: records.media, files: files)
    let store = ConversationHistoryStore(
        records: try ConversationRecordStore(repository: records.chat, tasks: records.tasks, agent: "writer"))
    let history = WriterHistory(store: store, taskID: "runtime", goal: "Inspect", photos: photos)
    // Storage contract fixture bytes, not a native image decoding acceptance test.
    let bytes = Data([1, 2, 3])
    let request = try ChatRequest(messages: [
        .init(role: .user, content: "Render", images: [try .init(id: "screenshot", data: bytes)])
    ])
    let id = try await history.begin(request, phase: "控制")
    try await history.finish(id)
    let turn = try #require(await store.readCurrent().current.turns.first)
    let json = try #require(turn.modelRequests?.first?.requestJSON)
    let messages = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    let references = try #require(messages.first?["imageReferences"] as? [[String: Any]])
    let mediaID = try #require(references.first?["id"] as? String)
    #expect(try await photos.readForInput(mediaID, source: "writer", input: id) == bytes)
    await #expect(throws: FileStorageError.invalidFile) {
        try await photos.readForInput(mediaID, source: "assistant", input: id)
    }
    #expect(!json.contains("AQID"))
    try await records.shutdown()
}

private actor WriterStartupProbe {
    var partial = false
    func sawPartial() { partial = true }
    var shown = false
    func mark() { shown = true }
}

@Test func delegatedWriterTasksKeepIdentityDirectoryAndNativeHistoryAcrossRuns() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let database = try SQLiteRepositories(url: url)
    let source = try await database.chat.current(agent: "assistant")
    let first = try await database.tasks.beginDelegation(
        taskID: nil, goal: "画流程图", input: "用户原始请求", sourceDialog: source.id, agent: "writer")
    let project = UUID().uuidString
    try await database.tasks.bindProject(project, taskID: first.id, runID: first.runID, agent: "writer")
    let journal = ConversationHistoryStore(
        records: try ConversationRecordStore(repository: database.chat, tasks: database.tasks, agent: "writer"))
    let history = WriterHistory(
        store: journal, taskID: first.id, runID: first.runID, goal: "画流程图", modelName: "fixture-model")
    let request = try ChatRequest(
        messages: [.init(role: .system, content: "policy"), .init(role: .user, content: "画流程图")],
        maximumOutputTokens: 2048, temperature: 0.2)
    let input = try await history.begin(request, phase: "控制请求")
    try await history.event(.text("先读文件"), id: input)
    try await history.event(
        .toolCall(.init(id: "read-1", name: "workspace", argumentsJSON: "{\"command\":\"read\"}")), id: input)
    try await history.finish(input)
    try await history.toolOutcome("read-1", output: "node A")
    try await database.tasks.endTask(first.runID, status: "completed")
    let second = try await database.tasks.beginDelegation(
        taskID: first.id, goal: "改为蓝色", input: "继续改成蓝色", sourceDialog: source.id, agent: "writer")
    #expect(second.id == first.id && second.runID != first.runID)
    #expect(second.dialogID == first.dialogID && second.projectID == project && second.goal == "画流程图")
    let restored = try await WriterHistory(store: journal, taskID: first.id, runID: second.runID, goal: "改为蓝色")
        .restoredContext()
    #expect(restored.contains { $0.role == .assistant && $0.toolCalls.first?.id == "read-1" })
    #expect(restored.contains { $0.role == .tool && $0.toolCallID == "read-1" && $0.content == "node A" })
    await #expect(throws: (any Error).self) {
        try await database.tasks.bindProject(UUID().uuidString, taskID: first.id, runID: first.runID, agent: "writer")
    }
    try await database.tasks.requestCancellation(runID: second.runID, reason: "Assistant forced replacement")
    try await database.tasks.endTask(second.runID, status: "cancelled")
    let third = try await database.tasks.beginDelegation(
        taskID: nil, goal: "新作品", input: "另画一张", sourceDialog: source.id, agent: "writer")
    #expect(third.id != first.id && third.dialogID != first.dialogID && third.projectID == nil)
    #expect(try await journal.readCurrent().current.id == third.dialogID)
    try await database.tasks.endTask(third.runID, status: "failed", failure: "fixture failure")
    let resumedAgain = try await database.tasks.beginDelegation(
        taskID: first.id, goal: "再次修改", input: "修改旧任务", sourceDialog: source.id, agent: "writer")
    #expect(resumedAgain.projectID == project && resumedAgain.dialogID == first.dialogID)
    let earlierContext = try await WriterHistory(
        store: journal, taskID: first.id, runID: resumedAgain.runID, goal: "再次修改"
    ).restoredContext()
    #expect(earlierContext.contains { $0.role == .tool && $0.toolCallID == "read-1" })
    try await database.tasks.endTask(resumedAgain.runID, status: "completed")
    // Writer histories have no cascading ownership by the requesting Assistant dialog.
    _ = try await database.chat.rotate(source.id, agent: "assistant")
    try await database.chat.deleteDialog(source.id)
    #expect(try await database.tasks.delegatedTask(first.id, agent: "writer").projectID == project)
    #expect(try await database.tasks.delegatedTasks(agent: "assistant", before: nil, limit: 20).isEmpty)
    try await database.shutdown()
    let reopened = try SQLiteRepositories(url: url)
    #expect(try await reopened.tasks.delegatedTask(first.id, agent: "writer").runID == resumedAgain.runID)
    let runs = try await reopened.tasks.delegatedRuns(first.id, agent: "writer")
    #expect(runs.count == 3 && runs[1].status == "cancelled" && runs.last?.status == "completed")
    #expect(runs[1].cancellationReason == "Assistant forced replacement")
    let records = ConversationHistoryStore(
        records: try ConversationRecordStore(repository: reopened.chat, tasks: reopened.tasks, agent: "writer"))
    let full = try await records.conversation(first.dialogID)
    #expect(full.turns.first?.model == "fixture-model")
    #expect(full.turns.first?.modelRequests?.first?.decisionMetadata?.runID == first.runID)
    try await reopened.shutdown()
}

@Test func writerCleanupFailureKeepsPrimaryNetworkCauseAndCleanupCause() throws {
    let network = WriterNetworkFixtureFailure()
    let storage = StorageFailure(component: "writer-files", operation: "release", underlying: FileStorageError.busy)
    let report = WriterDiagnostics.make(WriterCleanupFailure(primary: network, cleanup: storage), stage: "控制请求")
    #expect(report.category == "cleanup" && report.causes.count == 2)
    #expect(report.causes[0].code == "writer.network.timeout" && report.causes[0].details["networkCode"] == "-1001")
    #expect(report.causes[1].category == "storage" && report.causes[1].stage == "清理")
    #expect(
        try JSONDecoder().decode(ConversationFailureDiagnostic.self, from: JSONEncoder().encode(report))
            == report.storageValue)
}

@Test func writerProviderRejectionsKeepServiceCategory() {
    struct Fixture: ChatFailureProviding { let chatFailure: ChatFailureDiagnostic }
    let diagnostic = WriterDiagnostics.make(
        Fixture(chatFailure: .init(.providerFailure, stage: .event, providerCode: "credit_balance_exhausted")),
        stage: "控制请求")
    #expect(diagnostic.category == "modelProvider" && diagnostic.code == "writer.provider.failed")
    #expect(diagnostic.details["providerCode"] == "credit_balance_exhausted")
    #expect(!diagnostic.message.contains("协议"))
    #expect(WriterDiagnostics.output(diagnostic).category == .modelResponse)
}

@Test func writerWorkflowFailureKeepsCancelledRequestAsSecondaryEvidence() {
    let cancelled = WriterDiagnostics.make(CancellationError(), stage: "文件内容请求", details: ["inputID": "fixture"])
    let diagnostic = WriterDiagnostics.make(WriterFailure.invalidOutput, stage: "创作执行", request: cancelled)
    #expect(diagnostic.code == "writer.invalidOutput" && diagnostic.category == "workflow")
    #expect(diagnostic.causes.first?.code == "writer.cancelled")
}

/// The fake Writer endpoint commits exactly the same trusted completion evidence as production.
func fixtureWriterCompletion(
    _ content: AgentTaskContent, scope: AgentTaskScope, status: AgentTaskSignal.Status,
    tasks: any TaskRepository
) async throws -> WriterTaskCompletion {
    let run = try await tasks.delegatedRun(scope.id, agent: "writer")
    let event = try #require(content.writerEvent)
    let canonical = try AgentTaskContent(
        text: content.text, stage: .completed,
        interactionID: content.interactionID, artifactID: content.artifactID,
        writerEvent: .init(
            sequence: event.sequence, kind: event.kind, projectID: event.projectID,
            windowID: event.windowID, taskID: run.taskID, runID: run.runID, failure: event.failure,
            eventID: event.eventID))
    let report = try WriterTaskCompletion(canonical.signal(.result, scope: scope, status: status))
    try await tasks.completeDelegatedRun(
        .init(
            runID: run.runID, agent: "writer", eventID: event.eventID,
            data: JSONEncoder().encode(report)), status: status == .succeeded ? "completed" : status.rawValue,
        failure: status == .failed ? content.text : nil)
    return report
}

private actor WriterModelCount {
    var count = 0
    func acquire() -> ChatModel {
        count += 1
        return ChatModel(capability: WriterNativeFixture(asks: false), modelName: "independent-fixture")
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func writerAcceptsTwentyTasksWithAllUserNotificationsRejectedThenRestoresOnlyDelivery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let recordsURL = root.appendingPathComponent("records.sqlite")
    let records = try SQLiteRepositories(url: recordsURL)
    let workspace = ArtifactWorkspace(
        disk: try DiskFileStore(root: root.appendingPathComponent("files")),
        index: try MemoryDocumentStore<ArtifactWorkspaceIndex>())
    let artifacts = ArtifactService(workspace: workspace, present: { _, _, _, _, _ in "Rendered fixture" })
    let islandState = await IslandState()
    await islandState.setAvailable(true)
    let islandService = await IslandPresentationService(state: islandState)
    let models = WriterModelCount()
    let writer = try WriterAgent(
        model: { await models.acquire() }, streaming: artifacts,
        history: ConversationHistoryStore(
            records: try ConversationRecordStore(repository: records.chat, tasks: records.tasks, agent: "writer")),
        tasks: records.tasks)
    let sink = WriterResultSink(blocksReports: true, blocksRetirement: true)
    let session = UUID().uuidString
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, configurations: AgentConfigurations.all())
    let manager = AgentManager()
    try await manager.register(sink, sessionID: session)
    try await manager.register(writer)
    let input = InputGateway(manager: manager, policy: policy)
    let assembly = try BehaviorAssembly(capabilityModules: [
        ArtifactsModule(artifacts: artifacts), IslandModule(island: islandService),
    ])
    let output = await OutputGateway(
        manager: manager, requests: input, tools: assembly.tools, policy: policy, sink: { _ in })
    await writer.bind(try await output.consumer(for: writer))
    try await manager.start(.writer)
    let port = try await output.messaging(for: .assistant)
    var eventIDs: Set<String> = []
    var runs: [String] = []
    for index in 0..<20 {
        let record = try await records.tasks.beginDelegation(
            taskID: nil, goal: "Goal \(index)", input: "Write greeting", sourceDialog: nil, agent: "writer")
        let scope = AgentTaskScope(
            id: record.runID, requester: .assistant, executor: .writer, sessionID: session, execution: .background)
        let request = try AgentTaskSignal(
            kind: .request, scope: scope, businessContract: "writer.author",
            data: JSONEncoder().encode(["taskID": record.id, "request": "Write greeting", "entry": "document.md"]))
        let receipt = try await port.send(
            request.message(), parent: .init(id: UUID().uuidString, sessionID: session, payload: .text("Write")),
            to: .writer)
        #expect(receipt.rejected.isEmpty)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while true {
            let run = try await records.tasks.delegatedRun(record.runID, agent: "writer")
            let retired = try await records.tasks.taskNotification(record.runID, agent: "writer")?.retired == true
            if run.status == "completed", retired { break }
            guard ContinuousClock.now < deadline else { throw WriterFailure.incomplete }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await writer.observationSnapshot().business["phase"] == .text("idle"))
        let notification = try #require(try await records.tasks.taskNotification(record.runID, agent: "writer"))
        #expect(!notification.delivered)
        eventIDs.insert(notification.eventID)
        runs.append(record.runID)
    }
    let presentationDeadline = ContinuousClock.now.advanced(by: .seconds(3))
    while await islandState.detailActivity != nil {
        guard ContinuousClock.now < presentationDeadline else { throw WriterFailure.incomplete }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await islandState.activities.isEmpty)
    #expect(eventIDs.count == 20)
    #expect(await models.count == 20)
    #expect(await sink.signals.allSatisfy { $0.kind != .result })
    #expect(try await workspace.list().count == 20)
    #expect(
        try await records.tasks.pendingTaskNotifications(agent: "writer", retirement: false, after: nil, limit: 32)
            .count == 20)
    await writer.stop()
    await output.shutdown()
    try await records.shutdown()

    // Reopen with no execution grants, a new Writer incarnation and no delegated request.
    let reopened = try SQLiteRepositories(url: recordsURL)
    let restored = try WriterAgent(model: { await models.acquire() }, streaming: artifacts, tasks: reopened.tasks)
    let resumedSink = WriterResultSink()
    let newManager = AgentManager()
    try await newManager.register(resumedSink, sessionID: session)
    try await newManager.register(restored)
    let newInput = InputGateway(manager: newManager, policy: policy)
    let newOutput = await OutputGateway(
        manager: newManager, requests: newInput, tools: assembly.tools, policy: policy, sink: { _ in })
    await restored.bind(try await newOutput.consumer(for: restored))
    try await newManager.start(.writer)
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while await resumedSink.signals.filter({ $0.kind == .result }).count < 20 {
        guard ContinuousClock.now < deadline else { throw WriterFailure.incomplete }
        try await Task.sleep(for: .milliseconds(20))
    }
    while true {
        let notices = try await reopened.tasks.pendingTaskNotifications(
            agent: "writer", retirement: false, after: nil, limit: 1)
        let retirements = try await reopened.tasks.pendingTaskNotifications(
            agent: "writer", retirement: true, after: nil, limit: 1)
        if notices.isEmpty && retirements.isEmpty { break }
        guard ContinuousClock.now < deadline else { throw WriterFailure.incomplete }
        try await Task.sleep(for: .milliseconds(20))
    }
    let delivered = await resumedSink.signals.filter { $0.kind == .result }
    #expect(Set(try delivered.map { try #require(try AgentTaskContent.decode($0).writerEvent?.eventID) }) == eventIDs)
    #expect(await models.count == 20)
    #expect(await restored.observationSnapshot().business["phase"] == .text("idle"))
    #expect(try await reopened.tasks.delegatedTasks(agent: "writer", before: nil, limit: 50).count == 20)
    for run in runs {
        #expect(try await reopened.tasks.delegatedRun(run, agent: "writer").status == "completed")
    }
    await restored.stop()
    await newOutput.shutdown()
    try await reopened.shutdown()
    await islandState.stop()
}

@Test func writerTerminalNotificationCommitRollsBackConflictsAndKeepsIndependentReceipts() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let database = try SQLiteRepositories(url: url)
    let first = try await database.tasks.beginDelegation(
        taskID: nil, goal: "First", input: "First input", sourceDialog: nil, agent: "writer")
    let event = UUID().uuidString
    let notification = TaskNotification(
        runID: first.runID, agent: "writer", eventID: event, data: Data("immutable fact".utf8))
    try await database.tasks.completeDelegatedRun(notification, status: "completed", failure: nil)
    try await database.tasks.completeDelegatedRun(notification, status: "completed", failure: nil)
    let second = try await database.tasks.beginDelegation(
        taskID: nil, goal: "Second", input: "Second input", sourceDialog: nil, agent: "writer")
    await #expect(throws: (any Error).self) {
        try await database.tasks.completeDelegatedRun(
            TaskNotification(runID: second.runID, agent: "writer", eventID: event, data: notification.data),
            status: "completed", failure: nil)
    }
    // The failed notification insert must roll back the execution terminal update too.
    #expect(try await database.tasks.delegatedRun(second.runID, agent: "writer").status == "running")
    #expect(try await database.tasks.taskNotification(second.runID, agent: "writer") == nil)
    await #expect(throws: RecordStorageError.conflict) {
        try await database.tasks.completeDelegatedRun(
            TaskNotification(runID: first.runID, agent: "writer", eventID: event, data: Data("different".utf8)),
            status: "completed", failure: nil)
    }
    await #expect(throws: RecordStorageError.missingRecord) {
        try await database.tasks.delegatedRun(first.runID, agent: "assistant")
    }
    #expect(try await database.tasks.taskNotification(first.runID, agent: "assistant") == nil)
    #expect(
        try await database.tasks.pendingTaskNotifications(agent: "assistant", retirement: false, after: nil, limit: 32)
            .isEmpty)
    try await database.tasks.finishTaskNotification(
        first.runID, agent: "writer", retirement: true, completed: true, failure: nil)
    #expect(
        try await database.tasks.pendingTaskNotifications(agent: "writer", retirement: true, after: nil, limit: 32)
            .isEmpty)
    #expect(
        try await database.tasks.pendingTaskNotifications(agent: "writer", retirement: false, after: nil, limit: 32)
            .count == 1)
    try await database.shutdown()
    let reopened = try SQLiteRepositories(url: url)
    let restored = try #require(try await reopened.tasks.taskNotification(first.runID, agent: "writer"))
    #expect(restored.data == notification.data && restored.eventID == event)
    #expect(restored.retired && !restored.delivered)
    try await reopened.tasks.finishTaskNotification(
        first.runID, agent: "writer", retirement: false, completed: true, failure: nil)
    #expect(
        try await reopened.tasks.pendingTaskNotifications(agent: "writer", retirement: false, after: nil, limit: 32)
            .isEmpty)
    try await reopened.shutdown()
}

private struct WriterPermanentFixtureFailure: Error, ChatFailureProviding {
    let chatFailure = ChatFailureDiagnostic(.httpStatus, stage: .http, statusCode: 401)
}
private actor WriterBatchFailureModel: ChatCapability {
    nonisolated var availability: CapabilityAvailability { .available }
    nonisolated let supportsToolCalls = true
    var calls = 0
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        calls += 1
        if request.tools.isEmpty { throw WriterPermanentFixtureFailure() }
        let pair = InferenceSession<ChatEvent>.make(limits: try .init(), estimatedBytes: { $0.estimatedBytes })
        for (id, command) in [("edit", "edit"), ("later", "list")] {
            try pair.emitter.yield(
                .toolCall(.init(id: id, name: "workspace", argumentsJSON: "{\"command\":\"" + command + "\"}")))
        }
        try pair.emitter.yield(.finished(.toolCalls))
        pair.emitter.finish()
        return pair.session
    }
}
private actor WriterBatchEffectProbe {
    var calls: [String] = []
    var aborted = false
    func execute(_ call: ChatToolCall) -> WriterToolOutcome {
        calls.append(call.id)
        return .write(streamID: "stream", instruction: "File: index.html", context: "New file")
    }
    func abort() { aborted = true }
}

@Test func writerRecordsOriginalFailureAndUnexecutedSiblingAcrossSQLiteReopen() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let database = try SQLiteRepositories(url: url)
    let task = try await database.tasks.beginDelegation(
        taskID: nil, goal: "Pair recovery", input: "Demo", sourceDialog: nil, agent: "writer")
    let store = ConversationHistoryStore(
        records: try ConversationRecordStore(repository: database.chat, tasks: database.tasks, agent: "writer"))
    let model = WriterBatchFailureModel()
    let probe = WriterBatchEffectProbe()
    let definition = try ChatToolDefinition(
        declaration: Data(
            #"{"type":"function","function":{"name":"workspace","parameters":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}}"#
                .utf8))
    let tools = WriterTools(
        definitions: [definition], execute: { await probe.execute($0) }, append: { _, _ in },
        complete: { _ in "not committed" }, abort: { _ in await probe.abort() })
    await #expect(throws: WriterPermanentFixtureFailure.self) {
        try await WriterWorkflow(
            model: model, history: WriterHistory(store: store, taskID: task.id, runID: task.runID, goal: "Demo")
        )
        .run(goal: "Demo", scope: task.runID, tools: tools)
    }
    #expect(await model.calls == 2)
    #expect(await probe.calls == ["edit"])
    #expect(await probe.aborted)
    try await database.tasks.endTask(task.runID, status: "failed")
    try await database.shutdown()
    let reopened = try SQLiteRepositories(url: url)
    let restored = ConversationHistoryStore(
        records: try ConversationRecordStore(repository: reopened.chat, tasks: reopened.tasks, agent: "writer"))
    let control = try #require(
        try await restored.readCurrent().current.turns.flatMap { $0.modelRequests ?? [] }.first {
            $0.decisionMetadata?.mode == "控制请求"
        })
    #expect(control.toolCalls.count == 2)
    #expect(control.toolCalls.allSatisfy { $0.state == .failed })
    #expect(control.toolCalls.first?.failureDiagnostic?.details["httpStatus"] == "401")
    #expect(control.toolCalls.last?.failureDiagnostic?.details["executed"] == "false")
    try await reopened.shutdown()
}

private actor WriterPreviewProbe {
    var calls = 0
    var cancelled = false
    func slow() async throws -> String {
        calls += 1
        do { try await Task.sleep(for: .seconds(30)) } catch {
            cancelled = true
            throw error
        }
        return "{}"
    }
    func unavailable() -> String {
        calls += 1
        return #"{"status":"unavailable"}"#
    }
}
@Test func writerPreviewCoalescesWithoutBlockingAndJoinsCancellation() async throws {
    let probe = WriterPreviewProbe()
    let preview = WriterPreview(present: { try await probe.slow() }, observed: { _ in })
    await preview.changed()
    let deadline = ContinuousClock.now + .seconds(20)
    while await probe.calls == 0 {
        guard ContinuousClock.now < deadline else { throw WriterFailure.incomplete }
        try await Task.sleep(for: .milliseconds(10))
    }
    for _ in 0..<1000 { await preview.changed() }
    #expect(await probe.calls == 1)
    await preview.stop()
    #expect(await probe.cancelled)
    await preview.changed()
    #expect(await probe.calls == 1)
}
@Test func writerPreviewDoesNotRetryAMinimizedWindow() async throws {
    let probe = WriterPreviewProbe()
    let preview = WriterPreview(present: { await probe.unavailable() }, observed: { _ in })
    await preview.changed()
    let deadline = ContinuousClock.now + .seconds(20)
    while await probe.calls == 0 {
        guard ContinuousClock.now < deadline else { throw WriterFailure.incomplete }
        try await Task.sleep(for: .milliseconds(10))
    }
    for _ in 0..<100 { await preview.changed() }
    try await Task.sleep(for: .milliseconds(900))
    #expect(await probe.calls == 1)
    await preview.stop()
}

@Test @MainActor func writerRequestSummariesAreScopedPagedAndSurviveReopen() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let records = try SQLiteRepositories(url: url)
    let delegation = try await records.tasks.beginDelegation(
        taskID: nil, goal: "report", input: "report", sourceDialog: nil, agent: "writer")
    let store = ConversationHistoryStore(
        records: try ConversationRecordStore(repository: records.chat, tasks: records.tasks, agent: "writer"))
    let history = WriterHistory(store: store, taskID: delegation.id, runID: delegation.runID, goal: "report")
    let request = try ChatRequest(messages: [.init(role: .user, content: "generate")])
    for i in 1...25 {
        let id = try await history.begin(request, phase: "文件内容请求", attempt: i == 25 ? 2 : 1, path: "index.html")
        if i == 1 {
            let starting = try await store.requestPreviews(delegation.dialogID, after: 0)
            #expect(starting.first?.state == "generating")
            #expect(starting.first?.metadata["path"] == "index.html")
            #expect(starting.first?.response.isEmpty == true)
        }
        try await history.event(.text(String(repeating: "source", count: 2000)), id: id)
        try await history.event(.finished(.stop), id: id)
        try await history.finish(id)
    }
    #expect(try await store.requestCount(delegation.dialogID) == 25)
    let first = try await store.requestPreviews(delegation.dialogID, after: 0)
    #expect(first.count == 20 && first.first?.ordinal == 1 && first.last?.ordinal == 20)
    let second = try await store.requestPreviews(delegation.dialogID, after: #require(first.last?.position))
    #expect(second.count == 5 && second.last?.ordinal == 25)
    #expect(second.last?.metadata["path"] == "index.html")
    #expect(second.last?.metadata["attempt"] == "2")
    #expect(first.allSatisfy { $0.response.utf8.count < 12000 })
    try await records.shutdown()
    let reopened = try SQLiteRepositories(url: url)
    let journal = try ConversationRecordStore(repository: reopened.chat, tasks: reopened.tasks, agent: "writer")
    #expect(try await journal.requestCount(delegation.dialogID) == 25)
    let other = try ConversationRecordStore(repository: reopened.chat, tasks: reopened.tasks, agent: "assistant")
    await #expect(throws: (any Error).self) { try await other.requestPreviews(delegation.dialogID, after: 0) }
    try await reopened.shutdown()
}

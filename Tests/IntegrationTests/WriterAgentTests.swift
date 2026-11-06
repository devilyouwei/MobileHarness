import Actions
import AgentCore
import CallRuntime
import Foundation
import FunctionContracts
import Gateway
import ModelKit
import StorageChat
import StorageCore
import StorageDatabase
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
        #expect(request.timing != nil)
        request.timing?.start()
        if failsNetwork, requests >= 2 { throw WriterNetworkFixtureFailure() }
        let pair = InferenceSession<ChatEvent>.make(limits: try .init(), estimatedBytes: { $0.estimatedBytes })
        if request.tools.isEmpty {
            request.timing?.recordText("# Hello")
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
                request.timing?.recordText("done")
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
            request.timing?.recordToolArguments(String(decoding: try JSONEncoder().encode(command), as: UTF8.self))
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
@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
func writerBackgroundRoleUsesDirectGatewayAndPublishesActualArtifact(mode: Int)
    async throws
{
    let asks = [1, 2, 4].contains(mode)
    let cancels = mode == 2
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let records = try SQLiteRepositories.temporary()
    let workspace = ArtifactWorkspace(
        disk: try DiskFileStore(root: root), catalog: records.workspaces)
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
            return mode == 12 && !preview ? #"{"status":"deferred"}"# : "Rendered fixture"
        })
    let islandState = await IslandState()
    await islandState.setAvailable(true)
    let islandService = await IslandPresentationService(state: islandState)
    let model = WriterNativeFixture(
        asks: asks, failsNetwork: mode == 6, invalidArguments: mode == 8, exactPatch: mode == 9,
        slowContent: mode == 10 || mode == 12, naturalEnd: mode == 11
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
    let journal = ConversationHistoryStore(
        records: try ConversationRecordStore(repository: records.chat, tasks: records.tasks, agent: "writer"))
    let writer = try WriterAgent(
        model: {
            #expect(await startup.shown)
            let inventory = try await workspace.inventory()
            let project = try #require(inventory.first?["workspaceID"])
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
    let task = try await records.tasks.seedDelegation(
        taskID: nil, goal: "写一段问候", input: "写一段问候", sourceDialog: nil, agent: "writer")
    let scope = try AgentTaskScope(
        id: task.delegateID, requester: .assistant, executor: .writer, sessionID: session, execution: .background)
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
    var sceneHidden = false
    while !(await sink.signals.contains { $0.kind == .result }) {
        if mode == 12, !sceneHidden, await model.requests == 2 {
            await writer.setSceneActive(false)
            sceneHidden = true
        }
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
        let project = pending.workspaceID
        // Files/index are prepared before UI presentation; a failed window does not erase the workspace.
        #expect(pending.workspaceReady)
        let retry = try await records.tasks.seedDelegation(
            taskID: task.id, goal: "重试", input: "继续原任务", sourceDialog: nil, agent: "writer")
        let nextScope = try AgentTaskScope(
            id: retry.delegateID, requester: .assistant, executor: .writer, sessionID: session, execution: .background)
        let next = try AgentTaskSignal(
            kind: .request, scope: nextScope, businessContract: "writer.author",
            data: JSONEncoder().encode([
                "goal": "重试", "request": "继续原任务", "entry": "document.md", "taskID": task.id, "workspaceID": project,
            ]))
        let receipt = try await messaging.send(
            next.message(), parent: .init(id: UUID().uuidString, sessionID: session, payload: .text("重试")), to: .writer)
        #expect(receipt.rejected.isEmpty)
        let until = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await sink.signals.contains { $0.kind == .result && $0.scope.id == retry.delegateID }) {
            guard ContinuousClock.now < until else { throw WriterFailure.incomplete }
            try await Task.sleep(for: .milliseconds(10))
        }
        let completed = try await records.tasks.delegatedTask(task.id, agent: "writer")
        #expect(completed.workspaceID == project && completed.workspaceReady && completed.status == "completed")
        let roots = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("writer").path)
        #expect(roots == [task.id])
        #expect(project == "writer/" + task.id)
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
    if mode == 12 {
        #expect(sceneHidden)
        #expect(resultText.contains("未进行页面视觉验证"))
        #expect(await writer.status().lifecycle == .running)
        await writer.setSceneActive(true)
    }
    if mode == 7 { #expect(verifiedIndependent) }
    let saved = try await records.tasks.delegatedTask(task.id, agent: "writer")
    #expect(saved.status == "completed" && saved.workspaceID == "writer/" + saved.id)
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
    #expect(
        current.turns.flatMap { $0.modelRequests ?? [] }.allSatisfy {
            $0.modelRequestStartedAt != nil && $0.firstTokenLatency != nil && $0.modelRequestCompletedAt != nil
        })
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
        disk: try DiskFileStore(root: root), catalog: try await workspaceFixtureRepositories().workspaces)
    let service = ArtifactService(workspace: workspace, present: { _, _, _, _, _ in "Rendered fixture" })
    func invocation(_ task: String, _ parameters: [String: String]) throws -> FunctionInvocation {
        .init(
            call: .init(
                actionPath: ActionIdentifier(domain: "Artifacts", module: "Workspace", function: "perform"),
                parameters: parameters.merging(["workspaceID": "writer/task_1", "createWorkspace": "true"]) {
                    existing, _ in existing
                }),
            context: .init(source: "writer", sessionID: "session", inputID: task, taskID: task),
            executionID: UUID().uuidString, results: ActionReportStore())
    }
    let first = try await service.perform(
        invocation: invocation("one", ["command": "start", "workspaceID": "writer/task_1", "createWorkspace": "true"]))
    let project = try #require(JSONDecoder().decode([String: String].self, from: Data(first.utf8))["workspaceID"])
    await #expect(throws: ArtifactWorkspaceError.busy) {
        try await service.perform(invocation: invocation("two", ["command": "start", "workspaceID": project]))
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
        try await service.append(streamID: stream, delegateID: "two", text: "wrong owner")
    }
    try await service.append(streamID: stream, delegateID: "one", text: "<p>draft")
    try await service.release(delegateID: "one")
    await #expect(throws: ArtifactWorkspaceError.conflict) {
        try await service.append(streamID: stream, delegateID: "one", text: "late")
    }
    let workspaceID = try #require(WorkspaceID(rawValue: project))
    let checkpoint = try #require(await workspace.checkpoint(for: workspaceID))
    #expect(checkpoint.draft.files["index.html"] == "<p>draft")
    #expect(try await workspace.list().isEmpty)
    _ = try await service.perform(invocation: invocation("three", ["command": "start", "workspaceID": project]))
    try await service.release(delegateID: "two")
    try await service.release(delegateID: "three")
}

private actor WriterLifetimeLatch {
    private(set) var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private func writerLifetimeInvocation(_ parameters: [String: String], session: String = "session")
    -> FunctionInvocation
{
    .init(
        call: .init(
            actionPath: ActionIdentifier(domain: "Artifacts", module: "Workspace", function: "perform"),
            parameters: parameters.merging(["workspaceID": "writer/task_1", "createWorkspace": "true"]) {
                existing, _ in existing
            }),
        context: .init(source: "writer", sessionID: session, inputID: UUID().uuidString, taskID: "delegate"),
        executionID: UUID().uuidString, results: ActionReportStore())
}

@Test(.actionCatalog) func writerStreamingRevocationRejectsLateAndCrossSessionWork() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let records = try await workspaceFixtureRepositories()
    let workspace = ArtifactWorkspace(disk: try DiskFileStore(root: root), catalog: records.workspaces)
    let service = ArtifactService(workspace: workspace, present: { _, _, _, _, _ in "fixture" })
    _ = try await service.perform(invocation: writerLifetimeInvocation(["command": "start"]))
    await #expect(throws: ActionExecutionError.invalidInvocation) {
        try await service.perform(invocation: writerLifetimeInvocation(["command": "list"], session: "other"))
    }
    let response = try await service.perform(
        invocation: writerLifetimeInvocation(["command": "edit", "path": "index.html", "instruction": "Create"]))
    let stream = try #require(JSONDecoder().decode([String: String].self, from: Data(response.utf8))["streamID"])
    try await service.append(streamID: stream, delegateID: "delegate", text: "<p>preserved</p>")
    let cancelledCompletion = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await service.complete(streamID: stream, delegateID: "delegate")
    }
    await #expect(throws: CancellationError.self) { try await cancelledCompletion.value }
    await service.revoke(delegateID: "delegate")
    await #expect(throws: ArtifactWorkspaceError.conflict) {
        try await service.append(streamID: stream, delegateID: "delegate", text: "late")
    }
    await #expect(throws: ArtifactWorkspaceError.conflict) {
        try await service.complete(streamID: stream, delegateID: "delegate")
    }
    await #expect(throws: ArtifactWorkspaceError.conflict) {
        try await service.perform(invocation: writerLifetimeInvocation(["command": "finish"]))
    }
    // Cleanup remains legal after revocation and retains the partial draft.
    try await service.abort(streamID: stream, delegateID: "delegate")
    try await service.release(delegateID: "delegate")
    let id = try #require(WorkspaceID(rawValue: "writer/task_1"))
    #expect(try await workspace.checkpoint(for: id)?.draft.files["index.html"] == "<p>preserved</p>")
    _ = try await service.perform(invocation: writerLifetimeInvocation(["command": "resume"]))
    await #expect(throws: ArtifactWorkspaceError.conflict) {
        try await service.append(streamID: stream, delegateID: "delegate", text: "old generation")
    }
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await service.perform(invocation: writerLifetimeInvocation(["command": "rename", "title": "late"]))
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    try await service.shutdown()
    await #expect(throws: ArtifactWorkspaceError.closed) {
        try await service.perform(invocation: writerLifetimeInvocation(["command": "start"]))
    }
    try await records.shutdown()
}

@Test(.actionCatalog, arguments: [false, true])
@MainActor func writerStreamingCleanupJoinsEffectsAndDoesNotBlockSource(shutdown: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let records = try await workspaceFixtureRepositories()
    let workspace = ArtifactWorkspace(disk: try DiskFileStore(root: root), catalog: records.workspaces)
    let entered = WriterLifetimeLatch()
    let cancelled = WriterLifetimeLatch()
    let unblock = WriterLifetimeLatch()
    let finished = WriterLifetimeLatch()
    let service = ArtifactService(
        workspace: workspace,
        present: { _, _, _, files, _ in
            if files["index.html"] == "<p>first</p>" {
                await entered.open()
                // Deliberately noncooperative effect: cancellation must still join actual exit.
                await withTaskCancellationHandler {
                    await unblock.wait()
                } onCancel: {
                    Task { await cancelled.open() }
                }
            }
            return "fixture"
        })
    let actions = ActionsContainer()
    try actions.configure(
        BehaviorAssembly(capabilityModules: [ArtifactsModule(artifacts: service)]),
        cleanup: [{ try await service.shutdown() }])
    try actions.start()
    _ = try await service.perform(invocation: writerLifetimeInvocation(["command": "start"]))
    let response = try await service.perform(
        invocation: writerLifetimeInvocation(["command": "edit", "path": "index.html", "instruction": "Create"]))
    let stream = try #require(JSONDecoder().decode([String: String].self, from: Data(response.utf8))["streamID"])
    try await service.append(streamID: stream, delegateID: "delegate", text: "<p>first</p>")
    let preview = Task { try await service.perform(invocation: writerLifetimeInvocation(["command": "preview"])) }
    await entered.wait()
    // A slow renderer must not back up model content intake or overwrite its latest session.
    try await service.append(streamID: stream, delegateID: "delegate", text: "<p>second</p>")
    let cleanup = Task {
        if shutdown { try await actions.stop() } else { try await service.release(delegateID: "delegate") }
        await finished.open()
    }
    await cancelled.wait()
    #expect(await finished.opened == false)
    await #expect(throws: shutdown ? ArtifactWorkspaceError.closed : ArtifactWorkspaceError.conflict) {
        try await service.append(streamID: stream, delegateID: "delegate", text: "late")
    }
    let repeated = Task {
        if shutdown { try await actions.stop() } else { try await service.release(delegateID: "delegate") }
    }
    await unblock.open()
    await #expect(throws: CancellationError.self) { try await preview.value }
    try await cleanup.value
    try await repeated.value
    let id = try #require(WorkspaceID(rawValue: "writer/task_1"))
    #expect(try await workspace.checkpoint(for: id)?.draft.files["index.html"] == "<p>first</p><p>second</p>")
    if !shutdown {
        _ = try await service.perform(invocation: writerLifetimeInvocation(["command": "resume"]))
        try await service.release(delegateID: "delegate")
    }
    try await actions.stop()
    try await records.shutdown()
}

@Test(.actionCatalog) func writerShutdownJoinsPendingWorkspaceAdmission() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let records = try await workspaceFixtureRepositories()
    let workspace = ArtifactWorkspace(disk: try DiskFileStore(root: root), catalog: records.workspaces)
    let entered = WriterLifetimeLatch()
    let cancelled = WriterLifetimeLatch()
    let unblock = WriterLifetimeLatch()
    let finished = WriterLifetimeLatch()
    let service = ArtifactService(
        workspace: workspace,
        present: { _, _, _, _, _ in
            await entered.open()
            await withTaskCancellationHandler {
                await unblock.wait()
            } onCancel: {
                Task { await cancelled.open() }
            }
            return "fixture"
        })
    let start = Task { try await service.perform(invocation: writerLifetimeInvocation(["command": "start"])) }
    await entered.wait()
    await #expect(throws: ArtifactWorkspaceError.busy) {
        try await service.perform(invocation: writerLifetimeInvocation(["command": "edit", "path": "index.html"]))
    }
    let close = Task {
        try await service.shutdown()
        await finished.open()
    }
    await cancelled.wait()
    #expect(await finished.opened == false)
    await unblock.open()
    await #expect(throws: CancellationError.self) { try await start.value }
    try await close.value
    await #expect(throws: ArtifactWorkspaceError.closed) {
        try await service.perform(invocation: writerLifetimeInvocation(["command": "resume"]))
    }
    try await records.shutdown()
}

@Test(.actionCatalog) func writerCleanupFailureRemainsVisibleAndFencesAdmission() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let records = try await workspaceFixtureRepositories()
    let workspace = ArtifactWorkspace(disk: try DiskFileStore(root: root), catalog: records.workspaces)
    let service = ArtifactService(workspace: workspace, present: { _, _, _, _, _ in "fixture" })
    _ = try await service.perform(invocation: writerLifetimeInvocation(["command": "start"]))
    let response = try await service.perform(
        invocation: writerLifetimeInvocation(["command": "edit", "path": "index.html", "instruction": "Create"]))
    let stream = try #require(JSONDecoder().decode([String: String].self, from: Data(response.utf8))["streamID"])
    try await service.append(streamID: stream, delegateID: "delegate", text: "<p>draft</p>")
    // Explicit filesystem failure fixture: checkpoint cannot create files beneath a regular file.
    let directory = root.appendingPathComponent("writer/task_1")
    try FileManager.default.removeItem(at: directory)
    try Data("blocked".utf8).write(to: directory)
    await #expect(throws: NativeCleanupFailure.self) { try await service.release(delegateID: "delegate") }
    await #expect(throws: NativeCleanupFailure.self) { try await service.release(delegateID: "delegate") }
    await #expect(throws: ArtifactWorkspaceError.closed) {
        try await service.perform(invocation: writerLifetimeInvocation(["command": "resume"]))
    }
    await #expect(throws: NativeCleanupFailure.self) { try await service.shutdown() }
    await #expect(throws: NativeCleanupFailure.self) { try await service.shutdown() }
    try await records.shutdown()
}

@Test(.actionCatalog) func writerCancelledAdmissionCanResumeAfterRelease() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let records = try await workspaceFixtureRepositories()
    let workspace = ArtifactWorkspace(disk: try DiskFileStore(root: root), catalog: records.workspaces)
    let entered = WriterLifetimeLatch()
    let unblock = WriterLifetimeLatch()
    let service = ArtifactService(
        workspace: workspace,
        present: { _, _, _, _, _ in
            if await !entered.opened {
                await entered.open()
                await unblock.wait()
                try Task.checkCancellation()
            }
            return "fixture"
        })
    let start = Task { try await service.perform(invocation: writerLifetimeInvocation(["command": "start"])) }
    await entered.wait()
    await service.revoke(delegateID: "delegate")
    await unblock.open()
    await #expect(throws: CancellationError.self) { try await start.value }
    // start has already removed its session; release must still retire the revocation fence.
    try await service.release(delegateID: "delegate")
    _ = try await service.perform(invocation: writerLifetimeInvocation(["command": "resume"]))
    try await service.shutdown()
    try await records.shutdown()
}

private actor WriterCheckpointProbe: WorkspaceRepository {
    let base: any WorkspaceRepository
    let entered = WriterLifetimeLatch()
    let unblock = WriterLifetimeLatch()
    private var armed = false
    private(set) var wasCancelled = false
    init(base: any WorkspaceRepository) { self.base = base }
    func arm() { armed = true }
    func directory() async throws -> [WorkspaceSummary] { try await base.directory() }
    func workspace(_ id: WorkspaceID) async throws -> WorkspaceSummary? { try await base.workspace(id) }
    func claim(_ id: WorkspaceID, expecting: UUID?, lease: UUID) async throws {
        try await base.claim(id, expecting: expecting, lease: lease)
    }
    func commit(_ value: WorkspaceSummary, lease: UUID) async throws {
        if armed {
            armed = false
            await entered.open()
            await unblock.wait()
            wasCancelled = Task.isCancelled
        }
        try await base.commit(value, lease: lease)
    }
    func release(_ id: WorkspaceID, lease: UUID) async throws { try await base.release(id, lease: lease) }
    func markDeleting(_ id: WorkspaceID) async throws { try await base.markDeleting(id) }
    func finishDeleting(_ id: WorkspaceID) async throws { try await base.finishDeleting(id) }
}

@Test(.actionCatalog, arguments: [false, true])
func writerCheckpointRevocationDistinguishesCommitFromCleanup(aborting: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let records = try await workspaceFixtureRepositories()
    let probe = WriterCheckpointProbe(base: records.workspaces)
    let workspace = ArtifactWorkspace(disk: try DiskFileStore(root: root), catalog: probe)
    let service = ArtifactService(workspace: workspace, present: { _, _, _, _, _ in "fixture" })
    _ = try await service.perform(invocation: writerLifetimeInvocation(["command": "start"]))
    let response = try await service.perform(
        invocation: writerLifetimeInvocation(["command": "edit", "path": "index.html", "instruction": "Create"]))
    let stream = try #require(JSONDecoder().decode([String: String].self, from: Data(response.utf8))["streamID"])
    try await service.append(streamID: stream, delegateID: "delegate", text: "<p>checkpoint</p>")
    await probe.arm()
    let write = Task {
        if aborting {
            try await service.abort(streamID: stream, delegateID: "delegate")
        } else {
            _ = try await service.complete(streamID: stream, delegateID: "delegate")
        }
    }
    await probe.entered.wait()
    // A second mutation cannot enter while checkpoint persistence is suspended.
    await #expect(throws: ArtifactWorkspaceError.busy) {
        try await service.perform(invocation: writerLifetimeInvocation(["command": "rename", "title": "late"]))
    }
    await service.revoke(delegateID: "delegate")
    let release = Task { try await service.release(delegateID: "delegate") }
    await probe.unblock.open()
    if aborting {
        try await write.value
    } else {
        await #expect(throws: CancellationError.self) { try await write.value }
    }
    try await release.value
    #expect(await probe.wasCancelled == !aborting)
    let id = try #require(WorkspaceID(rawValue: "writer/task_1"))
    #expect(try await workspace.checkpoint(for: id)?.draft.files["index.html"] == "<p>checkpoint</p>")
    _ = try await service.perform(invocation: writerLifetimeInvocation(["command": "resume"]))
    await #expect(throws: ArtifactWorkspaceError.conflict) {
        try await service.complete(streamID: stream, delegateID: "delegate")
    }
    try await service.shutdown()
    try await records.shutdown()
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
        disk: try DiskFileStore(root: root), catalog: try await workspaceFixtureRepositories().workspaces)
    let probe = WriterRenderProbe()
    let service = ArtifactService(
        workspace: workspace, prepare: { _, _ in await probe.prepare() },
        present: { _, _, _, files, preview in await probe.present(files, preview) })
    func call(_ parameters: [String: String]) async throws -> String {
        try await service.perform(
            invocation: FunctionInvocation(
                call: .init(
                    actionPath: ActionIdentifier(domain: "Artifacts", module: "Workspace", function: "perform"),
                    parameters: parameters.merging(["workspaceID": "writer/task_1", "createWorkspace": "true"]) {
                        existing, _ in existing
                    }),
                context: .init(source: "writer", sessionID: "s", inputID: "t", taskID: "t"),
                executionID: UUID().uuidString, results: ActionReportStore()))
    }
    func strings(_ value: String) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: Data(value.utf8))
    }
    let started = try strings(await call(["command": "start"]))
    let workspaceID = try #require(started["workspaceID"])
    #expect(await probe.prepared == 1)
    let first = try strings(
        await call(["command": "edit", "path": "index.html", "instruction": "Create", "title": "Simple flowchart"]))
    let stream = try #require(first["streamID"])
    try await Task.sleep(for: .milliseconds(210))
    try await service.append(streamID: stream, delegateID: "t", text: "<h1 class=diagram>Hello</h1>")
    _ = try await service.complete(streamID: stream, delegateID: "t")
    #expect(await probe.frames.count == 1)  // Only the startup placeholder, no edit-driven render.
    let namingProject = try #require(WorkspaceID(rawValue: workspaceID))
    #expect(try await workspace.checkpoint(for: namingProject)?.title == "Simple flowchart")
    _ = try await call(["command": "rename", "title": "Project flowchart"])
    #expect(try await workspace.checkpoint(for: namingProject)?.title == "Project flowchart")

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
    try await service.append(streamID: live, delegateID: "t", text: css)
    _ = try await service.complete(streamID: live, delegateID: "t")
    _ = try await call(["command": "preview"])
    #expect(await probe.frames.last?.0["styles/a.css"] == css)
    #expect(await probe.frames.last?.1 == true)
    // Opt-in belongs to one edit, not the next one or another project.
    let count = await probe.frames.count
    let next = try strings(await call(["command": "edit", "path": "note.txt", "instruction": "Write"]))
    let nextID = try #require(next["streamID"])
    try await service.append(streamID: nextID, delegateID: "t", text: "note")
    _ = try await service.complete(streamID: nextID, delegateID: "t")
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
    #expect(try await workspace.project(namingProject).title == "Project flowchart")

    await probe.fail()
    _ = try await call(["command": "render"])
    await #expect(throws: ArtifactWorkspaceError.renderRequired) { try await call(["command": "finish"]) }
    try await service.release(delegateID: "t")
    _ = try await call(["command": "resume", "workspaceID": workspaceID])
    #expect(try await workspace.checkpoint(for: namingProject)?.title == "Project flowchart")

    #expect(await probe.prepared == 1)
    try await service.release(delegateID: "t")
    _ = try await call(["command": "start", "workspaceID": workspaceID])
    #expect(await probe.prepared == 2)
    try await service.release(delegateID: "t")
}

@Test func writerHistoryPersistsExactRequestsAndSeparatesAssistantInSQLite() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let database = try SQLiteRepositories(url: url)
    let assistant = try await database.chat.current(agent: "assistant")
    let store = ConversationHistoryStore(
        records: try ConversationRecordStore(repository: database.chat, tasks: database.tasks, agent: "writer"))
    let task = try await database.tasks.seedDelegation(
        taskID: nil, goal: "绘图", input: "画一张图", sourceDialog: assistant.id, agent: "writer")
    let history = WriterHistory(
        store: store, taskID: task.id, delegateID: task.delegateID, goal: "画一张图 · project abc")
    let request = try ChatRequest(
        messages: [.init(role: .system, content: "Writer policy"), .init(role: .user, content: "<h1>中文 🌍</h1>")],
        maximumOutputTokens: 2048, temperature: 0.2)
    let id = try await history.begin(request, phase: "内容")
    let timing = ChatTiming()
    timing.start()
    timing.recordText("<h1>完成</h1>")
    try await history.timing(try #require(timing.snapshot), id: id)
    try await history.event(.text("<h1>完成</h1>"), id: id)
    let largeArguments = String(
        decoding: try JSONEncoder().encode([
            "command": "read", "path": "index.html", "query": String(repeating: "source", count: 100000),
        ]), as: UTF8.self)
    try await history.event(
        .toolCall(.init(id: "call", name: "workspace", argumentsJSON: largeArguments)),
        id: id)
    try await history.event(.usage(try .init(input: 5, generated: 7, total: 12)), id: id)
    try await history.event(.finished(.stop), id: id)
    try await history.finish(id)
    try await history.toolOutcome("call", output: "Saved artifact abc")
    let nextRequest = try ChatRequest(messages: [
        .init(
            role: .assistant, content: "",
            toolCalls: [
                .init(id: "call", name: "workspace", argumentsJSON: largeArguments)
            ]),
        .init(role: .tool, content: "Saved artifact abc", toolCallID: "call"),
    ])
    let largeSnapshot = try await history.begin(nextRequest, phase: "control")
    try await history.finish(largeSnapshot)

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
    try await database.tasks.endSeedDelegation(task.delegateID, status: "failed", failure: "fixture")
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
    let snapshotJSON = try #require(value.turns.first { $0.id == largeSnapshot }?.modelRequests?.first?.requestJSON)
    let snapshotMessages = try #require(JSONSerialization.jsonObject(with: Data(snapshotJSON.utf8)) as? [[String: Any]])
    let snapshotCalls = try #require(snapshotMessages.first?["toolCalls"] as? [[String: String]])
    #expect(snapshotCalls.first?["argumentsJSON"] == largeArguments)
    #expect(modelRequest.toolCalls.first?.argumentsJSON == largeArguments)
    #expect(modelRequest.toolCalls.first?.output == "Saved artifact abc")
    #expect(modelRequest.toolCalls.first?.state == .completed)
    #expect(modelRequest.tokenUsage?.total == 12)
    #expect(modelRequest.finishReason == "stop")
    #expect(modelRequest.modelRequestStartedAt == timing.snapshot?.startedAt)
    #expect(modelRequest.firstTokenLatency == timing.snapshot?.firstTokenLatency)
    #expect(modelRequest.modelRequestCompletedAt != nil)
    let restoredRun = try await reopened.tasks.delegation(task.delegateID, agent: "writer")
    #expect(restoredRun.finishedAt != nil)
    #expect(
        try await reopened.tasks.delegations(task.id, agent: "writer").first?.finishedAt == restoredRun.finishedAt)

    let controller = await WriterContainer()
    try await controller.configureHistory(chat: reopened.chat, tasks: reopened.tasks)
    let requestPage = try await controller.requests(taskID: task.id, after: 0)
    #expect(requestPage.items.first?.title == "读取 index.html")
    #expect(requestPage.items.first?.statusTitle == "已完成")
    let completedTask = try await controller.task(task.id)
    let closedDuration = try #require(restoredRun.finishedAt).timeIntervalSince(restoredRun.createdAt)
    #expect(completedTask.elapsed(at: Date.distantFuture) == closedDuration)
    let continuation = try await reopened.tasks.seedDelegation(
        taskID: task.id, goal: "revise", input: "revise", sourceDialog: nil, agent: "writer")
    let activeRun = try await reopened.tasks.delegation(continuation.delegateID, agent: "writer")
    let activeTask = try await controller.task(task.id)
    #expect(activeTask.completedDuration == closedDuration && activeTask.activeSince == activeRun.createdAt)
    #expect(activeTask.elapsed(at: activeRun.createdAt.addingTimeInterval(3)) == closedDuration + 3)
    try await reopened.tasks.endSeedDelegation(continuation.delegateID, status: "completed", failure: nil)

    #expect(value.turns.first { $0.id == cancelled }?.state == .cancelled)
    let failure = try #require(value.turns.first { $0.id == failed }?.modelRequests?.last?.failureDiagnostic)
    #expect(failure == diagnostic.storageValue && failure.details["networkCode"] == "-1001")
    let resumedContext = try await WriterHistory(
        store: restored, taskID: task.id, delegateID: continuation.delegateID, goal: "Continue"
    ).restoredContext()
    #expect(
        resumedContext.contains {
            $0.role == .user && $0.content.contains("Previous execution failure")
                && $0.content.contains(diagnostic.code) && $0.content.contains("-1001")
        })

    let projection = try JSONDecoder().decode(HistoryConversation.self, from: JSONEncoder().encode(value))
    let timed = try #require(projection.turns.first { $0.id == id }?.modelRequests?.first)
    #expect(timed.modelRequestCompletedAt == modelRequest.modelRequestCompletedAt)
    #expect(!WriterRecordPresentation.firstToken(timed).contains("未知"))
    #expect(!WriterRecordPresentation.requestDuration(timed, at: Date()).contains("未知"))

    let projected = try #require(projection.turns.first { $0.id == failed }?.modelRequests?.last?.failureDiagnostic)
    #expect(projected.category == failure.category && projected.details == failure.details)
    try await reopened.shutdown()
}

@Test func writerHistoryStoresImageReferencesWithWriterInputOwnership() async throws {
    let records = try SQLiteRepositories.temporary()
    let files = try MemoryFileStore()
    let photos = MediaStore(repository: records.media, files: files)
    let store = ConversationHistoryStore(
        records: try ConversationRecordStore(repository: records.chat, tasks: records.tasks, agent: "writer"))
    let task = try await records.tasks.seedDelegation(
        taskID: nil, goal: "Inspect", input: "Render", sourceDialog: nil, agent: "writer")
    let history = WriterHistory(
        store: store, taskID: task.id, delegateID: task.delegateID, goal: "Inspect", photos: photos)
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
    let first = try await database.tasks.seedDelegation(
        taskID: nil, goal: "画流程图", input: "用户原始请求", sourceDialog: source.id, agent: "writer")
    let project = "writer/" + first.id
    try await database.tasks.prepareWorkspace(project, taskID: first.id, delegateID: first.delegateID, agent: "writer")
    let journal = ConversationHistoryStore(
        records: try ConversationRecordStore(repository: database.chat, tasks: database.tasks, agent: "writer"))
    let history = WriterHistory(
        store: journal, taskID: first.id, delegateID: first.delegateID, goal: "画流程图", modelName: "fixture-model")
    let request = try ChatRequest(
        messages: [.init(role: .system, content: "policy"), .init(role: .user, content: "画流程图")],
        maximumOutputTokens: 2048, temperature: 0.2)
    let input = try await history.begin(request, phase: "控制请求")
    try await history.event(.text("先读文件"), id: input)
    try await history.event(
        .toolCall(.init(id: "read-1", name: "workspace", argumentsJSON: "{\"command\":\"read\"}")), id: input)
    try await history.finish(input)
    try await history.toolOutcome("read-1", output: "node A")
    try await database.tasks.endSeedDelegation(first.delegateID, status: "completed")
    let second = try await database.tasks.seedDelegation(
        taskID: first.id, goal: "改为蓝色", input: "继续改成蓝色", sourceDialog: source.id, agent: "writer")
    #expect(second.id == first.id && second.delegateID != first.delegateID)
    #expect(second.dialogID == first.dialogID && second.workspaceID == project && second.goal == "画流程图")
    let restored = try await WriterHistory(
        store: journal, taskID: first.id, delegateID: second.delegateID, goal: "改为蓝色"
    )
    .restoredContext()
    #expect(restored.contains { $0.role == .assistant && $0.toolCalls.first?.id == "read-1" })
    #expect(restored.contains { $0.role == .tool && $0.toolCallID == "read-1" && $0.content == "node A" })
    await #expect(throws: (any Error).self) {
        try await database.tasks.prepareWorkspace(
            UUID().uuidString, taskID: first.id, delegateID: first.delegateID, agent: "writer")
    }
    try await database.tasks.requestCancellation(delegateID: second.delegateID, reason: "Assistant forced replacement")
    try await database.tasks.endSeedDelegation(second.delegateID, status: "cancelled")
    let third = try await database.tasks.seedDelegation(
        taskID: nil, goal: "新作品", input: "另画一张", sourceDialog: source.id, agent: "writer")
    #expect(
        third.id != first.id && third.dialogID != first.dialogID && !third.workspaceReady
            && third.workspaceID == "writer/" + third.id)
    #expect(try await journal.readCurrent().current.id == third.dialogID)
    try await database.tasks.endSeedDelegation(third.delegateID, status: "failed", failure: "fixture failure")
    let resumedAgain = try await database.tasks.seedDelegation(
        taskID: first.id, goal: "再次修改", input: "修改旧任务", sourceDialog: source.id, agent: "writer")
    #expect(resumedAgain.workspaceID == project && resumedAgain.dialogID == first.dialogID)
    let earlierContext = try await WriterHistory(
        store: journal, taskID: first.id, delegateID: resumedAgain.delegateID, goal: "再次修改"
    ).restoredContext()
    #expect(earlierContext.contains { $0.role == .tool && $0.toolCallID == "read-1" })
    try await database.tasks.endSeedDelegation(resumedAgain.delegateID, status: "completed")
    // Writer histories have no cascading ownership by the requesting Assistant dialog.
    _ = try await database.chat.rotate(source.id, agent: "assistant")
    try await database.chat.deleteDialog(source.id)
    #expect(try await database.tasks.delegatedTask(first.id, agent: "writer").workspaceID == project)
    #expect(try await database.tasks.delegatedTasks(agent: "assistant", before: nil, limit: 20).isEmpty)
    try await database.shutdown()
    let reopened = try SQLiteRepositories(url: url)
    #expect(try await reopened.tasks.delegatedTask(first.id, agent: "writer").delegateID == resumedAgain.delegateID)
    let runs = try await reopened.tasks.delegations(first.id, agent: "writer")
    #expect(runs.count == 3 && runs[1].status == "cancelled" && runs.last?.status == "completed")
    #expect(runs[1].cancellationReason == "Assistant forced replacement")
    let records = ConversationHistoryStore(
        records: try ConversationRecordStore(repository: reopened.chat, tasks: reopened.tasks, agent: "writer"))
    let full = try await records.conversation(first.dialogID)
    #expect(full.turns.first?.model == "fixture-model")
    #expect(full.turns.first?.modelRequests?.first?.decisionMetadata?.delegateID == first.delegateID)
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
    let run = try await tasks.delegation(scope.id, agent: "writer")
    let event = try #require(content.writerEvent)
    let canonical = try AgentTaskContent(
        text: content.text, stage: .completed,
        interactionID: content.interactionID, artifactID: content.artifactID,
        writerEvent: .init(
            sequence: event.sequence, kind: event.kind, workspaceID: event.workspaceID,
            windowID: event.windowID, taskID: run.taskID, delegateID: run.delegateID, failure: event.failure,
            eventID: event.eventID))
    let report = try WriterTaskCompletion(canonical.signal(.result, scope: scope, status: status))
    try await tasks.completeDelegation(
        .init(
            delegateID: run.delegateID, agent: "writer", eventID: event.eventID,
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
        catalog: records.workspaces)
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
        let record = try await records.tasks.seedDelegation(
            taskID: nil, goal: "Goal \(index)", input: "Write greeting", sourceDialog: nil, agent: "writer")
        let scope = AgentTaskScope(
            id: record.delegateID, requester: .assistant, executor: .writer, sessionID: session, execution: .background)
        let request = try AgentTaskSignal(
            kind: .request, scope: scope, businessContract: "writer.author",
            data: JSONEncoder().encode([
                "goal": record.goal, "taskID": record.id, "request": "Write greeting", "entry": "document.md",
            ]))
        let receipt = try await port.send(
            request.message(), parent: .init(id: UUID().uuidString, sessionID: session, payload: .text("Write")),
            to: .writer)
        #expect(receipt.rejected.isEmpty)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while true {
            let run = try await records.tasks.delegation(record.delegateID, agent: "writer")
            let retired = try await records.tasks.taskNotification(record.delegateID, agent: "writer")?.retired == true
            if run.status == "completed", retired { break }
            guard ContinuousClock.now < deadline else { throw WriterFailure.incomplete }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await writer.observationSnapshot().business["phase"] == .text("idle"))
        let notification = try #require(try await records.tasks.taskNotification(record.delegateID, agent: "writer"))
        #expect(!notification.delivered)
        eventIDs.insert(notification.eventID)
        runs.append(record.delegateID)
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
        #expect(try await reopened.tasks.delegation(run, agent: "writer").status == "completed")
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
    let first = try await database.tasks.seedDelegation(
        taskID: nil, goal: "First", input: "First input", sourceDialog: nil, agent: "writer")
    let event = UUID().uuidString
    let notification = TaskNotification(
        delegateID: first.delegateID, agent: "writer", eventID: event, data: Data("immutable fact".utf8))
    try await database.tasks.completeDelegation(notification, status: "completed", failure: nil)
    try await database.tasks.completeDelegation(notification, status: "completed", failure: nil)
    let second = try await database.tasks.seedDelegation(
        taskID: nil, goal: "Second", input: "Second input", sourceDialog: nil, agent: "writer")
    await #expect(throws: (any Error).self) {
        try await database.tasks.completeDelegation(
            TaskNotification(delegateID: second.delegateID, agent: "writer", eventID: event, data: notification.data),
            status: "completed", failure: nil)
    }
    // The failed notification insert must roll back the execution terminal update too.
    #expect(try await database.tasks.delegation(second.delegateID, agent: "writer").status == "running")
    #expect(try await database.tasks.taskNotification(second.delegateID, agent: "writer") == nil)
    await #expect(throws: RecordStorageError.conflict) {
        try await database.tasks.completeDelegation(
            TaskNotification(
                delegateID: first.delegateID, agent: "writer", eventID: event, data: Data("different".utf8)),
            status: "completed", failure: nil)
    }
    await #expect(throws: RecordStorageError.missingRecord) {
        try await database.tasks.delegation(first.delegateID, agent: "assistant")
    }
    #expect(try await database.tasks.taskNotification(first.delegateID, agent: "assistant") == nil)
    #expect(
        try await database.tasks.pendingTaskNotifications(agent: "assistant", retirement: false, after: nil, limit: 32)
            .isEmpty)
    try await database.tasks.finishTaskNotification(
        first.delegateID, agent: "writer", retirement: true, completed: true, failure: nil)
    #expect(
        try await database.tasks.pendingTaskNotifications(agent: "writer", retirement: true, after: nil, limit: 32)
            .isEmpty)
    #expect(
        try await database.tasks.pendingTaskNotifications(agent: "writer", retirement: false, after: nil, limit: 32)
            .count == 1)
    try await database.shutdown()
    let reopened = try SQLiteRepositories(url: url)
    let restored = try #require(try await reopened.tasks.taskNotification(first.delegateID, agent: "writer"))
    #expect(restored.data == notification.data && restored.eventID == event)
    #expect(restored.retired && !restored.delivered)
    try await reopened.tasks.finishTaskNotification(
        first.delegateID, agent: "writer", retirement: false, completed: true, failure: nil)
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
    let task = try await database.tasks.seedDelegation(
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
            model: model,
            history: WriterHistory(store: store, taskID: task.id, delegateID: task.delegateID, goal: "Demo")
        )
        .run(goal: "Demo", scope: task.delegateID, tools: tools)
    }
    #expect(await model.calls == 2)
    #expect(await probe.calls == ["edit"])
    #expect(await probe.aborted)
    try await database.tasks.endSeedDelegation(task.delegateID, status: "failed")
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
    let delegation = try await records.tasks.seedDelegation(
        taskID: nil, goal: "report", input: "report", sourceDialog: nil, agent: "writer")
    let store = ConversationHistoryStore(
        records: try ConversationRecordStore(repository: records.chat, tasks: records.tasks, agent: "writer"))
    let history = WriterHistory(store: store, taskID: delegation.id, delegateID: delegation.delegateID, goal: "report")
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

#if os(macOS)
    import AppKit
    import WebKit

    extension LiveRuntimeTests {
        @Test @MainActor func artifactPreviewRotatesFilesWithoutReplacingItsNativeSurface() async throws {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .resolvingSymlinksInPath()
            let pages = WebPageContainer()
            pages.setAvailable(true)
            let windows = WindowState()
            windows.layout(width: 390, height: 750)
            windows.setAvailable(true)
            let presentation = ArtifactPresentation(pages: pages, windows: windows, disk: try DiskFileStore(root: root))
            defer {
                pages.closeSessions()
                try? FileManager.default.removeItem(at: root)
            }
            let project = try #require(WorkspaceID(agent: "writer", taskID: "task_1"))
            let first = Task { @MainActor in
                try await presentation.present(
                    id: project, title: "Preview", entry: "pages/index.html",
                    files: ["pages/index.html": "<title>Initial</title><h1 id=heading>Initial</h1>"], preview: true)
            }
            let deadline = ContinuousClock.now + .seconds(3)
            while windows.windows.isEmpty {
                guard ContinuousClock.now < deadline else { throw WebPageError.unavailable }
                await Task.yield()
            }
            let window = try #require(windows.windows.first)
            windows.complete(window.id, revision: window.revision, generation: windows.generation, success: true)
            _ = try await first.value
            let page = try #require(pages.sessions[window.id])
            let native = page.webView
            _ = try await native.evaluateJavaScript("window.initialDocument=document;'ready'")
            for revision in 2...5 {
                _ = try await presentation.present(
                    id: project, title: "Preview", entry: "pages/index.html",
                    files: [
                        "pages/index.html":
                            "<title>Version \(revision)</title><link rel=stylesheet href=../style.css><h1 id=heading>Version \(revision)</h1>",
                        "style.css": "body{color:rgb(20,30,40)}",
                    ], preview: true)
                #expect(page.webView === native)
                #expect(try await native.evaluateJavaScript("window.initialDocument===document") as? Bool == true)
                #expect(try await page.observe().title == "Version \(revision)")
            }
            // Reload resolves the latest entry, even after the first slot was recycled and deleted.
            _ = try await presentation.present(
                id: project, title: "Preview", entry: "pages/index.html",
                files: ["pages/index.html": "<title>Published</title><h1>Published</h1>"], preview: false)
            #expect(try await page.navigate("reload").title == "Published")
            #expect(page.webView === native)
            presentation.describe(id: project, title: "Diagram", subtitle: "Initial goal")
            windows.setAvailable(false)
            pages.setAvailable(false)
            try await presentation.setSceneActive(false)
            let hidden = try await presentation.present(
                id: project, title: "Diagram", entry: "pages/index.html",
                files: ["pages/index.html": "<title>Background</title><h1>Latest background source</h1>"],
                preview: false)
            #expect(hidden.contains("deferred"))
            #expect(native.title == "Published")
            #expect(try await presentation.snapshot(id: project) == nil)
            let second = try #require(WorkspaceID(agent: "writer", taskID: "task_2"))
            _ = try await presentation.present(
                id: second, title: "Diagram", entry: "index.html",
                files: ["index.html": "<title>Second background project</title><h1>Second</h1>"], preview: true)
            #expect(windows.windows.count == 1)
            presentation.describe(id: project, title: nil, subtitle: "Saved in background")
            windows.setAvailable(true)
            pages.setAvailable(true)
            let restoring = Task { @MainActor in try await presentation.setSceneActive(true) }
            let restoreDeadline = ContinuousClock.now + .seconds(5)
            while windows.windows.count < 2 {
                guard ContinuousClock.now < restoreDeadline else { throw WebPageError.timedOut }
                await Task.yield()
            }
            for item in windows.windows where item.phase == .opening {
                windows.complete(item.id, revision: item.revision, generation: windows.generation, success: true)
            }
            try await restoring.value
            #expect(try await page.observe().title == "Background")
            #expect(page.webView === native)
            #expect(Set(windows.windows.map(\.title)) == ["Diagram · 1", "Diagram · 2"])
            #expect(try windows.find(window.id).subtitle == "Saved in background")
            let minimizing = Task { @MainActor in try await windows.change(window.id, command: .minimize) }
            let minimizeDeadline = ContinuousClock.now + .seconds(5)
            while try windows.find(window.id).mode != .minimized {
                guard ContinuousClock.now < minimizeDeadline else { throw WebPageError.timedOut }
                await Task.yield()
            }
            let minimized = try windows.find(window.id)
            windows.complete(minimized.id, revision: minimized.revision, generation: windows.generation, success: true)
            try await minimizing.value
            try await presentation.setSceneActive(false)
            try await presentation.prepare(id: project, deleting: false)
            _ = try await presentation.present(
                id: project, title: "Diagram", entry: "pages/index.html",
                files: ["pages/index.html": "<title>Hidden minimized update</title>"], preview: true)
            try await presentation.setSceneActive(true)
            #expect(try windows.find(window.id).mode == .minimized)
            #expect(native.title == "Background")

            let previewRoot = root.appendingPathComponent("previews/" + project.rawValue)
            let slots = try FileManager.default.contentsOfDirectory(at: previewRoot, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent != "preview.html" }
            #expect(slots.count == 2)
            for slot in slots {
                #expect(
                    try FileManager.default.contentsOfDirectory(at: slot, includingPropertiesForKeys: nil).count == 1)
            }
        }
    }
#endif

@Test func writerPreviewSuspendsOnlyRenderingAndResumesLatestIntent() async throws {
    let probe = WriterPreviewProbe()
    let preview = WriterPreview(present: { try await probe.slow() }, observed: { _ in })
    await preview.setSceneActive(false)
    for _ in 0..<100 { await preview.changed() }
    #expect(await probe.calls == 0)
    await preview.setSceneActive(true)
    var deadline = ContinuousClock.now + .seconds(20)
    while await probe.calls < 1 {
        guard ContinuousClock.now < deadline else { throw WriterFailure.incomplete }
        try await Task.sleep(for: .milliseconds(10))
    }
    await preview.setSceneActive(false)
    #expect(await probe.cancelled)
    for _ in 0..<100 { await preview.changed() }
    #expect(await probe.calls == 1)
    await preview.setSceneActive(true)
    deadline = ContinuousClock.now + .seconds(20)
    while await probe.calls < 2 {
        guard ContinuousClock.now < deadline else { throw WriterFailure.incomplete }
        try await Task.sleep(for: .milliseconds(10))
    }
    await preview.stop()
}
@Test func writerInitialNamesDescribeTheGoalWithoutAnotherModelCall() {
    #expect(WriterAgent.initialTitle(goal: "请帮我画一张软件工程流程图") == "软件工程流程图")
    #expect(WriterAgent.initialTitle(goal: "再绘制一份项目文档") == "项目文档")
    #expect(WriterAgent.initialTitle(goal: String(repeating: "👨‍👩‍👧‍👦", count: 50)).utf8.count <= 160)
}

#if os(macOS)
    extension LiveRuntimeTests {
        @Test @MainActor func artifactWindowAwaitingFirstPresentationSurvivesSceneLoss() async throws {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .resolvingSymlinksInPath()
            let pages = WebPageContainer()
            let windows = WindowState()
            windows.layout(width: 390, height: 750)
            windows.setAvailable(true)
            pages.setAvailable(true)
            let presentation = ArtifactPresentation(pages: pages, windows: windows, disk: try DiskFileStore(root: root))
            defer {
                pages.closeSessions()
                try? FileManager.default.removeItem(at: root)
            }
            let project = try #require(WorkspaceID(agent: "writer", taskID: "task_1"))
            let opening = Task { @MainActor in
                try await presentation.present(
                    id: project, title: "Flowchart", entry: "index.html",
                    files: ["index.html": "<title>Retained after scene loss</title><h1>Draft</h1>"], preview: true)
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while windows.windows.isEmpty {
                guard ContinuousClock.now < deadline else { throw WebPageError.timedOut }
                await Task.yield()
            }
            let reserved = try #require(windows.windows.first?.id)
            windows.setAvailable(false)
            pages.setAvailable(false)
            try await presentation.setSceneActive(false)
            #expect(try await opening.value.contains("deferred"))
            windows.setAvailable(true)
            pages.setAvailable(true)
            try await presentation.setSceneActive(true)
            #expect(windows.windows.count == 1 && windows.windows.first?.id == reserved)
            #expect(try await pages.sessions[reserved]?.observe().title == "Retained after scene loss")
        }
    }
#endif

@Test func writerRequestNamesUseActualCallsAndKeepStatusSeparateFromModelCompletion() throws {
    func call(_ values: [String: String], state: String = "completed") throws -> MessageToolPreview {
        .init(
            name: "workspace", argumentsJSON: String(decoding: try JSONEncoder().encode(values), as: UTF8.self),
            state: state)
    }
    let read = try call(["command": "read", "path": "index.html"])
    let edit = try call(["command": "edit", "path": "index.html", "instruction": "修改流程图布局"])
    let combined = WriterRequestNaming.summary(phase: "控制请求", path: nil, calls: [read, read, edit])
    #expect(combined == "读取 index.html、修改流程图布局")
    let content = WriterRequestNaming.summary(phase: "文件内容请求", path: "styles/main.css", calls: [])
    #expect(content == "编写 styles/main.css")
    let source = try call(["command": "edit", "path": "index.html", "instruction": "<html>code</html>"])
    #expect(WriterRequestNaming.summary(phase: "控制请求", path: nil, calls: [source]) == "编写 index.html")
    #expect(
        WriterRequestNaming.state(request: "completed", calls: [try call(["command": "read"], state: "failed")])
            == "failed")
    #expect(
        WriterRequestNaming.state(request: "completed", calls: [try call(["command": "read"], state: "received")])
            == "executing")
    #expect(WriterRequestNaming.state(request: "cancelled", calls: [read]) == "cancelled")
    #expect(WriterRequestNaming.state(request: "cancelled", calls: [], pending: true) == "cancelled")

}

@Test func writerLargeSourceAndToolResultPersistWithoutPerItemCeilings() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let database = try SQLiteRepositories(url: url)
    let store = ConversationHistoryStore(
        records: try ConversationRecordStore(
            repository: database.chat, tasks: database.tasks, agent: "writer"))
    let task = try await database.tasks.seedDelegation(
        taskID: nil, goal: "Large", input: "Large", sourceDialog: nil, agent: "writer")
    let history = WriterHistory(store: store, taskID: task.id, delegateID: task.delegateID, goal: "Large")
    let request = try ChatRequest(messages: [.init(role: .user, content: "Create")])
    let input = try await history.begin(request, phase: "control")
    let source = String(repeating: "<p>source</p>", count: 30000)
    let result = String(repeating: "file result ", count: 30000)
    try await history.event(.toolCall(.init(id: "read", name: "workspace", argumentsJSON: "{}")), id: input)
    try await history.event(.text(source), id: input)
    try await history.finish(input)
    try await history.toolOutcome("read", output: result)
    try await history.hostFinalization(input, result: result, error: nil)
    try await database.shutdown()
    let reopened = try SQLiteRepositories(url: url)
    let restored = ConversationHistoryStore(
        records: try ConversationRecordStore(
            repository: reopened.chat, tasks: reopened.tasks, agent: "writer"))
    let record = try #require(try await restored.conversation(task.dialogID).turns.first)
    #expect(record.response == source)
    #expect(record.modelRequests?.first?.toolCalls.first?.output == result)
    try await reopened.shutdown()
}

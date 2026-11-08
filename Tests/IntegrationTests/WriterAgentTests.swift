import AgentCore
import CallRuntime
import Foundation
import FunctionContracts
import GRDB
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

@testable import Actions
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
    let libraryOnly: Bool
    let editInstruction: String
    let observe: @Sendable (Int) async throws -> Void
    init(
        asks: Bool, failsNetwork: Bool = false, invalidArguments: Bool = false, exactPatch: Bool = false,
        slowContent: Bool = false, naturalEnd: Bool = false, libraryOnly: Bool = false,
        editInstruction: String = "Write greeting",
        observe: @escaping @Sendable (Int) async throws -> Void = { _ in }
    ) {
        self.asks = asks
        self.failsNetwork = failsNetwork
        self.invalidArguments = invalidArguments
        self.exactPatch = exactPatch
        self.slowContent = slowContent
        self.naturalEnd = naturalEnd
        self.libraryOnly = libraryOnly
        self.editInstruction = editInstruction
        self.observe = observe
    }
    var requests = 0
    private var existing = false
    func restart() {
        requests = 0
        existing = true
    }
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        requests += 1
        try await observe(requests)
        #expect(request.timing != nil)
        request.timing?.start()
        if failsNetwork, requests >= 2 { throw WriterNetworkFixtureFailure() }
        let pair = InferenceSession<ChatEvent>.make(limits: try .init(), estimatedBytes: { $0.estimatedBytes })
        if request.tools.isEmpty {
            #expect(request.messages.last?.content.contains(editInstruction) == true)
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
            if naturalEnd, requests == 6 {
                request.timing?.recordText("done")
                try pair.emitter.yield(.text("作品已经完成。"))
                try pair.emitter.yield(.finished(.stop))
                pair.emitter.finish()
                return pair.session
            }
            let policy = request.messages.first(where: { $0.role == .system })?.content ?? ""
            #expect(policy.contains("Own the creative loop through truthful completion"))
            #expect(!policy.contains("Assistant delegates"))
            #expect(policy.contains("Your private workflow uses tools, never XML scheduling"))
            #expect(policy.contains("Do not invent extra features"))
            let schema = try #require(
                try JSONSerialization.jsonObject(with: request.tools[0].declaration) as? [String: Any])
            let function = try #require(schema["function"] as? [String: Any])
            let parameters = try #require(function["parameters"] as? [String: Any])
            let properties = try #require(parameters["properties"] as? [String: [String: Any]])
            let commands = try #require(properties["command"]?["enum"] as? [String])
            let library = commands.contains("searchWorkspaces")
            #expect(properties["workspaceID"] == nil)
            if library {
                #expect(policy.contains("Workspace library domain"))
                #expect(!commands.contains("edit") && properties["path"] == nil)
            } else {
                #expect(policy.contains("Workspace editing domain") && policy.contains("Active workspace: writer/"))
                #expect((properties["start"]?["description"] as? String)?.contains("decimal") == true)
                #expect(commands.contains("move") && !commands.contains("searchWorkspaces"))
            }
            let step = requests - (asks || invalidArguments ? 1 : 0)
            let command: [String: String]
            if libraryOnly, requests == 2 {
                command = ["command": "finish", "summary": "作品库为空"]
            } else if exactPatch, requests == 5 {
                command = ["command": "read", "path": "document.md"]
            } else if exactPatch, requests == 6 {
                let text = try #require(request.messages.last(where: { $0.role == .tool })?.content)
                let read = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                let reference = try #require(read["reference"] as? String)
                command = [
                    "command": "replace", "path": "document.md", "reference": reference,
                    "oldText": "Hello", "newText": "Hello 修订",
                ]
            } else if exactPatch, requests == 7 {
                command = ["command": "render"]
            } else {
                switch step {
                case 0:
                    command =
                        invalidArguments
                        ? ["command": "list", "verification": "ok"] : ["command": "ask", "summary": "希望用什么语言？"]
                case 1: command = ["command": "searchWorkspaces", "query": existing ? "task_1" : "测试问候"]
                case 2:
                    command =
                        existing
                        ? ["command": "enter", "taskID": "task_1"]
                        : ["command": "create", "title": "测试问候", "entry": "document.md"]
                case 3:
                    if !library {
                        #expect(request.messages.count == 2 && !request.messages.contains { $0.role == .tool })
                    }
                    command = ["command": "edit", "path": "document.md", "instruction": editInstruction]
                case 5: command = ["command": "render"]
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
@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13])
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
                if mode == 5, files["document.md"] == nil { throw WriterFailure.unavailable }
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
        slowContent: mode == 10 || mode == 12, naturalEnd: mode == 11, libraryOnly: mode == 13,
        editInstruction: mode == 0 ? "Write greeting. " + String(repeating: "保留标签。", count: 256) : "Write greeting"
    ) { request in
        if mode == 0, request == 3 { #expect(await startup.shown) }
        guard mode == 7, request == 1 || request == 3 else { return }
        let expected = request == 1 ? "第1轮" : "第3轮"
        let deadline = ContinuousClock.now + .seconds(3)
        while await islandState.detailActivity?.content.detail?.text?.contains(expected) != true {
            guard ContinuousClock.now < deadline else { throw WriterFailure.incomplete }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await islandState.detailActivity?.content.subtitle == "正在创作")
    }
    let journal = WriterHistoryStore(
        records: try WriterRecordStore(repository: records.writerMessages, logs: records.logs))
    let writer = try WriterAgent(
        model: {
            // Model acquisition and questions must not create an empty artifact.
            if !(await startup.shown) { #expect(try await workspace.inventory().isEmpty) }
            if mode == 3 { throw CancellationError() }
            return ChatModel(capability: model, modelName: "writer-fixture")
        }, streaming: artifacts, history: journal, tasks: records.writerExecutions,
        communications: records.agentMessages)
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
    try await output.bindCommunications(records.agentMessages)
    await writer.bind(try await output.consumer(for: writer))
    try await manager.start(.writer)
    let task = try await records.seedDelegation(
        taskID: nil, goal: "写一段问候", input: "写一段问候", sourceDialog: nil, agent: "writer")
    let scope = try AgentTaskScope(
        id: task.delegateID, requester: .assistant, executor: .writer, sessionID: session, execution: .background)
    let signal = try AgentTaskSignal(
        kind: .request, scope: scope, businessContract: "writer.author",
        data: JSONEncoder().encode(["request": "写一段问候", "entry": "document.md"]))
    let messaging = try await output.messaging(for: .assistant)
    let report = try await messaging.send(
        signal.message(), parent: AgentInput(id: UUID().uuidString, sessionID: session, payload: .text("写作")),
        to: .writer)
    #expect(report.rejected.isEmpty)
    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    var answered = false
    var pausedDelivery = false
    var verifiedIndependent = false
    var sceneHidden = false
    while !(await sink.signals.contains { $0.kind == .result }) {
        if mode == 12, !sceneHidden, await model.requests == 4 {
            await writer.setSceneActive(false)
            sceneHidden = true
        }
        if mode == 7, !verifiedIndependent, await model.requests == 6, !(try await workspace.list()).isEmpty {
            let saved = try await records.writerExecutions.request(task.delegateID, agent: "writer")
            let presented = await islandState.detailActivity == nil
            if saved.status == "completed", presented {
                #expect(await sink.signals.isEmpty)
                #expect(await !sink.rejectedReports.isEmpty)
                let firstEvent = await sink.rejectedReports.first
                #expect(await writer.observationSnapshot().business["phase"] == .text("idle"))
                await sink.allowReports()
                verifiedIndependent = true
                // All retries retain their identity; no extra model/file execution.
                #expect(await model.requests == 6)
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
                #expect(
                    try await records.writerExecutions.request(task.delegateID, agent: "writer").status == "interrupted"
                )
                #expect(try await records.writerExecutions.taskNotification(scope.id, agent: "writer") != nil)
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
        guard ContinuousClock.now < deadline else {
            throw WriterFailure.incomplete
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    let retiredDeadline = ContinuousClock.now + .seconds(5)
    while try await records.writerExecutions.taskNotification(scope.id, agent: "writer")?.retired != true {
        guard ContinuousClock.now < retiredDeadline else { throw WriterFailure.incomplete }
        try await Task.sleep(for: .milliseconds(10))
    }
    let result = try #require(await sink.signals.last { $0.kind == .result })
    let resultText = try AgentTaskContent.decode(result).text
    if mode == 13 {
        #expect(result.status == .succeeded)
        #expect(resultText.contains("作品库为空") && !resultText.contains("作品已保存"))
        #expect(try await workspace.inventory().isEmpty)
        #expect(await startup.shown == false)
        #expect(await model.requests == 2)
        #expect(try await records.writerExecutions.task(task.id, agent: "writer").workspaceReady == false)
        await writer.stop()
        await output.shutdown()
        try await records.shutdown()
        await islandState.stop()
        return
    }
    if mode == 5 {
        #expect(result.status == .failed)
        let pending = try await records.writerExecutions.task(task.id, agent: "writer")
        let project = pending.workspaceID
        // Files/index are prepared before UI presentation; a failed window does not erase the workspace.
        #expect(pending.workspaceReady)
        await model.restart()
        let retry = try await records.seedDelegation(
            taskID: task.id, goal: "重试", input: "继续原任务", sourceDialog: nil, agent: "writer")
        let nextScope = try AgentTaskScope(
            id: retry.delegateID, requester: .assistant, executor: .writer, sessionID: session, execution: .background)
        let next = try AgentTaskSignal(
            kind: .request, scope: nextScope, businessContract: "writer.author",
            data: JSONEncoder().encode([
                "goal": "重试", "request": "继续原任务", "entry": "document.md",
            ]))
        let receipt = try await messaging.send(
            next.message(), parent: .init(id: UUID().uuidString, sessionID: session, payload: .text("重试")), to: .writer)
        #expect(receipt.rejected.isEmpty)
        let until = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await sink.signals.contains { $0.kind == .result && $0.scope.id == retry.delegateID }) {
            guard ContinuousClock.now < until else { throw WriterFailure.incomplete }
            try await Task.sleep(for: .milliseconds(10))
        }
        let completed = try await records.writerExecutions.task(task.id, agent: "writer")
        #expect(completed.workspaceID == project && completed.workspaceReady)
        #expect(try await records.writerExecutions.request(retry.delegateID, agent: "writer").status == "completed")
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
                try await records.writerExecutions.request(task.delegateID, agent: "writer").failure?.contains(
                    "code=writer.network.timeout") == true)
        }

        #expect(result.status == .failed)
        #expect(try AgentTaskContent.decode(result).writerEvent?.kind == .failed)
        #expect(
            try await records.writerExecutions.request(task.delegateID, agent: "writer").status
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
    let saved = try await records.writerExecutions.task(task.id, agent: "writer")
    #expect(saved.workspaceReady && saved.workspaceID == "writer/" + saved.id)
    if !asks { #expect(pausedDelivery) }
    #expect(try AgentTaskContent.decode(result).writerEvent?.eventID == (await sink.rejectedCompletion))
    let evidence = await sink.signals.filter {
        $0.kind == .result && (try? AgentTaskContent.decode($0).writerEvent?.kind) == .completed
    }
    #expect(evidence.count == 1)
    #expect(try await workspace.list().first?.files["document.md"] == expectedSource)
    #expect(await model.requests == (mode == 9 ? 8 : asks || mode == 8 ? 7 : 6))
    #expect(try AgentTaskContent.decode(result).artifactID != nil)
    let current = try await journal.readCurrent().current
    let persistedCount = try await records.writerMessages.timelineCount(task: current.id)
    #expect(
        current.turns.count == (mode == 9 ? 8 : asks ? 8 : mode == 8 ? 7 : 6),
        "scope=\(current.id), persisted=\(persistedCount), turns=\(current.turns.map(\.id))")
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
        try await service.perform(invocation: invocation("two", ["command": "start"]))
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
    _ = try await service.perform(invocation: invocation("three", ["command": "start"]))
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

@Test(.actionCatalog) func writerFileToolsAcceptLargeInputsAndSessionHandles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let records = try await workspaceFixtureRepositories()
    let workspace = ArtifactWorkspace(disk: try DiskFileStore(root: root), catalog: records.workspaces)
    let service = ArtifactService(workspace: workspace, present: { _, _, _, _, _ in "fixture" })
    func call(_ parameters: [String: String]) async throws -> String {
        try await service.perform(invocation: writerLifetimeInvocation(parameters))
    }
    func decode(_ value: String) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: Data(value.utf8))
    }

    let path = String(repeating: "directory", count: 19) + "/document.txt"
    let title = String(repeating: "作品", count: 32)
    _ = try await call(["command": "start", "entry": path, "title": title])
    await #expect(throws: ArtifactWorkspaceError.invalidInstruction) {
        try await call(["command": "edit", "path": path, "instruction": ""])
    }
    let edit = try await decode(call(["command": "edit", "path": path, "instruction": "Create document"]))
    let stream = try #require(edit["streamID"])
    let query = String(repeating: "文本", count: 200)
    let source = query + "\n" + String(repeating: "A long line of text for the read fixture.\n", count: 640)
    try await service.append(streamID: stream, delegateID: "delegate", text: source)
    _ = try await service.complete(streamID: stream, delegateID: "delegate")

    struct ReadOutput: Decodable {
        let reference: String
        let content: String
    }
    func read(_ parameters: [String: String]) async throws -> ReadOutput {
        let result = try await call(parameters.merging(["command": "read", "path": path]) { current, _ in current })
        return try JSONDecoder().decode(ReadOutput.self, from: Data(result.utf8))
    }
    let byLine = try await read(["line": "1", "limit": "700"])
    let byCharacter = try await read(["offset": "0", "limit": "30000"])
    #expect(byLine.content == source)
    #expect(byCharacter.content == source)
    var references = [byLine.reference]
    for _ in 0..<129 {
        let read = try await read(["offset": "0", "limit": "1"])
        references.append(read.reference)
    }
    let related = try await decode(
        call([
            "command": "edit", "path": "notes.txt", "instruction": "Write notes",
            "contextReferences": references.prefix(9).joined(separator: ","),
        ]))
    #expect(related["context"]?.contains(source) == true)
    try await service.abort(streamID: #require(related["streamID"]), delegateID: "delegate")

    struct SearchOutput: Decodable {
        let matches: [[String: String]]
    }
    let search = try await call(["command": "search", "query": query])
    let found = try JSONDecoder().decode(SearchOutput.self, from: Data(search.utf8))
    #expect(found.matches.map { $0["path"] } == [path])
    for number in 1...9 {
        let savepoint = try await decode(call(["command": "savepoint"]))
        #expect(savepoint["savepoint"] == "savepoint_\(number)")
    }
    _ = try await call(["command": "render"])
    _ = try await call(["command": "finish"])
    let project = try await workspace.project(#require(WorkspaceID(rawValue: "writer/task_1")))
    #expect(project.title == title)
    #expect(project.files[path] == source)
    try await service.release(delegateID: "delegate")
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
    func search(_ query: String, before: String?) async throws -> (matches: [WorkspaceSummary], nextBefore: String?) {
        try await base.search(query, before: before)
    }
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
    #expect(try await workspace.checkpoint(for: namingProject) == nil)
    #expect(try await workspace.project(namingProject).title == "Project flowchart")

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
    let assistant = try await database.assistantConversations.current()
    let store = WriterHistoryStore(
        records: try WriterRecordStore(repository: database.writerMessages, logs: database.logs))
    let task = try await database.seedDelegation(
        taskID: nil, goal: "绘图", input: "画一张图", sourceDialog: assistant.id, agent: "writer")
    try await database.writerExecutions.prepareWorkspace(
        task.workspaceID, taskID: task.id, delegateID: task.delegateID, agent: "writer")
    let history = WriterHistory(
        store: store, taskID: task.id, delegateID: task.delegateID, goal: "画一张图 · project abc")
    let definition =
        #"{"type":"function","function":{"name":"workspace","parameters":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}}"#
    let request = try ChatRequest(
        messages: [.init(role: .system, content: "Writer policy"), .init(role: .user, content: "<h1>中文 🌍</h1>")],
        maximumOutputTokens: 2048, temperature: 0.2,
        tools: [try ChatToolDefinition(declaration: Data(definition.utf8))])
    let id = try await history.begin(request, phase: "内容", path: "index.html")
    try await history.recording(AgentModelRequestRecording(request).snapshot(initial: true), id: id)
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
    // An input-only checkpoint must not overwrite this request's structured tool catalog.
    try await store.recordExecutionFailure("host cleanup fixture", for: id)
    try await store.checkpoint()
    let nextRequest = try ChatRequest(messages: [
        .init(
            role: .assistant, content: "",
            toolCalls: [
                .init(id: "call", name: "workspace", argumentsJSON: largeArguments)
            ]),
        .init(role: .tool, content: "Saved artifact abc", toolCallID: "call"),
    ])
    let largeSnapshot = try await history.begin(nextRequest, phase: "control")
    try await history.recording(AgentModelRequestRecording(nextRequest).snapshot(initial: true), id: largeSnapshot)
    try await history.finish(largeSnapshot)
    try await history.hostFinalization(largeSnapshot, result: nil, error: WriterNetworkFixtureFailure())

    let cancelled = try await history.begin(request, phase: "控制")
    try await history.event(.text("partial"), id: cancelled)
    try await history.finish(cancelled, error: CancellationError())
    let failed = try await history.begin(request, phase: "控制请求")
    let diagnostic = WriterDiagnostics.make(
        WriterNetworkFixtureFailure(), stage: "控制请求", details: ["model": "fixture", "elapsedSeconds": "60.030"])
    try await history.finish(failed, error: WriterNetworkFixtureFailure(), diagnostic: diagnostic)
    let dialog = try await store.readCurrent().current.id
    #expect(dialog != assistant.id)
    #expect(try database.assistantMessages.messages(dialog: assistant.id, after: nil, limit: 20).isEmpty)
    try await database.endSeedDelegation(task.delegateID, status: "failed", failure: "fixture")
    try await database.shutdown()
    let reopened = try SQLiteRepositories(url: url)
    let restored = WriterHistoryStore(
        records: try WriterRecordStore(repository: reopened.writerMessages, logs: reopened.logs))
    let restoredTask = try await reopened.writerExecutions.task(task.id, agent: "writer")
    #expect(restoredTask.dialogID != dialog)
    let value = try await WriterRecordStore(repository: reopened.writerMessages, logs: reopened.logs)
        .read(dialog)
    let record = try #require(value.turns.first { $0.id == id })
    #expect(record.temperature == 0.2)
    #expect(record.maximumOutputTokens == 2048)
    let modelRequest = try #require(record.modelRequests?.first)
    #expect(modelRequest.requestParametersJSON?.contains("中文 🌍") == true)
    #expect(modelRequest.response == "<h1>完成</h1>")
    #expect(modelRequest.decisionMetadata?.taskID == task.id)
    let snapshotJSON = try #require(
        value.turns.first { $0.id == largeSnapshot }?.modelRequests?.first?.requestParametersJSON)
    let snapshotRoot = try #require(JSONSerialization.jsonObject(with: Data(snapshotJSON.utf8)) as? [String: Any])
    let snapshotMessages = try #require(snapshotRoot["messages"] as? [[String: Any]])
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
    let restoredRun = try await reopened.writerExecutions.request(task.delegateID, agent: "writer")
    #expect(restoredRun.finishedAt != nil)
    #expect(
        try await reopened.writerExecutions.requests(task.id, agent: "writer").first?.finishedAt
            == restoredRun.finishedAt
    )

    let controller = await WriterContainer()
    try await controller.configureHistory(
        messages: reopened.writerMessages, tasks: reopened.writerExecutions, communications: reopened.agentMessages,
        logs: reopened.logs)
    let requestPage = try await controller.requests(taskID: task.id, after: 0)
    #expect(requestPage.items.first?.title == "读取 index.html")
    #expect(requestPage.items.first?.statusTitle == "已完成")
    let firstID = try #require(modelRequest.messageID)
    let firstDetail = try await controller.requestDetail(firstID)
    #expect(firstDetail.summary.number == requestPage.items.first?.number)
    #expect(firstDetail.request?.temperature == 0.2 && firstDetail.request?.maximumOutputTokens == 2048)
    #expect(firstDetail.finalization == nil && firstDetail.toolSources.isEmpty)
    let nextID = try #require(value.turns.first { $0.id == largeSnapshot }?.modelRequests?.first?.messageID)
    let nextDetail = try await controller.requestDetail(nextID)
    #expect(nextDetail.toolSources == ["call": firstID])
    #expect(nextDetail.request?.state == .completed)
    #expect(nextDetail.finalization?.state == .failed && nextDetail.finalization?.error != nil)
    #expect(nextDetail.request?.maximumOutputTokens == nil)
    let sameRound = try reopened.writerMessages.detailContext(firstID, toolCallIDs: ["call"])
    #expect(sameRound.toolSources.isEmpty)
    let completedTask = try await controller.task(task.id)
    #expect(
        completedTask.updatedAt == (try await reopened.writerExecutions.task(task.id, agent: "writer")).updatedAt)
    #expect(completedTask.startedAt != nil && completedTask.requestCount > 0)
    let continuation = try await reopened.seedDelegation(
        taskID: task.id, goal: "revise", input: "revise", sourceDialog: nil, agent: "writer")
    let activeTask = try await controller.task(task.id)
    #expect(activeTask.startedAt == completedTask.startedAt && activeTask.updatedAt >= completedTask.updatedAt)
    #expect(activeTask.requestCount == completedTask.requestCount)
    try await reopened.endSeedDelegation(continuation.delegateID, status: "completed", failure: nil)

    #expect(value.turns.first { $0.id == cancelled }?.state == .cancelled)
    let failure = try #require(value.turns.first { $0.id == failed }?.modelRequests?.last?.failureDiagnostic)
    #expect(failure == diagnostic.storageValue && failure.details["networkCode"] == "-1001")
    let resumedContext = try await WriterHistory(
        store: restored, taskID: task.id, delegateID: continuation.delegateID, goal: "Continue"
    ).restoredContext()
    #expect(resumedContext.isEmpty)

    let projection = try JSONDecoder().decode(HistoryConversation.self, from: JSONEncoder().encode(value))
    let timed = try #require(projection.turns.first { $0.id == id }?.modelRequests?.first)
    #expect(WriterRecordPresentation.contentPath(timed) == "index.html")
    let inputTools = try #require(try WriterRecordPresentation.tools(timed))
    #expect(inputTools.map(\.alias) == ["workspace"])
    #expect(inputTools.first?.required == ["command"])
    #expect(inputTools.first?.definitionJSON == definition)
    let contentOnly = try #require(projection.turns.first { $0.id == largeSnapshot }?.modelRequests?.first)
    #expect(try WriterRecordPresentation.tools(contentOnly)?.isEmpty == true)
    let selectedDetail = try await restored.message(try #require(modelRequest.messageID))
    let selectedUI = try JSONDecoder().decode(HistoryConversation.self, from: JSONEncoder().encode(selectedDetail))
    let selectedRequest = try #require(selectedUI.turns.first?.modelRequests?.first)
    #expect(try WriterRecordPresentation.tools(selectedRequest)?.first?.definitionJSON == definition)
    #expect(timed.modelRequestCompletedAt == modelRequest.modelRequestCompletedAt)
    #expect(!WriterRecordPresentation.firstToken(timed).contains("未知"))
    #expect(!WriterRecordPresentation.requestDuration(timed, at: Date()).contains("未知"))

    let projected = try #require(projection.turns.first { $0.id == failed }?.modelRequests?.last?.failureDiagnostic)
    #expect(projected.category == failure.category && projected.details == failure.details)
    try await restored.clearRequestLogs(requestID: nil)
    let clearedDetail = try await controller.requestDetail(nextID)
    #expect(clearedDetail.request?.logsCleared == true && clearedDetail.request?.temperature == nil)
    #expect(clearedDetail.toolSources == nextDetail.toolSources && clearedDetail.finalization?.state == .failed)
    let cleared = try await WriterRecordStore(repository: reopened.writerMessages, logs: reopened.logs).read(dialog)
    let toolInput = try #require(cleared.turns.first { $0.id == largeSnapshot }?.modelRequests?.first)
    #expect(toolInput.logsCleared == true && toolInput.requestParametersJSON == nil)
    #expect(
        toolInput.inputMessages == [
            .init(role: .tool, content: "Saved artifact abc", toolCallID: "call", toolName: "workspace")
        ])
    let clearedProjection = try JSONDecoder().decode(HistoryConversation.self, from: JSONEncoder().encode(cleared))
    #expect(
        clearedProjection.turns.first { $0.id == largeSnapshot }?.modelRequests?.first?.inputMessages?.first?.toolName
            == "workspace")
    let clearedRequest = try #require(clearedProjection.turns.first { $0.id == id }?.modelRequests?.first)
    #expect(WriterRecordPresentation.contentPath(clearedRequest) == "index.html")
    #expect(try WriterRecordPresentation.tools(clearedRequest)?.first?.definitionJSON == definition)
    let clearedContent = try #require(clearedProjection.turns.first { $0.id == largeSnapshot }?.modelRequests?.first)
    #expect(try WriterRecordPresentation.tools(clearedContent)?.isEmpty == true)
    try await reopened.shutdown()
}

@Test func writerHistoryRecordsActualImagesWithoutPublishingMediaFiles() async throws {
    let records = try SQLiteRepositories.temporary()
    let files = try MemoryFileStore()
    let photos = MediaStore(repository: records.media, files: files)
    let store = WriterHistoryStore(
        records: try WriterRecordStore(repository: records.writerMessages, logs: records.logs))
    let task = try await records.seedDelegation(
        taskID: nil, goal: "Inspect", input: "Render", sourceDialog: nil, agent: "writer")
    let history = WriterHistory(store: store, taskID: task.id, delegateID: task.delegateID, goal: "Inspect")
    let bytes = Data([1, 2, 3])  // Byte preservation fixture; not native image decoding.
    let request = try ChatRequest(messages: [
        .init(role: .user, content: "Render", images: [try .init(id: "screenshot", data: bytes)])
    ])
    let id = try await history.begin(request, phase: "控制请求")
    try await history.recording(AgentModelRequestRecording(request).snapshot(initial: true), id: id)
    try await history.event(.text("Observed screenshot"), id: id)
    try await history.finish(id)
    let turn = try #require(await store.readCurrent().current.turns.first)
    let record = try #require(turn.modelRequests?.first)
    #expect(record.requestParametersJSON == nil)
    #expect(record.inputMessages == [.init(role: .user, content: "Render")])
    let detail = try await store.message(try #require(record.messageID))
    let payload = try #require(detail.turns.first?.modelRequests?.first?.requestParametersJSON)
    #expect(HistoryRecordedImages.data("screenshot", json: payload) == bytes)
    #expect(try await photos.albumPage().items.isEmpty)
    #expect(try await files.listObjects(cursor: nil, limit: 128).keys.isEmpty)
    let before = try await history.restoredContext()
    try await store.clearRequestLogs(requestID: nil)
    let after = try await history.restoredContext()
    #expect(before.map(\.content) == after.map(\.content))
    #expect(after.contains { $0.role == .assistant && $0.content == "Observed screenshot" })
    #expect(
        try await store.message(try #require(record.messageID)).turns.first?.modelRequests?.first?.logsCleared == true)
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
    let source = try await database.assistantConversations.current()
    let first = try await database.seedDelegation(
        taskID: nil, goal: "画流程图", input: "用户原始请求", sourceDialog: source.id, agent: "writer")
    let project = "writer/" + first.id
    try await database.writerExecutions.prepareWorkspace(
        project, taskID: first.id, delegateID: first.delegateID, agent: "writer")
    let journal = WriterHistoryStore(
        records: try WriterRecordStore(repository: database.writerMessages, logs: database.logs))
    let history = WriterHistory(
        store: journal, taskID: first.id, delegateID: first.delegateID, goal: "画流程图", modelName: "fixture-model")
    let request = try ChatRequest(
        messages: [.init(role: .system, content: "policy"), .init(role: .user, content: "画流程图")],
        maximumOutputTokens: 2048, temperature: 0.2)
    let input = try await history.begin(request, phase: "控制请求")
    try await history.recording(AgentModelRequestRecording(request).snapshot(initial: true), id: input)
    try await history.event(.text("先读文件"), id: input)
    try await history.event(
        .toolCall(.init(id: "read-1", name: "workspace", argumentsJSON: "{\"command\":\"read\"}")), id: input)
    try await history.finish(input)
    try await history.toolOutcome("read-1", output: "node A")
    try await database.endSeedDelegation(first.delegateID, status: "completed")
    let second = try await database.seedDelegation(
        taskID: first.id, goal: "改为蓝色", input: "继续改成蓝色", sourceDialog: source.id, agent: "writer")
    #expect(second.id == first.id && second.delegateID != first.delegateID)
    #expect(second.dialogID == first.dialogID && second.workspaceID == project && second.goal == "画流程图")
    let restored = try await WriterHistory(
        store: journal, taskID: first.id, delegateID: second.delegateID, goal: "改为蓝色"
    )
    .restoredContext()
    #expect(restored.isEmpty)
    #expect(try await journal.taskHistory(first.dialogID).turns.count == 1)
    try await journal.clearRequestLogs(requestID: nil)
    let afterClear = try await WriterHistory(
        store: journal, taskID: first.id, delegateID: second.delegateID, goal: "改为蓝色"
    ).restoredContext()
    #expect(afterClear.map(\.content) == restored.map(\.content))
    #expect(afterClear.isEmpty)
    await #expect(throws: (any Error).self) {
        try await database.writerExecutions.prepareWorkspace(
            UUID().uuidString, taskID: first.id, delegateID: first.delegateID, agent: "writer")
    }
    let cancelID = UUID().uuidString
    try await database.agentMessages.enqueueAgentMessage(
        .init(
            id: cancelID, sender: "assistant", receiver: "writer", contract: "task.cancel",
            payload: Data("{\"text\":\"Assistant requested cancellation\"}".utf8), correlationID: second.delegateID,
            replyTo: second.delegateID, dedupeKey: cancelID))
    try await database.endSeedDelegation(second.delegateID, status: "cancelled")
    let third = try await database.seedDelegation(
        taskID: nil, goal: "新作品", input: "另画一张", sourceDialog: source.id, agent: "writer")
    #expect(
        third.id != first.id && third.dialogID != first.dialogID && !third.workspaceReady
            && third.workspaceID == "writer/" + third.id)
    #expect(try await journal.readCurrent().current.id == database.writerMessages.current().id)
    try await database.endSeedDelegation(third.delegateID, status: "failed", failure: "fixture failure")
    let resumedAgain = try await database.seedDelegation(
        taskID: first.id, goal: "再次修改", input: "修改旧任务", sourceDialog: source.id, agent: "writer")
    #expect(resumedAgain.workspaceID == project && resumedAgain.dialogID == first.dialogID)
    let earlierContext = try await WriterHistory(
        store: journal, taskID: first.id, delegateID: resumedAgain.delegateID, goal: "再次修改"
    ).restoredContext()
    #expect(earlierContext.isEmpty)
    try await database.endSeedDelegation(resumedAgain.delegateID, status: "completed")
    // Writer histories have no cascading ownership by the requesting Assistant dialog.
    _ = try await database.assistantConversations.rotate(source.id)
    try await database.assistantConversations.deleteDialog(source.id)
    #expect(try await database.writerExecutions.task(first.id, agent: "writer").workspaceID == project)
    await #expect(throws: RecordStorageError.invalidRecord) {
        try await database.writerExecutions.tasks(agent: "assistant", before: nil, limit: 20)
    }
    try await database.shutdown()
    let reopened = try SQLiteRepositories(url: url)
    #expect(
        try await reopened.writerExecutions.request(resumedAgain.delegateID, agent: "writer").taskID == first.id)
    let runs = try await reopened.writerExecutions.requests(first.id, agent: "writer")
    #expect(runs.count == 3 && runs[1].status == "cancelled" && runs.last?.status == "completed")
    #expect(runs[1].cancellationReason == "Assistant requested cancellation")
    let records = WriterHistoryStore(
        records: try WriterRecordStore(repository: reopened.writerMessages, logs: reopened.logs))
    let full = try await records.taskHistory(first.dialogID)
    #expect(full.turns.first?.model == "")
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
        try JSONDecoder().decode(ModelFailureDiagnostic.self, from: JSONEncoder().encode(report))
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
    tasks: any WriterExecutionRepository
) async throws -> WriterTaskCompletion {
    let run = try await tasks.request(scope.id, agent: "writer")
    let event = try #require(content.writerEvent)
    let canonical = try AgentTaskContent(
        text: content.text, stage: .completed,
        interactionID: content.interactionID, artifactID: content.artifactID,
        writerEvent: .init(
            sequence: event.sequence, kind: event.kind, workspaceID: event.workspaceID,
            windowID: event.windowID, taskID: run.taskID.isEmpty ? nil : run.taskID, delegateID: run.delegateID,
            failure: event.failure,
            eventID: event.eventID))
    let report = try WriterTaskCompletion(canonical.signal(.result, scope: scope, status: status))
    try await tasks.completeRequest(
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
        history: WriterHistoryStore(
            records: try WriterRecordStore(repository: records.writerMessages, logs: records.logs)),
        tasks: records.writerExecutions, communications: records.agentMessages)
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
        let record = try await records.seedDelegation(
            taskID: nil, goal: "Goal \(index)", input: "Write greeting", sourceDialog: nil, agent: "writer")
        let scope = AgentTaskScope(
            id: record.delegateID, requester: .assistant, executor: .writer, sessionID: session, execution: .background)
        let request = try AgentTaskSignal(
            kind: .request, scope: scope, businessContract: "writer.author",
            data: JSONEncoder().encode([
                "goal": record.goal, "request": "Write greeting", "entry": "document.md",
            ]))
        let receipt = try await port.send(
            request.message(), parent: .init(id: UUID().uuidString, sessionID: session, payload: .text("Write")),
            to: .writer)
        #expect(receipt.rejected.isEmpty)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while true {
            let run = try await records.writerExecutions.request(record.delegateID, agent: "writer")
            let retired =
                try await records.writerExecutions.taskNotification(record.delegateID, agent: "writer")?.retired == true
            if run.status == "completed", retired { break }
            guard ContinuousClock.now < deadline else { throw WriterFailure.incomplete }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await writer.observationSnapshot().business["phase"] == .text("idle"))
        let notification = try #require(
            try await records.writerExecutions.taskNotification(record.delegateID, agent: "writer"))
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
    for run in runs {
        #expect(try await records.writerExecutions.taskNotification(run, agent: "writer")?.delivered == false)
    }
    await writer.stop()
    await output.shutdown()
    try await records.shutdown()

    // Reopen with no execution grants, a new Writer incarnation and no delegated request.
    let reopened = try SQLiteRepositories(url: recordsURL)
    let restored = try WriterAgent(
        model: { await models.acquire() }, streaming: artifacts, tasks: reopened.writerExecutions,
        communications: reopened.agentMessages)
    let resumedSink = WriterResultSink()
    let newManager = AgentManager()
    try await newManager.register(resumedSink, sessionID: session)
    try await newManager.register(restored)
    let newInput = InputGateway(manager: newManager, policy: policy)
    let newOutput = await OutputGateway(
        manager: newManager, requests: newInput, tools: assembly.tools, policy: policy, sink: { _ in })
    await restored.bind(try await newOutput.consumer(for: restored))
    try await newManager.start(.writer)
    let deadline = ContinuousClock.now.advanced(by: .seconds(35))
    while await resumedSink.signals.filter({ $0.kind == .result }).count < 20 {
        guard ContinuousClock.now < deadline else { throw WriterFailure.incomplete }
        try await Task.sleep(for: .milliseconds(20))
    }
    while true {
        let notices = try await reopened.writerExecutions.pendingTaskNotifications(
            agent: "writer", retirement: false, after: nil, limit: 1)
        let retirements = try await reopened.writerExecutions.pendingTaskNotifications(
            agent: "writer", retirement: true, after: nil, limit: 1)
        if notices.isEmpty && retirements.isEmpty { break }
        guard ContinuousClock.now < deadline else { throw WriterFailure.incomplete }
        try await Task.sleep(for: .milliseconds(20))
    }
    let delivered = await resumedSink.signals.filter { $0.kind == .result }
    #expect(Set(try delivered.map { try #require(try AgentTaskContent.decode($0).writerEvent?.eventID) }) == eventIDs)
    #expect(await models.count == 20)
    #expect(await restored.observationSnapshot().business["phase"] == .text("idle"))
    #expect(try await reopened.writerExecutions.tasks(agent: "writer", before: nil, limit: 50).count == 20)
    for run in runs {
        #expect(try await reopened.writerExecutions.request(run, agent: "writer").status == "completed")
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
    let first = try await database.seedDelegation(
        taskID: nil, goal: "First", input: "First input", sourceDialog: nil, agent: "writer")
    let event = UUID().uuidString
    let notification = TaskNotification(
        delegateID: first.delegateID, agent: "writer", eventID: event, data: Data("{\"text\":\"immutable fact\"}".utf8))
    try await database.writerExecutions.completeRequest(notification, status: "completed", failure: nil)
    try await database.writerExecutions.completeRequest(notification, status: "completed", failure: nil)
    try await database.writerExecutions.finishTaskNotification(
        first.delegateID, agent: "writer", retirement: true, completed: true, failure: nil)
    let second = try await database.seedDelegation(
        taskID: nil, goal: "Second", input: "Second input", sourceDialog: nil, agent: "writer")
    await #expect(throws: (any Error).self) {
        try await database.writerExecutions.completeRequest(
            TaskNotification(delegateID: second.delegateID, agent: "writer", eventID: event, data: notification.data),
            status: "completed", failure: nil)
    }
    // The failed notification insert must roll back the execution terminal update too.
    #expect(try await database.writerExecutions.request(second.delegateID, agent: "writer").status == "running")
    #expect(try await database.writerExecutions.taskNotification(second.delegateID, agent: "writer") == nil)
    await #expect(throws: RecordStorageError.conflict) {
        try await database.writerExecutions.completeRequest(
            TaskNotification(
                delegateID: first.delegateID, agent: "writer", eventID: event,
                data: Data("{\"text\":\"different\"}".utf8)),
            status: "completed", failure: nil)
    }
    await #expect(throws: RecordStorageError.invalidRecord) {
        try await database.writerExecutions.request(first.delegateID, agent: "assistant")
    }
    try await database.writerExecutions.finishTaskNotification(
        first.delegateID, agent: "writer", retirement: true, completed: true, failure: nil)
    #expect(
        try await database.writerExecutions.pendingTaskNotifications(
            agent: "writer", retirement: true, after: nil, limit: 32
        )
        .isEmpty)
    #expect(
        try await database.writerExecutions.pendingTaskNotifications(
            agent: "writer", retirement: false, after: nil, limit: 32
        )
        .count == 1)
    try await database.shutdown()
    let reopened = try SQLiteRepositories(url: url)
    let restored = try #require(try await reopened.writerExecutions.taskNotification(first.delegateID, agent: "writer"))
    #expect(restored.data == notification.data && restored.eventID == event)
    #expect(restored.retired && !restored.delivered)
    try await reopened.writerExecutions.finishTaskNotification(
        first.delegateID, agent: "writer", retirement: false, completed: true, failure: nil,
        claimToken: restored.claimToken)
    #expect(
        try await reopened.writerExecutions.pendingTaskNotifications(
            agent: "writer", retirement: false, after: nil, limit: 32
        )
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
    let task = try await database.seedDelegation(
        taskID: nil, goal: "Pair recovery", input: "Demo", sourceDialog: nil, agent: "writer")
    let store = WriterHistoryStore(
        records: try WriterRecordStore(repository: database.writerMessages, logs: database.logs))
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
    try await database.endSeedDelegation(task.delegateID, status: "failed")
    try await database.shutdown()
    let reopened = try SQLiteRepositories(url: url)
    let restored = WriterHistoryStore(
        records: try WriterRecordStore(repository: reopened.writerMessages, logs: reopened.logs))
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
    let delegation = try await records.seedDelegation(
        taskID: nil, goal: "report", input: "report", sourceDialog: nil, agent: "writer")
    let store = WriterHistoryStore(
        records: try WriterRecordStore(repository: records.writerMessages, logs: records.logs))
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
    let journal = try WriterRecordStore(repository: reopened.writerMessages, logs: reopened.logs)
    #expect(try await journal.requestCount(delegation.dialogID) == 25)
    let other = try AssistantRecordStore(
        repository: reopened.assistantMessages, tasks: reopened.assistantTasks,
        conversations: reopened.assistantConversations, logs: reopened.logs)
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
            await presentation.setSceneActive(false)
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
            // Reject the next snapshot slot for one window, while allowing its peer to restore.
            let blockedSlot = root.appendingPathComponent("previews/" + project.rawValue + "/1")
            try FileManager.default.removeItem(at: blockedSlot)
            try FileManager.default.createSymbolicLink(at: blockedSlot, withDestinationURL: root)
            windows.setAvailable(true)
            pages.setAvailable(true)
            await presentation.setSceneActive(true)
            let restoreDeadline = ContinuousClock.now + .seconds(5)
            while windows.windows.count < 2 {
                guard ContinuousClock.now < restoreDeadline else { throw WebPageError.timedOut }
                await Task.yield()
            }
            for item in windows.windows where item.phase == .opening {
                windows.complete(item.id, revision: item.revision, generation: windows.generation, success: true)
            }
            await presentation.waitForSceneRestoration()
            #expect(try windows.find(window.id).failure?.contains("invalidPath") == true)
            #expect(native.title == "Published")
            let peer = try #require(windows.windows.first { $0.id != window.id })
            #expect(try await pages.sessions[peer.id]?.observe().title == "Second background project")
            try FileManager.default.removeItem(at: blockedSlot)
            await presentation.setSceneActive(false)
            await presentation.setSceneActive(true)
            await presentation.waitForSceneRestoration()
            #expect(try windows.find(window.id).failure == nil)
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
            await presentation.setSceneActive(false)
            _ = try await presentation.present(
                id: project, title: "Diagram", entry: "pages/index.html",
                files: ["pages/index.html": "<title>Hidden minimized update</title>"], preview: true)
            await presentation.setSceneActive(true)
            await presentation.waitForSceneRestoration()
            #expect(try windows.find(window.id).mode == .minimized)
            #expect(native.title == "Background")

            await presentation.setSceneActive(false)
            try await presentation.prepare(id: project, deleting: false)
            await presentation.setSceneActive(true)
            let reopenDeadline = ContinuousClock.now + .seconds(5)
            while try windows.find(window.id).phase != .changing {
                guard ContinuousClock.now < reopenDeadline else { throw WebPageError.timedOut }
                await Task.yield()
            }
            let reopeningWindow = try windows.find(window.id)
            windows.complete(
                window.id, revision: reopeningWindow.revision, generation: windows.generation, success: true)
            await presentation.waitForSceneRestoration()
            #expect(windows.focusedID == window.id)
            #expect(try await page.observe().title == "Hidden minimized update")

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
#if os(macOS)
    extension LiveRuntimeTests {
        @Test @MainActor func artifactSceneHideCancelsAndJoinsPendingWindowRestore() async throws {
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
            await presentation.setSceneActive(false)
            _ = try await presentation.present(
                id: project, title: "Draft", entry: "index.html", files: ["index.html": "<title>Draft</title>"],
                preview: true)
            await presentation.setSceneActive(true)
            let deadline = ContinuousClock.now + .seconds(5)
            while windows.windows.isEmpty {
                guard ContinuousClock.now < deadline else { throw WebPageError.timedOut }
                await Task.yield()
            }
            let reserved = try #require(windows.windows.first?.id)
            // The window animation has not acknowledged presentation yet.
            await presentation.setSceneActive(false)
            #expect(pages.sessions[reserved] == nil)
            #expect(try windows.find(reserved).failure == nil)
            await presentation.setSceneActive(true)
            await presentation.waitForSceneRestoration()
            #expect(windows.windows.map(\.id) == [reserved])
            #expect(try await pages.sessions[reserved]?.observe().title == "Draft")
        }

        @Test(arguments: [true, false]) @MainActor
        func artifactWindowAwaitingFirstPresentationSurvivesInterruption(sceneLoss: Bool) async throws {
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
            if sceneLoss {
                windows.setAvailable(false)
                pages.setAvailable(false)
                await presentation.setSceneActive(false)
                #expect(try await opening.value.contains("deferred"))
                windows.setAvailable(true)
                pages.setAvailable(true)
                await presentation.setSceneActive(true)
                await presentation.waitForSceneRestoration()
            } else {
                let item = try windows.find(reserved)
                windows.complete(item.id, revision: item.revision, generation: windows.generation, success: false)
                #expect(try await opening.value.contains("deferred"))
            }
            #expect(windows.windows.count == 1 && windows.windows.first?.id == reserved)
            #expect(try await pages.sessions[reserved]?.observe().title == "Retained after scene loss")
        }
    }
#endif

@Test func writerRequestNamesUseActualCallsAndKeepStatusSeparateFromModelCompletion() throws {
    func call(_ values: [String: String], state: String = "completed") throws -> WriterToolPreview {
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
    let store = WriterHistoryStore(
        records: try WriterRecordStore(repository: database.writerMessages, logs: database.logs))
    let task = try await database.seedDelegation(
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
    let restored = WriterHistoryStore(
        records: try WriterRecordStore(repository: reopened.writerMessages, logs: reopened.logs))
    let record = try #require(try await restored.taskHistory(task.dialogID).turns.first)
    #expect(record.response == source)
    #expect(record.modelRequests?.first?.toolCalls.first?.output == result)
    let controller = await WriterContainer()
    try await controller.configureHistory(
        messages: reopened.writerMessages, tasks: reopened.writerExecutions, communications: reopened.agentMessages,
        logs: reopened.logs)
    let detail = try await controller.requestDetail(try #require(record.modelRequests?.first?.messageID))
    #expect(detail.finalization?.state == .completed && detail.finalization?.result == result)
    try await reopened.shutdown()
}

@Test func httpHistoryImagesSupportResponsesAndChatProtocolsWithoutFallback() throws {
    let bytes = Data([1, 2, 3])
    let url = "data:image/png;base64," + bytes.base64EncodedString()
    for (key, part) in [
        ("input", ["type": "input_image", "image_url": url] as [String: Any]),
        ("messages", ["type": "image_url", "image_url": ["url": url]] as [String: Any]),
    ] {
        let payload = String(
            decoding: try JSONSerialization.data(withJSONObject: [key: [["role": "user", "content": [part]]]]),
            as: UTF8.self)
        let reference = try #require(HistoryRecordedImages.references(payload).first)
        #expect(reference.mimeType == "image/png" && reference.byteCount == bytes.count)
        #expect(HistoryRecordedImages.data(reference.id, json: payload) == bytes)
    }
    #expect(HistoryRecordedImages.references(nil).isEmpty)
    #expect(HistoryRecordedImages.data("http_image_1", json: nil) == nil)
}

@Test(.actionCatalog) func writerLibraryOpensSavedWorksWithoutEditingAndRejectsAssistant() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = ArtifactWorkspace(
        disk: try DiskFileStore(root: root), catalog: try await workspaceFixtureRepositories().workspaces)
    let id = try #require(WorkspaceID(rawValue: "writer/task_1"))
    let original = try await workspace.publish(
        id: id, expecting: nil, title: "流程图", draft: ArtifactDraft(files: ["index.html": "<p>original</p>"]))
    let service = ArtifactService(workspace: workspace) { target, title, _, files, preview in
        #expect(target == id && title == "流程图" && files == original.files && !preview)
        return #"{"windowID":"window_1"}"#
    }
    func call(_ command: String, source: String = "writer", task: String = "task_1") -> FunctionInvocation {
        .init(
            call: .init(
                actionPath: .init(domain: "Artifacts", module: "Workspace", function: "perform"),
                parameters: ["command": command, "taskID": task, "query": "流程"]),
            context: .init(source: source, sessionID: "library", inputID: "lookup", taskID: "delegate"),
            executionID: UUID().uuidString, results: ActionReportStore())
    }
    for command in ["searchWorkspaces", "open", "delete"] {
        await #expect(throws: ActionExecutionError.invalidInvocation) {
            try await service.perform(invocation: call(command, source: "assistant"))
        }
    }
    #expect(try await service.perform(invocation: call("searchWorkspaces")).contains("流程图"))
    #expect(try await service.perform(invocation: call("open")).contains("window_1"))
    #expect(try await workspace.project(id) == original)
    #expect(try await workspace.checkpoint(for: id) == nil)
    await #expect(throws: ArtifactWorkspaceError.missingProject) {
        try await service.perform(invocation: call("open", task: "task_999"))
    }
    await #expect(throws: ArtifactWorkspaceError.invalidPath) {
        try await service.perform(invocation: call("open", task: "../task_1"))
    }
    #expect(try await workspace.inventory().count == 1)
    _ = try await service.perform(invocation: call("delete"))
    #expect(try await workspace.inventory().isEmpty)
    try await service.release(delegateID: "delegate")
}

private actor WriterCohesionModel: ChatCapability {
    nonisolated let availability: CapabilityAvailability = .available
    nonisolated let supportsToolCalls = true
    let mode: String
    let target: String
    var round = 0
    var commands: [String] = []
    init(mode: String, target: String) {
        self.mode = mode
        self.target = target
    }
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        let pair = InferenceSession<ChatEvent>.make(limits: try .init(), estimatedBytes: { $0.estimatedBytes })
        if request.tools.isEmpty {
            try pair.emitter.yield(.text("# Draft\nKEEP"))
            try pair.emitter.yield(.finished(.stop))
        } else {
            round += 1
            if round == 1 {
                #expect(
                    !request.messages.contains {
                        $0.role == .user && $0.content.contains("Workspace: writer/" + target + "\n")
                    })
            }
            guard round < 14 else { throw WriterFailure.incomplete }
            let sequence: [String]
            switch mode {
            case "explanation": sequence = ["explanation"]
            case "render-retry": sequence = ["searchWorkspaces", "create", "edit", "finish", "render", "finish"]
            case "explanation-after-edit":
                sequence = ["searchWorkspaces", "create", "edit", "explanation", "render", "finish"]
            case "read-before-enter":
                sequence = ["read", "searchWorkspaces", "enter", "read", "replace", "render", "finish"]
            case "clarify-enter":
                sequence = ["searchWorkspaces", "ask", "enter", "read", "replace", "render", "finish"]
            case "clarify-workspace":
                sequence = ["searchWorkspaces", "enter", "ask", "read", "replace", "render", "finish"]
            case "switch-after-edit": sequence = ["searchWorkspaces", "create", "edit", "enter", "render", "finish"]
            case "open": sequence = ["searchWorkspaces", "open", "finish"]
            default: sequence = ["searchWorkspaces", "enter", "read", "replace", "render", "finish"]
            }
            let command = sequence[min(round - 1, sequence.count - 1)]
            if round > 1, ["enter", "create", "open"].contains(commands.last ?? ""),
                mode != "switch-after-edit" || commands.last == "create"
            {
                let prompt = try #require(request.messages.first?.content)
                #expect(prompt.contains(mode == "open" ? "Workspace viewing domain" : "Workspace editing domain"))
                #expect(request.messages.count == 2 && !prompt.contains("Workspace library domain"))
                #expect(!String(decoding: request.tools[0].declaration, as: UTF8.self).contains("searchWorkspaces"))
            }
            if mode == "clarify-workspace", commands.last == "ask" {
                #expect(request.messages.first?.content.contains("Workspace editing domain") == true)
                let tools = request.messages.flatMap(\.toolCalls)
                #expect(!tools.contains { $0.argumentsJSON.contains("searchWorkspaces") })
                #expect(tools.contains { $0.argumentsJSON.contains("ask") })
            }
            commands.append(command)
            var args = ["command": command]
            switch command {
            case "enter", "open": args["taskID"] = target
            case "searchWorkspaces":
                args["query"] =
                    ["render-retry", "explanation-after-edit", "switch-after-edit"].contains(mode)
                    ? "distinct new fixture" : target
            case "create":
                args["title"] = "New work"
                args["entry"] = "document.md"
            case "ask": args["summary"] = "请选择要修改的作品。"
            case "read": args["path"] = "document.md"
            case "edit":
                args.merge(
                    ["path": "document.md", "instruction": "Write exactly # Draft followed by KEEP"],
                    uniquingKeysWith: { _, b in b })
            case "replace":
                let text = try #require(request.messages.last(where: { $0.role == .tool })?.content)
                let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                args.merge(
                    [
                        "path": "document.md",
                        "reference": try #require(object["reference"] as? String, "read response: \(text)"),
                        "oldText": "Draft", "newText": "Final",
                    ], uniquingKeysWith: { _, b in b })
            case "finish": args["summary"] = "已完成"
            case "explanation": args = ["command": "finish", "outcome": "explanation", "summary": "当前不支持外部下载，未创建文件。"]
            default: break
            }
            try pair.emitter.yield(
                .toolCall(
                    .init(
                        id: UUID().uuidString, name: "workspace",
                        argumentsJSON: String(decoding: try JSONEncoder().encode(args), as: UTF8.self))))
            try pair.emitter.yield(.finished(.toolCalls))
        }
        pair.emitter.finish()
        return pair.session
    }
}

@Test(
    .actionCatalog, .timeLimit(.minutes(1)),
    arguments: [
        "enter", "clarify-enter", "clarify-workspace", "read-before-enter", "open", "explanation", "render-retry",
        "explanation-after-edit",
        "switch-after-edit",
    ])
func writerOwnsTargetSelectionAndCompletion(mode: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("records.sqlite")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let records = try SQLiteRepositories(url: databaseURL)
    let workspace = ArtifactWorkspace(
        disk: try DiskFileStore(root: root.appendingPathComponent("files")), catalog: records.workspaces)
    let old = try await records.seedDelegation(
        taskID: nil, goal: "Saved work", input: "seed", sourceDialog: nil, agent: "writer")
    let workspaceID = try #require(WorkspaceID(rawValue: old.workspaceID))
    _ = try await workspace.publish(
        id: workspaceID, expecting: nil, title: "Saved work",
        draft: ArtifactDraft(files: ["document.md": "# Draft\nKEEP", "style.css": "KEEP_STYLE"]), entry: "document.md")
    try await records.endSeedDelegation(old.delegateID, status: "completed")
    let model = WriterCohesionModel(mode: mode, target: old.id)
    let journal = WriterHistoryStore(
        records: try WriterRecordStore(repository: records.writerMessages, logs: records.logs))
    let startup = WriterStartupProbe()
    let artifacts = ArtifactService(
        workspace: workspace,
        present: { _, _, _, _, _ in
            await startup.mark()
            return #"{"status":"observed"}"#
        })
    let writer = try WriterAgent(
        model: { ChatModel(capability: model, modelName: "cohesion-fixture") }, streaming: artifacts, history: journal,
        tasks: records.writerExecutions, communications: records.agentMessages)
    let sink = WriterResultSink()
    let manager = AgentManager()
    let session = UUID().uuidString
    try await manager.register(sink, sessionID: session)
    try await manager.register(writer)
    let island = await IslandState()
    await island.setAvailable(true)
    let assembly = try BehaviorAssembly(capabilityModules: [
        ArtifactsModule(artifacts: artifacts), IslandModule(island: await IslandPresentationService(state: island)),
    ])
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, configurations: AgentConfigurations.all())
    let output = await OutputGateway(
        manager: manager, requests: InputGateway(manager: manager, policy: policy), tools: assembly.tools,
        policy: policy, sink: { _ in })
    try await output.bindCommunications(records.agentMessages)
    await writer.bind(try await output.consumer(for: writer))
    try await manager.start(.writer)
    let messaging = try await output.messaging(for: .assistant)
    if mode == "enter" {
        for field in ["taskID", "workspaceID"] {
            let forbiddenScope = AgentTaskScope(
                id: UUID().uuidString, requester: .assistant, executor: .writer, sessionID: session,
                execution: .background)
            let forbidden = try AgentTaskSignal(
                kind: .request, scope: forbiddenScope, businessContract: "writer.author",
                data: JSONEncoder().encode(["request": "Find Saved work", field: old.id]))
            let rejected = try await messaging.send(
                forbidden.message(),
                parent: .init(id: UUID().uuidString, sessionID: session, payload: .text("invalid identity")),
                to: .writer)
            #expect(!rejected.rejected.isEmpty)
            #expect(try await records.writerExecutions.tasks(agent: "writer", before: nil, limit: 50).count == 1)
        }
    }
    let requestID = UUID().uuidString
    let scope = AgentTaskScope(
        id: requestID, requester: .assistant, executor: .writer, sessionID: session, execution: .background)
    let signal = try AgentTaskSignal(
        kind: .request, scope: scope, businessContract: "writer.author",
        data: JSONEncoder().encode(["request": "Find Saved work and update Draft to Final", "entry": "document.md"]))
    let receipt = try await messaging.send(
        signal.message(), parent: .init(id: UUID().uuidString, sessionID: session, payload: .text("request")),
        to: .writer)
    #expect(receipt.rejected.isEmpty)
    let admitted = try await records.writerExecutions.request(requestID, agent: "writer")
    var answered = false
    let deadline = ContinuousClock.now + .seconds(15)
    while !(await sink.signals.contains { $0.kind == .result && $0.scope.id == requestID }) {
        guard ContinuousClock.now < deadline else { throw WriterFailure.incomplete }
        if !answered,
            let question = await sink.signals.compactMap({ try? AgentTaskContent.decode($0) }).last(where: {
                $0.interactionID != nil
            })
        {
            let reply = try AgentTaskContent(text: "选择 " + old.id, interactionID: question.interactionID).signal(
                .input, scope: scope)
            let result = try await messaging.send(
                reply.message(), parent: .init(id: UUID().uuidString, sessionID: session, payload: .text("answer")),
                to: .writer)
            #expect(result.rejected.isEmpty)
            answered = true
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    let completion = try #require(await sink.signals.last { $0.kind == .result && $0.scope.id == requestID })
    #expect(completion.status == .succeeded)
    let content = try AgentTaskContent.decode(completion)
    let current = try await records.writerExecutions.request(requestID, agent: "writer")
    let selected = ["enter", "read-before-enter", "clarify-enter", "clarify-workspace"].contains(mode)
    if selected {
        #expect(current.taskID == old.id && content.writerEvent?.taskID == old.id)
        #expect(try await workspace.inventory().count == 1)
        #expect(
            try await workspace.project(workspaceID).files == [
                "document.md": "# Final\nKEEP", "style.css": "KEEP_STYLE",
            ])
        if admitted.taskID != old.id {
            await #expect(throws: (any Error).self) {
                try await records.writerExecutions.task(admitted.taskID, agent: "writer")
            }
        }
        #expect(try await records.writerExecutions.tasks(agent: "writer", before: nil, limit: 50).count == 1)
        #expect(try await records.writerExecutions.request(old.delegateID, agent: "writer").status == "completed")
    } else if mode == "open" {
        #expect(current.taskID == old.id)
        #expect(await startup.shown)
        #expect(try await workspace.project(workspaceID).files["document.md"] == "# Draft\nKEEP")
        #expect(try await workspace.checkpoint(for: workspaceID) == nil)
        #expect(!content.text.contains("作品已保存"))
    } else if mode == "explanation" {
        #expect(try await workspace.inventory().count == 1)
        #expect(await startup.shown == false)
        #expect(content.artifactID == nil && content.writerEvent?.workspaceID == nil)
        #expect(!content.text.contains("作品已保存"))
    } else {
        #expect(current.taskID != old.id)
        #expect(try await workspace.project(workspaceID).files["document.md"] == "# Draft\nKEEP")
        let created = try #require(WorkspaceID(rawValue: "writer/" + current.taskID))
        #expect(try await workspace.project(created).files["document.md"] == "# Draft\nKEEP")
    }
    #expect(answered == ["clarify-enter", "clarify-workspace"].contains(mode))
    let finalTask = current.taskID
    let requestHistoryID = "writer/request_\(current.messageID)"
    let history = try await journal.taskHistory(requestHistoryID)
    let requests = history.turns.flatMap { $0.modelRequests ?? [] }
    let calls = requests.flatMap(\.toolCalls)
    #expect(!calls.isEmpty && !calls.contains { $0.state == .received })
    let libraryRequests = requests.filter { $0.producerMetadata?["controlDomain"] == "library" }
    #expect(!libraryRequests.isEmpty && libraryRequests.allSatisfy { $0.decisionMetadata?.taskID == nil })
    if mode != "explanation" {
        let expectedDomain = (mode == "open" ? "view:" : "workspace:") + "writer/" + current.taskID
        let scopedRequests = requests.filter { $0.producerMetadata?["controlDomain"] == expectedDomain }
        #expect(!scopedRequests.isEmpty && scopedRequests.allSatisfy { $0.decisionMetadata?.taskID == current.taskID })
    }
    if ["render-retry", "explanation-after-edit", "read-before-enter", "switch-after-edit"].contains(mode) {
        #expect(calls.contains { $0.state == .failed })
    }
    let identities = Set(calls.map(\.providerID))
    await writer.stop()
    await output.shutdown()
    await island.stop()
    try await records.shutdown()
    let reopened = try SQLiteRepositories(url: databaseURL)
    let restored = WriterHistoryStore(
        records: try WriterRecordStore(repository: reopened.writerMessages, logs: reopened.logs))
    let persisted = try await restored.taskHistory(requestHistoryID)
    #expect(
        Set(persisted.turns.flatMap { $0.modelRequests ?? [] }.flatMap(\.toolCalls).map(\.providerID)) == identities)
    #expect(try await reopened.writerExecutions.request(requestID, agent: "writer").taskID == finalTask)
    try await reopened.shutdown()
}

@Test @MainActor func writerRecordControllersOnlyAdvertiseActualFollowingPages() async throws {
    let records = try SQLiteRepositories.temporary()
    let controller = WriterContainer()
    try controller.configureHistory(
        messages: records.writerMessages, tasks: records.writerExecutions, communications: records.agentMessages,
        logs: records.logs)
    let empty = try await controller.tasks(before: nil)
    #expect(empty.items.isEmpty && empty.nextID == nil)
    let task = try await records.seedDelegation(
        taskID: nil, goal: "Paging", input: "Paging", sourceDialog: nil, agent: "writer")
    let store = try #require(controller.historyStore)
    let history = WriterHistory(store: store, taskID: task.id, delegateID: task.delegateID, goal: "Paging")
    let request = try ChatRequest(messages: [.init(role: .user, content: "Page fixture")])
    var total = 0
    for count in [0, 19, 20, 21, 40] {
        while total < count {
            let id = try await history.begin(request, phase: "控制请求")
            try await history.event(.text("row"), id: id)
            try await history.event(.finished(.stop), id: id)
            try await history.finish(id)
            total += 1
        }
        let first = try await controller.requests(taskID: task.id, after: 0)
        #expect(first.items.count == min(count, 20))
        #expect((first.nextPosition != nil) == (count > 20))
        if let next = first.nextPosition {
            let second = try await controller.requests(taskID: task.id, after: next)
            #expect(second.items.count == count - 20 && second.nextPosition == nil)
            #expect(Set((first.items + second.items).map(\.id)).count == count)
            let repeated = try await controller.requests(taskID: task.id, after: next)
            #expect(repeated.nextPosition == nil)
        }
    }
    try await records.writerExecutions.prepareWorkspace(
        task.workspaceID, taskID: task.id, delegateID: task.delegateID, agent: "writer")
    try await records.endSeedDelegation(task.delegateID, status: "completed")
    var taskCount = 1
    for count in [19, 20, 21, 40] {
        while taskCount < count {
            let added = try await records.seedDelegation(
                taskID: nil, goal: "Task", input: "Fixture", sourceDialog: nil, agent: "writer")
            try await records.writerExecutions.prepareWorkspace(
                added.workspaceID, taskID: added.id, delegateID: added.delegateID, agent: "writer")
            try await records.endSeedDelegation(added.delegateID, status: "completed")
            taskCount += 1
        }
        let first = try await controller.tasks(before: nil)
        #expect(first.items.count == min(count, 20) && (first.nextID != nil) == (count > 20))
        if let next = first.nextID {
            let second = try await controller.tasks(before: next)
            #expect(second.items.count == count - 20 && second.nextID == nil)
            #expect(Set((first.items + second.items).map(\.id)).count == count)
        }
    }
    try await records.shutdown()
}

@Test @MainActor func writerDelegationAndWorkspaceMessagesHaveImmutableScopes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let records = try SQLiteRepositories(url: root.appendingPathComponent("records.sqlite"))
    let files = ArtifactWorkspace(
        disk: try DiskFileStore(root: root.appendingPathComponent("workspaces")), catalog: records.workspaces)
    let requestID = UUID().uuidString
    try await records.agentMessages.seedAgentRequest(
        id: requestID, requester: "assistant", executor: "writer", goal: "Create", input: "Original input",
        sourceDialog: "source")
    let admission = try await records.writerExecutions.beginRequest(
        delegateID: requestID, taskID: nil, goal: "Create", input: "Original input", sourceDialog: "source",
        agent: "writer")
    #expect(admission.taskID.isEmpty)
    #expect(try await records.writerExecutions.delegationCount() == 1)
    #expect(try await records.writerExecutions.tasks(agent: "writer", before: nil, limit: 20).isEmpty)
    let store = WriterHistoryStore(
        records: try WriterRecordStore(repository: records.writerMessages, logs: records.logs))
    let history = WriterHistory(store: store, taskID: "", delegateID: requestID, goal: "Create")
    let request = try ChatRequest(messages: [.init(role: .user, content: "original")])
    let first = try await history.begin(request, phase: "控制请求")
    try await history.event(.text("selecting"), id: first)
    try await history.event(.finished(.stop), id: first)
    try await history.finish(first)
    let workspace = try await records.writerExecutions.createWorkspace(requestID: requestID, title: "A workspace")
    try await records.writerExecutions.prepareWorkspace(
        workspace.workspaceID, taskID: workspace.id, delegateID: requestID, agent: "writer")
    _ = try await files.publish(
        id: #require(WorkspaceID(rawValue: workspace.workspaceID)), expecting: nil, title: "A workspace",
        draft: ArtifactDraft(files: ["index.html": "<h1>Created</h1>"]))
    let second = try await history.begin(request, phase: "文件内容请求", path: "index.html")
    try await history.event(.text("<h1>Created</h1>"), id: second)
    try await history.event(.finished(.stop), id: second)
    try await history.finish(second)
    let controller = WriterContainer()
    try controller.configureHistory(
        messages: records.writerMessages, tasks: records.writerExecutions, communications: records.agentMessages,
        logs: records.logs)
    let preflight = try await controller.preflight(requestID, after: 0)
    let inside = try await controller.requests(taskID: workspace.id, after: 0)
    #expect(preflight.items.count == 1 && inside.items.count == 1)
    #expect(preflight.items.first?.position ?? 0 < inside.items.first?.position ?? 0)
    #expect(preflight.items.first?.delegateID == requestID && inside.items.first?.delegateID == requestID)
    let detail = try await controller.delegation(requestID)
    #expect(
        detail.input == "Original input" && detail.sourceAgent == "assistant" && detail.workspace?.id == workspace.id)
    try await records.endSeedDelegation(requestID, status: "completed")
    let secondRequest = UUID().uuidString
    try await records.agentMessages.seedAgentRequest(
        id: secondRequest, requester: "assistant", executor: "writer", goal: "Edit", input: "Continue",
        sourceDialog: nil)
    _ = try await records.writerExecutions.beginRequest(
        delegateID: secondRequest, taskID: nil, goal: "Edit", input: "Continue", sourceDialog: nil, agent: "writer")
    _ = try await records.writerExecutions.selectWorkspace(requestID: secondRequest, taskID: workspace.id)
    #expect(try await records.writerExecutions.delegationCount() == 2)
    #expect(try await controller.preflight(requestID, after: 0).items.count == 1)
    #expect(try await controller.requests(taskID: workspace.id, after: 0).items.count == 1)
    let continued = WriterHistory(store: store, taskID: workspace.id, delegateID: secondRequest, goal: "Continue")
    for index in 1...39 {
        let input = try await continued.begin(request, phase: "控制请求")
        try await continued.event(.text("Workspace message \(index)"), id: input)
        try await continued.finish(input)
    }
    let firstPage = try await controller.requests(taskID: workspace.id, after: 0)
    let secondPage = try await controller.requests(taskID: workspace.id, after: #require(firstPage.nextPosition))
    #expect(firstPage.items.count == 20 && secondPage.items.count == 20 && secondPage.nextPosition == nil)
    #expect(firstPage.items.first?.delegateID == requestID && secondPage.items.last?.delegateID == secondRequest)
    #expect(try await controller.preflight(requestID, after: 0).items.count == 1)
    #expect(try await controller.delegations(before: nil).total == 2)
    try await records.endSeedDelegation(secondRequest, status: "completed")
    for notification in try await records.writerExecutions.pendingTaskNotifications(
        agent: "writer", retirement: false, after: nil, limit: 32)
    {
        try await records.writerExecutions.finishTaskNotification(
            notification.delegateID, agent: "writer", retirement: false, completed: true, failure: nil,
            claimToken: notification.claimToken)
    }
    if let destination = ProcessInfo.processInfo.environment["WRITER_SEPARATION_UI_SEED"] {
        let target = URL(fileURLWithPath: destination)
        let source = try DatabaseQueue(path: root.appendingPathComponent("records.sqlite").path)
        let snapshot = try DatabaseQueue(path: target.appendingPathComponent("records.sqlite").path)
        try source.backup(to: snapshot)
        let journalMode = try await snapshot.writeWithoutTransaction { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode=DELETE")
        }
        #expect(journalMode == "delete")
        try snapshot.close()
        try source.close()
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("workspaces"), to: target.appendingPathComponent("workspaces"))
    }
    try await records.shutdown()
}

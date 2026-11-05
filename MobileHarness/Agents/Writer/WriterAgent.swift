import AgentCore
import Foundation
import FunctionContracts
import ModelKit
import StorageChat
import StorageMedia
import StorageTasks

public actor WriterAgent: Agent {
    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>
    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    private let model: @Sendable () async throws -> ChatModel
    private let streaming: any ArtifactStreaming
    private let history: ConversationHistoryStore?
    private let photos: MediaStore?
    private let tasks: any TaskRepository
    private let island = WriterIslandPresentation()
    private let notifications: WriterNotifications
    private let receipts = CommunicationReceipts()
    private var consumer: GatewayOutputConsumer?
    private var lifecycle = AgentLifecycle.registered
    private var workers: [String: Task<Void, Never>] = [:]
    private var previews: [String: WriterPreview] = [:]
    private var sceneActive = true
    private var updates: [String: [String]] = [:]
    private var inputs: [String: AgentInput] = [:]
    private var requests: [String: Request] = [:]
    private var failures: [String: String] = [:]
    private var models: [String: ChatModel] = [:]
    private var waiting: [String: String] = [:]
    private var suspending: Set<String> = []
    private var cancelling: Set<String> = []
    private struct PendingReport: Sendable {
        let content: AgentTaskContent
        let scope: AgentTaskScope
        let input: AgentInput
    }
    // One latest ordinary progress, one waiting interaction and one immutable in-flight event per run.
    private var pendingReports: [String: [PendingReport]] = [:]
    private var reportWorker: Task<Void, Never>?
    private var deliveringEvent: String?
    private var deliveryFailures: [String: String] = [:]
    private var eventSequences: [String: UInt64] = [:]
    private var lastSteps: [String: String] = [:]
    private var windowIDs: [String: String] = [:]
    private var phases: [String: String] = [:]
    private var acceptingRequest = false
    private var finalizing: Set<String> = []
    private var processed = 0
    private var sequence: UInt64 = 0
    public static let parameters: Set<String> = [
        "workspaceID", "createWorkspace", "title", "subtitle", "entry", "path", "offset", "query", "reference", "start",
        "end",
        "instruction", "summary",
        "line", "limit", "contextReferences", "destination", "savepoint", "oldText", "newText",
    ]
    public static func capabilities() throws -> CapabilityRegistry {
        try CapabilityRegistry(
            tools: [
                .init(
                    alias: "workspace", path: "Artifacts.Workspace.perform",
                    requiredParameters: ["command"], optionalParameters: parameters)
            ],
            internalTools: [
                .init(path: "UI.Island.present", required: ["activityID", "revision", "content"]),
                .init(path: "UI.Island.end", required: ["activityID", "revision"]),
            ])
    }
    public init(
        model: @escaping @Sendable () async throws -> ChatModel, streaming: any ArtifactStreaming,
        history: ConversationHistoryStore? = nil, photos: MediaStore? = nil, tasks: any TaskRepository
    ) throws {
        self.tasks = tasks
        notifications = WriterNotifications(tasks: tasks)
        self.photos = photos
        self.history = history
        self.model = model
        self.streaming = streaming
        let config = try AgentConfigurations.load(named: "Writer")
        descriptor = AgentDescriptor(
            id: .writer, name: "Writer", inputs: Set(config.communication.inputs.map(\.kind)),
            outputs: [.toolCall, .communication, .control], capabilities: try Self.capabilities())
        let pair = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(16))
        outputs = pair.stream
        continuation = pair.continuation
    }
    public func bind(_ consumer: GatewayOutputConsumer) async {
        self.consumer = consumer
        await island.bind { [weak self] operation, parameters, session in
            guard let self else { throw WriterFailure.unavailable }
            try await self.presentIsland(operation, parameters: parameters, sessionID: session)
        }
        await notifications.bind { [weak self] message, scope, retirement in
            guard let self else { throw WriterFailure.unavailable }
            return try await self.sendCompletion(message, scope: scope, retirement: retirement)
        }
    }
    public func start() async throws {
        guard lifecycle == .registered, consumer != nil else { throw WriterFailure.unavailable }
        lifecycle = .running
        await island.start()
        await notifications.resume()
    }
    public func setSceneActive(_ active: Bool) async {
        sceneActive = active
        for preview in Array(previews.values) { await preview.setSceneActive(active) }
    }
    static func initialTitle(goal: String) -> String {
        var text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["请帮我", "帮我", "请", "再", "绘制一份", "绘制一张", "画一张", "创建一份", "生成一份", "制作一个"] {
            if text.hasPrefix(prefix) {
                text.removeFirst(prefix.count)
                text = text.trimmingCharacters(in: .whitespaces)
            }
        }
        var title = String(text.prefix(32))
        while title.utf8.count > 160 { title.removeLast() }
        return title.isEmpty ? "创作文档" : title
    }
    public func pause() async throws {
        guard lifecycle == .running else { return }
        lifecycle = .paused
        suspending.formUnion(workers.keys)
        for worker in workers.values { worker.cancel() }
        for worker in Array(workers.values) { await worker.value }
        reportWorker?.cancel()
        await reportWorker?.value
        await notifications.pause()
        for (id, request) in requests {
            await island.update(delegateID: id, phase: .paused)
            if let stable = request.taskID {
                try await tasks.setDelegationPhase(taskID: stable, delegateID: id, phase: "paused", agent: "writer")
            }
        }
    }
    public func resume() async throws {
        guard lifecycle == .paused else { return }
        lifecycle = .running
        for (id, request) in requests {
            await island.update(delegateID: id, phase: waiting[id] == nil ? .running : .waitingUser)
            if let stable = request.taskID {
                try await tasks.setDelegationPhase(
                    taskID: stable, delegateID: id, phase: waiting[id] == nil ? "running" : "waitingUser",
                    agent: "writer")
            }
        }
        for (id, input) in inputs where workers[id] == nil {
            guard let scope = input.taskScope else { continue }
            if waiting[id] == nil, let request = requests[id] {
                workers[id] = Task { await run(request, input: input, scope: scope) }
            }
        }
        startReports()
        await notifications.resume()
    }
    public func stop() async {
        lifecycle = .stopped
        for worker in workers.values { worker.cancel() }
        for worker in Array(workers.values) { await worker.value }
        for (id, input) in inputs {
            if let scope = input.taskScope {
                do {
                    try await report(
                        "运行已中断，已有草稿保留。", scope: scope, input: input, status: .failed, persistedStatus: "interrupted")
                } catch {
                    failures[id] = String(String(describing: error).prefix(256))
                }
            }
            // Durable terminal facts outlive this root; another start retries only delivery.
        }
        await reportWorker?.value
        for id in Array(inputs.keys) { forget(id) }
        reportWorker?.cancel()
        await reportWorker?.value
        pendingReports.removeAll()
        await island.stop()
        await notifications.stop()
        await receipts.close()
        continuation.finish()
        consumer = nil
    }
    public func status() -> AgentStatus {
        .init(
            lifecycle: lifecycle, queuedInputs: updates.values.reduce(0) { $0 + $1.count }, processedInputs: processed)
    }
    public func observationSnapshot() async -> AgentStateSnapshot {
        let presentationFailure = await island.lastFailure
        let notificationFailure = await notifications.lastFailure
        let id = requests.keys.first
        return .init(
            path: "agents.writer",
            business: [
                "agentID": .text("writer"),
                "activeTasks": .texts(requests.values.compactMap(\.taskID).sorted()),
                "presentationFailure": presentationFailure.map { .text($0) } ?? .unknown,
                "phase": .text(
                    id == nil ? "idle" : lifecycle == .paused ? "paused" : id.flatMap { phases[$0] } ?? "starting"),
                "taskID": id.flatMap { requests[$0]?.taskID }.map { .text($0) } ?? .unknown,

                "goal": id.flatMap { requests[$0]?.goal ?? requests[$0]?.request }.map { .text($0) } ?? .unknown,
                "step": id.flatMap { lastSteps[$0] }.map { .text($0) } ?? .unknown,
                "waitingForInput": .flag(id.flatMap { waiting[$0] } != nil),
            ],
            runtime: [
                "rolePhase": .text(lifecycle.rawValue), "failures": .count(failures.count),
                "lastFailure": failures.values.sorted().last.map { .text($0) } ?? .unknown,
                "pendingReports": .count(pendingReports.values.reduce(0) { $0 + $1.count }),
                "deliveryFailure": (notificationFailure ?? deliveryFailures.values.sorted().last).map { .text($0) }
                    ?? .unknown,
            ])
    }
    public func receive(_ input: AgentInput) async throws {
        if case .toolResult = input.payload { return }
        if case .communicationReceipt(let receipt) = input.payload {
            guard input.metadata.origin == .runtime, receipt.owner.agent == .writer,
                receipt.owner.sessionID == input.sessionID
            else { throw CommunicationError.unauthorized }
            try await receipts.accept(receipt)
            return
        }
        guard case .observation(let message) = input.payload, let signal = message.content(as: AgentTaskSignal.self),
            input.metadata.origin == .agent, input.metadata.source == "assistant", input.metadata.incarnation != nil,
            signal.scope.requester == .assistant, signal.scope.executor == .writer,
            signal.scope.execution == .background, input.taskScope == signal.scope
        else {
            throw CommunicationError.unauthorized
        }
        let id = signal.scope.id
        if signal.kind == .input || signal.kind == .cancel {
            guard inputs[id]?.taskScope == signal.scope else { throw CommunicationError.unauthorized }
        }
        switch signal.kind {
        case .cancel:
            guard let original = inputs[id] else { throw WriterFailure.unavailable }
            if let stable = requests[id]?.taskID {
                try await tasks.setDelegationPhase(taskID: stable, delegateID: id, phase: "cancelling", agent: "writer")
            }
            phases[id] = "cancelling"
            await island.update(delegateID: id, phase: .cancelling, step: "正在停止模型并清理文件操作。")
            cancelling.insert(id)
            if let worker = workers[id] {
                worker.cancel()
            } else {
                workers[id] = Task {
                    do {
                        try await streaming.release(delegateID: id)
                        try await report("创作已取消，草稿已保留。", scope: signal.scope, input: original, status: .cancelled)
                    } catch {
                        failures[id] = String(describing: error)
                        do {
                            try await report(
                                "取消清理失败：" + String(describing: error), scope: signal.scope, input: original,
                                status: .failed)
                        } catch { failures[id] = String(describing: error) }
                    }
                    workers.removeValue(forKey: id)
                    startReports()
                }
            }
        case .input:
            guard !finalizing.contains(id) else { throw CommunicationError.scopeClosed }
            guard requests[id] != nil, !cancelling.contains(id),
                (updates[id]?.count ?? 0) < 8
            else { throw WriterFailure.capacity }
            let content = try AgentTaskContent.decode(signal)
            if let interaction = waiting[id] {
                guard content.interactionID == interaction, var request = requests[id], let original = inputs[id] else {
                    throw CommunicationError.invalidPayload
                }
                request.request += "\nAdditional user input:\n" + content.text
                guard request.request.utf8.count <= 12_000 else { throw WriterFailure.capacity }
                try await tasks.saveInteraction(delegateID: id, interactionID: nil, data: nil)
                requests[id] = request
                waiting.removeValue(forKey: id)
                await island.update(delegateID: id, phase: .running, step: "已收到补充，继续创作。")
                if lifecycle == .running, workers[id] == nil {
                    workers[id] = Task { await run(request, input: original, scope: signal.scope) }
                }
            } else {
                guard content.interactionID == nil else { throw CommunicationError.invalidPayload }
                let pendingBytes = updates[id, default: []].reduce(0) { $0 + $1.utf8.count + 32 }
                guard (requests[id]?.request.utf8.count ?? 0) + pendingBytes + content.text.utf8.count + 32 <= 12_000
                else {
                    throw WriterFailure.capacity
                }
                updates[id, default: []].append(content.text)
            }
        case .request:
            if let original = inputs[id], requests[id] != nil {
                guard original.taskScope == signal.scope,
                    case .observation(let priorMessage) = original.payload,
                    priorMessage.content(as: AgentTaskSignal.self)?.data == signal.data
                else { throw CommunicationError.invalidPayload }
                return
            }
            if let status = try await tasks.delegationStatus(id, agent: "writer"),
                !["requested", "running", "finishing"].contains(status)
            {
                return
            }
            guard lifecycle == .running, !acceptingRequest, requests.isEmpty, requests[id] == nil,
                signal.businessContract == "writer.author"
            else { throw WriterFailure.unavailable }
            acceptingRequest = true
            defer { acceptingRequest = false }
            var request = try JSONDecoder().decode(Request.self, from: signal.data)
            guard request.request.utf8.count <= 12_000 else { throw WriterFailure.capacity }
            let task = try await tasks.beginDelegation(
                delegateID: id, taskID: request.taskID, goal: request.goal ?? signal.goal ?? request.request,
                input: request.request, sourceDialog: nil, agent: "writer")
            request.taskID = task.id
            request.workspaceID = task.workspaceID
            requests[id] = request
            inputs[id] = input
            updates[id] = []
            phases[id] = "starting"
            await island.begin(delegateID: id, goal: request.goal ?? task.goal)
            if lifecycle == .paused {
                phases[id] = "paused"
                try await tasks.setDelegationPhase(taskID: task.id, delegateID: id, phase: "paused", agent: "writer")
                await island.update(delegateID: id, phase: .paused)
                return
            }
            if lifecycle != .running {
                try await report(
                    "Writer stopped during admission; no creative effects ran.", scope: signal.scope, input: input,
                    status: .failed, persistedStatus: "interrupted")
                return
            }
            workers[id] = Task { await run(request, input: input, scope: signal.scope) }
            processed += 1
        default: throw CommunicationError.unsupportedContract
        }
    }
    private struct Request: Decodable {
        var request: String
        let goal: String?
        var taskID: String?
        var workspaceID: String? = nil
        private enum CodingKeys: String, CodingKey { case request, goal, taskID, title, entry }
        let title: String?
        let entry: String?
    }
    private func run(_ request: Request, input: AgentInput, scope: AgentTaskScope) async {
        var request = request
        var failure: (any Error)?
        var result = ""
        let preview = WriterPreview(
            present: { try await self.execute(["command": "preview"], input: input) },
            observed: { text in
                do { try await self.report(text, scope: scope, input: input) } catch {
                    await self.recoveryReportFailed(error, delegateID: scope.id)
                }
            })
        previews[scope.id] = preview
        await preview.setSceneActive(sceneActive)
        let diagnosticCapture = WriterDiagnosticCapture()
        var failureStage = "工作区准备"
        var selectedModel: String?
        do {
            guard let stableTaskID = request.taskID else { throw CommunicationError.invalidPayload }
            let initial = windowIDs[scope.id] == nil
            var start = ["command": initial ? "start" : "resume"]
            var newProject = request.workspaceID == nil
            if let stable = request.taskID {
                let allocation = try await tasks.delegatedTask(stable, agent: "writer")
                let project = allocation.workspaceID
                request.workspaceID = project
                requests[scope.id]?.workspaceID = project
                newProject = !allocation.workspaceReady
                start["createWorkspace"] = allocation.workspaceReady ? "false" : "true"
            }
            start["workspaceID"] = request.workspaceID
            start["title"] =
                request.title ?? (newProject ? Self.initialTitle(goal: request.goal ?? request.request) : nil)
            start["subtitle"] = request.goal ?? request.request
            start["entry"] = request.entry
            let project = try await execute(start, input: input)
            let workspaceHint =
                start["createWorkspace"] == "true"
                ? "\nThis is a NEW EMPTY workspace. Create directly; no initial list/read is needed."
                : "\nResume this workspace; inspect only files relevant to the change."
            if let data = try? JSONDecoder().decode([String: String].self, from: Data(project.utf8)) {
                requests[scope.id]?.workspaceID = data["workspaceID"]
                windowIDs[scope.id] = data["windowID"]
                if let stable = request.taskID, let project = data["workspaceID"] {
                    try await tasks.prepareWorkspace(project, taskID: stable, delegateID: scope.id, agent: "writer")
                }
            }
            try await report(
                initial ? "已打开作品窗口，开始创作。" : "已恢复草稿，继续创作。",
                scope: scope, input: input, kind: initial ? .started : .progress)
            failureStage = "模型配置"
            await island.update(delegateID: scope.id, phase: .running, step: "正在准备创作模型。")
            let acquired: ChatModel
            if let held = models[scope.id] {
                acquired = held
            } else {
                acquired = try await model()
                models[scope.id] = acquired
            }
            selectedModel = acquired.modelName
            let selected = acquired.capability
            guard await selected.supportsToolCalls else { throw WriterFailure.unsupportedModel }
            let tools = try toolPorts(input: input, preview: preview)
            failureStage = "创作执行"
            result = try await WriterWorkflow(
                model: selected,
                history: history.map {
                    WriterHistory(
                        store: $0, taskID: stableTaskID, delegateID: scope.id,
                        goal: (request.goal.map { "Goal: " + $0 + "\nUser input: " } ?? "") + request.request
                            + "\nWorkspace: " + project + workspaceHint, photos: photos, modelName: acquired.modelName)
                }, diagnostics: diagnosticCapture,
                requestProgress: { fact in
                    let text =
                        "第\(fact.number)轮 · \(fact.phase)" + (fact.path.map { " · " + $0 } ?? "")
                        + (fact.attempt > 1 ? " · 重试\(fact.attempt)" : "")
                    await self.updateSubtitle(fact.path.map { "正在编写 · " + $0 } ?? "正在处理创作步骤", input: input)
                    await self.island.update(delegateID: scope.id, phase: .running, step: text + " · 正在处理")
                },
                roundCompleted: { fact, summary in
                    await self.updateSubtitle(summary, input: input)
                    let prefix = fact.map { "截至第\($0.number)次请求 · " } ?? ""
                    do {
                        try await self.report(prefix + summary, scope: scope, input: input, requestProgress: fact)
                    } catch {
                        await self.recoveryReportFailed(error, delegateID: scope.id)
                    }
                }
            ).run(
                goal: (request.goal.map { "Goal: " + $0 + "\nUser input: " } ?? "") + request.request + "\nWorkspace: "
                    + project + workspaceHint,
                scope: scope.id, tools: tools,
                progress: { text in
                    do { try await self.report(text, scope: scope, input: input) } catch {
                        await self.recoveryReportFailed(error, delegateID: scope.id)
                    }
                }, revisions: { await self.takeUpdates(scope.id) })
        } catch { failure = error }
        let subtitle: String
        if let question = failure as? WriterNeedsInput {
            subtitle = "等待补充 · " + question.question
        } else if failure == nil {
            let verification = (try? JSONDecoder().decode([String: String].self, from: Data(result.utf8)))?[
                "verification"]
            subtitle =
                ["deferred", "unavailable", "unverified"].contains(verification ?? "unverified")
                ? "作品已保存，未进行视觉验证" : "作品已保存"
        } else if suspending.contains(scope.id) {
            subtitle = "创作已暂停，草稿保留"
        } else if cancelling.contains(scope.id) {
            subtitle = "已停止生成，草稿保留"
        } else {
            subtitle = "创作遇到异常，草稿保留"
        }
        await Task { await self.updateSubtitle(subtitle, input: input) }.value
        await preview.stop()
        previews.removeValue(forKey: scope.id)
        do { try await Task { [streaming] in try await streaming.release(delegateID: scope.id) }.value } catch {
            if failure == nil { failureStage = "工作区清理" }
            failure = failure.map { WriterCleanupFailure(primary: $0, cleanup: error) } ?? error
        }
        if suspending.remove(scope.id) != nil, !cancelling.contains(scope.id), Task.isCancelled,
            !(failure is WriterCleanupFailure)
        {
            workers.removeValue(forKey: scope.id)
            return
        }
        if let question = failure as? WriterNeedsInput, !cancelling.contains(scope.id) {
            let interaction = UUID().uuidString
            waiting[scope.id] = interaction
            do {
                try await report(question.question, scope: scope, input: input, interactionID: interaction)
                workers.removeValue(forKey: scope.id)
                if waiting[scope.id] == nil, lifecycle == .running, let next = requests[scope.id] {
                    workers[scope.id] = Task { await run(next, input: input, scope: scope) }
                }
                return
            } catch { failure = error }
            if lifecycle == .paused, !cancelling.contains(scope.id) {
                workers.removeValue(forKey: scope.id)
                return
            }
        }
        do {
            let interrupted = lifecycle == .stopped && !cancelling.contains(scope.id)
            let status: AgentTaskSignal.Status =
                failure == nil && !interrupted
                ? .succeeded
                : (cancelling.contains(scope.id) && !(failure is WriterCleanupFailure)) ? .cancelled : .failed
            var details = ["delegateID": scope.id]
            details["taskID"] = request.taskID
            details["model"] = selectedModel
            let requestFailure = await diagnosticCapture.latest
            let diagnostic = failure.map {
                WriterDiagnostics.make($0, stage: failureStage, details: details, request: requestFailure)
            }
            if let diagnostic, status == .failed, !interrupted, let consumer {
                failures[scope.id] = diagnostic.message
                sequence += 1
                let output = OutputEnvelope(
                    source: .writer, context: input.context,
                    output: .control("agent.error: " + diagnostic.message), sequence: sequence,
                    taskScope: scope, failure: WriterDiagnostics.output(diagnostic))
                do { _ = try await consumer.execute(output) } catch {
                    failures[scope.id] = "异常记录递送失败：" + String(describing: error)
                }
            }
            let finalText =
                status == .cancelled
                ? "创作已取消，草稿已保留。"
                : interrupted
                    ? "创作已中断，草稿已保留。"
                    : diagnostic.map { "创作未完成：" + $0.message } ?? result
            try await Task {
                try await self.report(
                    finalText, scope: scope, input: input, status: status, failure: diagnostic,
                    persistedStatus: interrupted ? "interrupted" : nil)
            }.value
        } catch {
            let description = String(String(describing: error).prefix(256))
            failures[scope.id] = "任务收尾失败：" + description
            // Even a persistence/encoding failure must produce a failed delivery rather than
            // leave a permanently busy creative slot with no event to retire it.
            do {
                try await report("任务收尾失败：" + description, scope: scope, input: input, status: .failed)
            } catch {
                failures[scope.id] = "任务失败且无法准备汇报：" + String(String(describing: error).prefix(256))
                await island.update(delegateID: scope.id, phase: .failed, step: failures[scope.id])
                forget(scope.id)
            }
        }
        workers.removeValue(forKey: scope.id)
        if failures.count > 16, let key = failures.keys.sorted().first { failures.removeValue(forKey: key) }
        // Completion persistence and delivery never own the creative slot.
        startReports()
    }
    private func recoveryReportFailed(_ error: any Error, delegateID: String) {
        deliveryFailures[delegateID] = "恢复进度尚未送达：" + String(String(describing: error).prefix(256))
    }
    private func forget(_ id: String) {
        workers.removeValue(forKey: id)
        requests.removeValue(forKey: id)
        deliveryFailures.removeValue(forKey: id)
        inputs.removeValue(forKey: id)
        updates.removeValue(forKey: id)
        models.removeValue(forKey: id)
        waiting.removeValue(forKey: id)
        pendingReports.removeValue(forKey: id)
        windowIDs.removeValue(forKey: id)
        phases.removeValue(forKey: id)
        lastSteps.removeValue(forKey: id)
        eventSequences.removeValue(forKey: id)
        suspending.remove(id)
        cancelling.remove(id)
    }
    private func takeUpdates(_ id: String) -> [String] {
        let value = updates[id] ?? []
        for text in value { requests[id]?.request += "\nAdditional user requirement:\n" + text }
        updates[id] = []
        return value
    }
    private static func parameterDescription(_ key: String) -> String {
        switch key {
        case "command": return "Operation name; use only a declared command."
        case "path": return "Project-relative file path, or directory prefix for list/search. Never an absolute path."
        case "line": return "read only: 1-based decimal line number as a string, e.g. 1."
        case "limit":
            return
                "read with line only: decimal line count 1...100. Offset reads return up to 2500 characters; follow nextOffset."
        case "query": return "search only: nonempty literal query, not a regular expression."
        case "offset": return "Nonnegative decimal string from nextOffset for pagination; never source text."
        case "start", "end":
            return
                "Optional absolute Unicode character offset as a decimal string, within the referenced range. NEVER a selector, anchor, source string or line number. Prefer omitting both and replacing the exact read range."
        case "reference":
            return
                "Fresh read_N reference returned by read for this file. edit replaces exactly that read range, not necessarily the whole file."
        case "oldText": return "replace only: exact nonempty text copied from the fresh read range; must match once."
        case "newText":
            return
                "replace only: exact replacement for oldText. Empty string deletes it. All surrounding bytes are preserved."
        case "instruction":
            return
                "Short change request for the separate content writer; no source code. Specify replacement of only the selected range."
        case "contextReferences": return "Comma-separated fresh read_N references for related files (up to eight)."
        case "destination": return "move only: new project-relative path; read every affected source file first."
        case "savepoint": return "ID returned by savepoint, used by diff/restore."
        case "summary": return "Brief user-language completion summary for finish, or essential question for ask."
        case "entry": return "Project entry path. Usually omit to preserve the existing entry."
        case "workspaceID": return "Host-bound project identity; omit, the runtime supplies it."
        case "title":
            return
                "Concise user-language artifact name, e.g. 软件工程流程图. Supply on the first edit of a NEW project; otherwise preserve unless renaming is requested."
        default: return "Workspace operation parameter."
        }
    }
    private func toolPorts(input: AgentInput, preview: WriterPreview) throws -> WriterTools {
        var properties: [String: Any] = [:]
        for key in Self.parameters.subtracting(["createWorkspace", "subtitle", "workspaceID"]).union(["command"]) {
            properties[key] = ["type": "string", "description": Self.parameterDescription(key)]
        }
        properties["command"] = [
            "type": "string", "description": Self.parameterDescription("command"),
            "enum": [
                "list", "read", "search", "edit", "replace", "remove", "move", "removeTree", "diff", "savepoint",
                "restore",
                "rename", "render", "finish", "ask",
            ],
        ]
        let definition = try ChatToolDefinition(
            declaration: JSONSerialization.data(withJSONObject: [
                "type": "function",
                "function": [
                    "name": "workspace",
                    "description":
                        "Native sandbox workspace, no shell. A new project's first edit should carry a concise title, e.g. 软件工程流程图 or 粒子动画; no separate naming request. rename(title) changes the artifact name (file renames use move); preserve existing names unless requested. list(path?) returns file sizes under a directory; read(path,line?,limit?) returns a bounded range with reference and starting line (or use offset to continue); search(query,path?,offset?) returns literal matches, total and nextOffset. replace(path,reference,oldText,newText) applies an exact short literal patch within the read range; oldText must match once, empty newText deletes it, surrounding bytes are preserved. Prefer replace for small edits. edit(path,instruction,reference?,contextReferences?) streams raw content separately; contextReferences is up to eight comma-separated read IDs for related files; The Writer runtime automatically streams safe previews; do not request extra renders while source is incomplete. Existing files require a fresh reference; edit replaces the referenced range unless start/end character offsets narrow it. move(path,destination) and removeTree(path) require reading all affected files first; remove(path,reference) deletes one file; never delete entry. savepoint returns an ID; diff(savepoint,path?,offset?) returns paged before/after excerpts; restore(savepoint) restores that task-local multi-file draft and entry. Repair links after moves. render executes the assembled draft and returns diagnostics/screenshot; batch related edits before render. finish(summary) publishes after render. ask(summary) suspends for essential missing input. Only replace accepts short exact source text; never send whole files through tool arguments. On readRequired reread the affected file; ambiguous ranges must be narrowed. Read/context/savepoint limits name the actual constraint; correct arguments or reuse a savepoint. Unchanged failed effects are suppressed; read the error and correct the cause within the bounded recovery attempts.",
                    "parameters": [
                        "type": "object", "properties": properties, "required": ["command"],
                        "additionalProperties": false,
                    ],
                ],
            ]))
        guard let delegateID = input.taskScope?.id else { throw CommunicationError.unauthorized }
        return WriterTools(
            definitions: [definition],
            execute: { call in
                let args = try JSONDecoder().decode([String: String].self, from: Data(call.argumentsJSON.utf8))
                if args["command"] == "ask" {
                    guard let question = args["summary"], !question.isEmpty, question.utf8.count <= 2048 else {
                        throw WriterFailure.invalidOutput
                    }
                    return .waiting(question)
                }
                guard
                    [
                        "list", "read", "search", "edit", "replace", "remove", "move", "removeTree", "diff",
                        "savepoint",
                        "restore",
                        "rename", "render", "finish",
                    ].contains(args["command"] ?? "")
                else { throw WriterFailure.invalidOutput }
                if ["render", "finish", "restore"].contains(args["command"] ?? "") {
                    await preview.settle()
                }
                let operation = args["command"] ?? ""
                let captions = [
                    "list": "正在查看工作区", "read": "正在读取文件", "search": "正在查找文件内容",
                    "edit": "正在编写文件", "replace": "正在局部修改", "render": "正在渲染并检查页面",
                    "rename": "正在更新作品名称", "finish": "正在保存作品", "move": "正在整理目录",
                    "remove": "正在删除文件", "restore": "正在恢复草稿",
                ]
                if let caption = captions[operation] {
                    await self.updateSubtitle(caption + (args["path"].map { " · " + $0 } ?? ""), input: input)
                }
                let response =
                    args["command"] == "finish"
                    ? try await self.finalize(args["summary"] ?? "作品已完成", input: input)
                    : try await self.execute(args, input: input)
                if ["replace", "move", "remove", "removeTree", "restore"].contains(
                    args["command"] ?? "")
                {
                    await preview.changed()
                }
                if args["command"] == "edit" {
                    let value = try JSONDecoder().decode([String: String].self, from: Data(response.utf8))
                    guard let id = value["streamID"], let instruction = value["instruction"],
                        let context = value["context"]
                    else { throw WriterFailure.invalidOutput }
                    return .write(streamID: id, instruction: instruction, context: context)
                }
                if args["command"] == "render" {
                    if let bytes = try await self.streaming.snapshot(delegateID: delegateID) {
                        return .visual(response, try ChatImage(id: UUID().uuidString, data: bytes))
                    }
                    return .observation(response + "\nScreenshot unavailable; do not claim visual verification.")
                }
                if args["command"] == "finish" { return .finished(response) }
                return .observation(response)
            },
            append: { [streaming] id, text in
                try await streaming.append(streamID: id, delegateID: delegateID, text: text)
                await preview.changed()
            },
            complete: { [streaming] id in
                let result = try await streaming.complete(streamID: id, delegateID: delegateID)
                await preview.changed()
                return result
            },
            abort: { [streaming] id in
                await preview.settle()
                try await streaming.abort(streamID: id, delegateID: delegateID)
            },
            finalize: { summary in
                await preview.settle()
                return try await self.finalize(summary, input: input)
            },
            refresh: { await preview.flush() })
    }
    private func finalize(_ summary: String, input: AgentInput) async throws -> String {
        guard let id = input.taskScope?.id else { throw CommunicationError.unauthorized }
        guard (updates[id] ?? []).isEmpty else {
            throw WriterToolFailure("Newly accepted requirements must be processed before publication.")
        }
        finalizing.insert(id)
        defer { finalizing.remove(id) }
        do { return try await execute(["command": "finish", "summary": summary], input: input) } catch let error
            as WriterToolFailure
        {
            if error.description.contains("renderRequired") { throw error }
            throw WriterCleanupFailure(
                primary: error, cleanup: WriterToolFailure("Publication outcome uncertain; never replay."))
        }
    }

    private func execute(_ arguments: [String: String], input: AgentInput) async throws -> String {
        guard let consumer else { throw WriterFailure.unavailable }
        let call: ToolCall
        do { call = try descriptor.capabilities.resolveTool("workspace", arguments: arguments) } catch GenerationError
            .invalidParameters
        {
            let unknown = Set(arguments.keys).subtracting(Self.parameters.union(["command"]))
            throw WriterToolFailure(
                "Invalid workspace parameters. Remove undeclared fields: " + unknown.sorted().joined(separator: ", ")
                    + ". Follow the declared schema.",
                context: [
                    "command": arguments["command"] ?? "", "path": arguments["path"] ?? "",
                    "validationCode": "invalidParameters", "executed": "false",
                ])
        }
        sequence += 1
        let output = OutputEnvelope(
            source: .writer, context: input.context, output: .toolCall(call), sequence: sequence,
            taskScope: input.taskScope)
        let result = try await consumer.executeReturning(output)
        if result.isCancellationOnly { throw CancellationError() }
        guard !result.isError, let response = result.tool else {
            var details = ["tool": "Artifacts.Workspace.perform"]
            details["command"] = arguments["command"]
            details["path"] = arguments["path"]
            details["dispatchFailure"] = result.failureCode?.rawValue
            details["toolFailureCode"] = result.tool?.failureCode?.rawValue
            if result.failureCode != nil { details["repairable"] = "false" }
            throw WriterToolFailure(result.failure ?? result.tool?.value ?? "Missing tool response", context: details)
        }
        return response.value
    }
    private func updateSubtitle(_ text: String, input: AgentInput) async {
        guard let run = input.taskScope?.id, windowIDs[run] != nil else { return }
        do { _ = try await execute(["command": "describe", "subtitle": String(text.prefix(160))], input: input) } catch
        { deliveryFailures[run] = "窗口状态尚未更新：" + String(String(describing: error).prefix(256)) }
    }
    private func report(
        _ text: String, scope: AgentTaskScope, input: AgentInput, status: AgentTaskSignal.Status? = nil,
        interactionID: String? = nil, kind: WriterTaskEvent.Kind? = nil,
        failure: WriterFailureDiagnostic? = nil, persistedStatus: String? = nil,
        requestProgress: WriterRequestProgress? = nil
    )
        async throws
    {
        let original: Request?
        if case .observation(let message) = input.payload, let signal = message.content(as: AgentTaskSignal.self) {
            original = try? JSONDecoder().decode(Request.self, from: signal.data)
        } else {
            original = nil
        }
        let taskID = requests[scope.id]?.taskID ?? original?.taskID
        let artifact =
            status == .succeeded ? try? JSONDecoder().decode([String: String].self, from: Data(text.utf8)) : nil
        let savedSummary = artifact?["summary"] ?? text
        let unverified =
            artifact != nil
            && ["deferred", "unavailable", "unverified"].contains(artifact?["verification"] ?? "unverified")
        let summary = unverified ? savedSummary + "\n作品已保存，但未进行页面视觉验证。" : savedSummary
        let display = (taskID.map { "taskID=" + $0 + "\n" } ?? "") + summary
        let eventKind =
            kind
            ?? (status == nil
                ? (interactionID == nil ? .progress : .userInput)
                : status == .succeeded ? .completed : status == .cancelled ? .cancelled : .failed)
        let displayPhase: WriterIslandPresentation.Phase =
            persistedStatus == "interrupted"
            ? .interrupted
            : status == .succeeded
                ? .completed
                : status == .failed
                    ? .failed
                    : status == .cancelled ? .cancelled : interactionID == nil ? .running : .waitingUser
        if status == nil, requestProgress == nil, previews[scope.id] != nil {
            await updateSubtitle(summary, input: input)
        }
        if status == nil { await island.update(delegateID: scope.id, phase: displayPhase, step: summary) }
        let eventSequence = (eventSequences[scope.id] ?? 0) + 1
        eventSequences[scope.id] = eventSequence
        phases[scope.id] = status == .cancelled ? "cancelling" : interactionID == nil ? "running" : "waitingUser"
        lastSteps[scope.id] = String(display.prefix(1000))
        if status == nil, let stable = requests[scope.id]?.taskID {
            try await tasks.setDelegationPhase(
                taskID: stable, delegateID: scope.id, phase: interactionID == nil ? "running" : "waitingUser",
                agent: "writer")
        }
        let event = WriterTaskEvent(
            sequence: eventSequence, kind: eventKind,
            workspaceID: artifact?["workspaceID"] ?? requests[scope.id]?.workspaceID, goal: requests[scope.id]?.goal,
            windowID: windowIDs[scope.id],
            taskID: taskID, delegateID: scope.id, failure: failure, request: requestProgress)
        let content = try AgentTaskContent(
            text: String(display.prefix(1000)),
            stage: status == nil ? (interactionID == nil ? .running : .waitingUser) : .completed,
            interactionID: interactionID, artifactID: artifact?["workspaceID"], writerEvent: event)
        if let status {
            let completion = try WriterTaskCompletion(content.signal(.result, scope: scope, status: status))
            let data = try JSONEncoder().encode(completion)
            // All model/file cleanup has joined. Release creation immediately, before awaiting
            // the independent metadata transaction or any Assistant/Gateway delivery.
            requests.removeValue(forKey: scope.id)
            updates.removeValue(forKey: scope.id)
            waiting.removeValue(forKey: scope.id)
            pendingReports.removeValue(forKey: scope.id)
            models.removeValue(forKey: scope.id)
            inputs.removeValue(forKey: scope.id)
            phases.removeValue(forKey: scope.id)
            try await tasks.completeDelegation(
                TaskNotification(delegateID: scope.id, agent: "writer", eventID: event.eventID, data: data),
                status: persistedStatus ?? (status == .succeeded ? "completed" : status.rawValue),
                failure: status == .failed ? failure.map(WriterDiagnostics.describe) ?? summary : nil)
            await island.update(delegateID: scope.id, phase: displayPhase, step: summary)
            forget(scope.id)
            await notifications.wake()
            return
        }
        if let interactionID {
            try await tasks.saveInteraction(
                delegateID: scope.id, interactionID: interactionID, data: JSONEncoder().encode(content))
        }
        let pending = PendingReport(content: content, scope: scope, input: input)
        var queue = pendingReports[scope.id] ?? []
        // Preserve the in-flight identity; replace only unsent facts of the same kind.
        // A waiting question can only be superseded after its matching input resumes Writer.
        queue.removeAll {
            let kind = $0.content.writerEvent?.kind
            let ordinary = [.started, .progress].contains(eventKind)
            return (ordinary ? kind == .started || kind == .progress : kind == eventKind)
                && $0.content.writerEvent?.eventID != deliveringEvent
        }
        queue.append(pending)
        pendingReports[scope.id] = queue
        startReports()
    }
    private func startReports() {
        guard reportWorker == nil, lifecycle != .paused, !pendingReports.isEmpty else { return }
        reportWorker = Task { await pumpReports() }
    }
    private func pumpReports() async {
        defer {
            deliveringEvent = nil
            reportWorker = nil
            if lifecycle == .running { startReports() }
        }
        while !Task.isCancelled, lifecycle != .paused,
            let id = pendingReports.keys.sorted().first, let pending = pendingReports[id]?.first
        {
            deliveringEvent = pending.content.writerEvent?.eventID
            do {
                guard let consumer else { throw WriterFailure.unavailable }
                try await deliver(pending, consumer: consumer)
                pendingReports[id]?.removeAll { $0.content.writerEvent?.eventID == deliveringEvent }
                if pendingReports[id]?.isEmpty == true { pendingReports.removeValue(forKey: id) }
                deliveryFailures.removeValue(forKey: id)
            } catch {
                if Task.isCancelled || lifecycle == .paused { return }
                if pendingReports[id] == nil { continue }
                deliveryFailures[id] = "Writer 汇报尚未送达：" + String(String(describing: error).prefix(256))
                if lifecycle == .stopped {
                    pendingReports.removeValue(forKey: id)
                    continue
                }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }
    private func deliver(_ pending: PendingReport, consumer: GatewayOutputConsumer) async throws {
        let content = pending.content
        let scope = pending.scope
        let evidence = try content.signal(.progress, scope: scope)
        let delivered = try await send(evidence, input: pending.input, consumer: consumer)
        guard delivered.failure == nil, delivered.rejected.isEmpty, delivered.delivered.contains(.assistant) else {
            throw WriterToolFailure(delivered.rejected[.assistant] ?? delivered.failure ?? "Assistant unavailable")
        }
    }
    private func presentIsland(_ operation: String, parameters: [String: String], sessionID: String) async throws {
        guard let consumer else { throw WriterFailure.unavailable }
        let call = ToolCall(id: UUID().uuidString, toolPath: "UI.Island." + operation, arguments: parameters)
        sequence += 1
        let result = try await consumer.executeInternal(
            .init(
                source: .writer, context: ProcessingContext(sessionID: sessionID, source: "writer"),
                output: .toolCall(call), sequence: sequence))
        if result.isCancellationOnly { throw CancellationError() }
        guard !result.isError, result.tool != nil else {
            throw WriterToolFailure(result.failure ?? "Island presentation rejected", context: ["tool": call.toolPath])
        }
    }
    private func sendCompletion(_ message: AgentMessage, scope: AgentTaskScope, retirement: Bool) async throws
        -> DeliveryReport
    {
        guard let consumer else { throw WriterFailure.unavailable }
        let call = try CommunicationAction(message: message, target: .assistant)
        try await receipts.register(call.id)
        do {
            sequence += 1
            let context = ProcessingContext(sessionID: scope.sessionID, source: "writer")
            let result = try await consumer.execute(
                .init(
                    source: .writer, context: context,
                    output: .communication(call), sequence: sequence, taskScope: retirement ? scope : nil))
            guard !result.isError else { throw WriterToolFailure(result.failure ?? "Completion transport failed") }
            return try await receipts.wait(call.id)
        } catch {
            await receipts.cancel(call.id)
            throw error
        }
    }
    private func send(_ signal: AgentTaskSignal, input: AgentInput, consumer: GatewayOutputConsumer) async throws
        -> DeliveryReport
    {
        let call = try CommunicationAction(message: signal.message(), target: .assistant)
        try await receipts.register(call.id)
        do {
            sequence += 1
            let result = try await consumer.execute(
                .init(
                    source: .writer, context: input.context,
                    output: .communication(call), sequence: sequence, taskScope: signal.scope))
            guard !result.isCancellationOnly else { throw CancellationError() }
            guard !result.isError else { throw WriterFailure.unavailable }
            return try await receipts.wait(call.id)
        } catch {
            await receipts.cancel(call.id)
            throw error
        }
    }

}

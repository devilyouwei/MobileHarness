import AgentCore
import Foundation
import FunctionContracts
import ModelKit
import StorageChat
import StorageCore
import StorageTasks

public actor WriterAgent: Agent {
    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>
    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    private let model: @Sendable () async throws -> ChatModel
    private let streaming: any ArtifactStreaming
    private let history: WriterHistoryStore?
    private let communications: any AgentMessageRepository
    private let tasks: any WriterExecutionRepository
    private let startBackground: WriterBackgroundExecution.Start?
    private let island = WriterIslandPresentation()
    private let notifications: WriterNotifications
    private var messaging: AgentMessaging?
    private var consumer: GatewayOutputConsumer?
    private var lifecycle = AgentLifecycle.registered
    private var workers: [String: Task<Void, Never>] = [:]
    private var backgroundRuns: [String: UUID] = [:]
    private var expiredBackgroundRuns: Set<String> = []
    private var backgroundFailure: String?
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
    private var preparedWorkspaces: Set<String> = []
    private var completedLibraryOperations: Set<String> = []
    private var searchMatches: [String: Set<String>] = [:]
    private var workspaceContexts: [String: WriterWorkspaceContext] = [:]
    private var processed = 0
    private var sequence: UInt64 = 0
    private static let workspacePath = "Artifacts.Workspace."
    private static let internalWorkspaceTools = ["start", "resume", "describe", "preview", "publish"]

    public static func capabilities() throws -> CapabilityRegistry {
        let editing = try WriterControlDomain.editing.registry()
        let lifecycle = try AgentConfigurations.registry(
            internalWorkspaceTools.map {
                .init(path: workspacePath + $0, callType: "tool", alias: $0, channel: nil)
            })
        return try CapabilityRegistry(
            tools: editing.tools.filter { !WriterLocalTools.contains($0.path) },
            internalTools: lifecycle.tools.map {
                .init(path: $0.path, required: $0.requiredParameters, optional: $0.optionalParameters)
            } + [
                .init(path: "UI.Island.present", required: ["activityID", "revision", "content"]),
                .init(path: "UI.Island.end", required: ["activityID", "revision"]),
            ])
    }
    public init(
        model: @escaping @Sendable () async throws -> ChatModel, streaming: any ArtifactStreaming,
        history: WriterHistoryStore? = nil, tasks: any WriterExecutionRepository,
        communications: any AgentMessageRepository, startBackground: WriterBackgroundExecution.Start? = nil
    ) throws {
        guard tasks.storageScope == communications.storageScope,
            history.map({ $0.storageScope == tasks.storageScope }) ?? true
        else { throw RecordStorageError.invalidRecord }
        self.tasks = tasks
        self.communications = communications
        self.startBackground = startBackground
        notifications = WriterNotifications(tasks: tasks, communications: communications)
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
    public func bind(_ consumer: GatewayOutputConsumer, messaging: AgentMessaging) async {
        self.consumer = consumer
        self.messaging = messaging
        await island.bind { [weak self] operation, parameters, session in
            guard let self else { throw WriterFailure.unavailable }
            try await self.presentIsland(operation, parameters: parameters, sessionID: session)
        }
        await notifications.bind(
            sender: { [weak self] completion in
                guard let self else { throw WriterFailure.unavailable }
                return try await self.sendCompletion(completion)
            }, retire: consumer.retireTask)
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
    public func pause() async throws {
        guard lifecycle == .running else { return }
        lifecycle = .paused
        let selected = workers
        suspending.formUnion(selected.keys)
        for worker in selected.values { worker.cancel() }
        for id in selected.keys { await streaming.revoke(delegateID: id) }
        for worker in selected.values { await worker.value }
        reportWorker?.cancel()
        await reportWorker?.value
        await notifications.pause()
        for (id, request) in requests {
            await island.update(delegateID: id, phase: .paused)
            if requests[id] != nil {
                try await tasks.updateRequestPhase(requestID: id, phase: "paused")
            }
        }
    }
    public func resume() async throws {
        guard lifecycle == .paused else { return }
        lifecycle = .running
        for (id, request) in requests {
            await island.update(delegateID: id, phase: waiting[id] == nil ? .running : .waitingUser)
            if requests[id] != nil {
                try await tasks.updateRequestPhase(
                    requestID: id, phase: waiting[id] == nil ? "running" : "waitingUser")
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
        let selected = workers
        for worker in selected.values { worker.cancel() }
        for id in selected.keys { await streaming.revoke(delegateID: id) }
        for worker in selected.values { await worker.value }
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
        messaging = nil
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
                "backgroundFailure": backgroundFailure.map { .text($0) } ?? .unknown,
                "deliveryFailure": (notificationFailure ?? deliveryFailures.values.sorted().last).map { .text($0) }
                    ?? .unknown,
            ])
    }
    public func receive(_ input: AgentInput) async throws {
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
            guard
                try await tasks.acceptWriterInput(
                    input.id, requestID: id, text: try AgentTaskContent.decode(signal).text, questionID: nil)
            else { return }
            if requests[id] != nil {
                try await tasks.updateRequestPhase(requestID: id, phase: "cancelling")
            }
            phases[id] = "cancelling"
            await island.update(delegateID: id, phase: .cancelling, step: "正在停止模型并清理文件操作。")
            cancelling.insert(id)
            let worker = workers[id]
            worker?.cancel()
            await streaming.revoke(delegateID: id)
            if worker == nil {
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
                guard
                    try await tasks.acceptWriterInput(
                        input.id, requestID: id, text: content.text, questionID: interaction)
                else { return }
                try await tasks.saveInteraction(delegateID: id, interactionID: nil, data: nil)
                requests[id] = request
                waiting.removeValue(forKey: id)
                await island.update(delegateID: id, phase: .running, step: "已收到补充，继续创作。")
                if lifecycle == .running, workers[id] == nil {
                    workers[id] = Task { await run(request, input: original, scope: signal.scope, userInitiated: true) }
                }
            } else {
                guard content.interactionID == nil else { throw CommunicationError.invalidPayload }
                let pendingBytes = updates[id, default: []].reduce(0) { $0 + $1.utf8.count + 32 }
                guard (requests[id]?.request.utf8.count ?? 0) + pendingBytes + content.text.utf8.count + 32 <= 12_000
                else {
                    throw WriterFailure.capacity
                }
                guard try await tasks.acceptWriterInput(input.id, requestID: id, text: content.text, questionID: nil)
                else { return }
                updates[id, default: []].append(content.text)
                await island.update(delegateID: id, phase: .running, step: "已收到补充，将在下一个编辑步骤处理。")
            }
        case .request:
            if let original = inputs[id], requests[id] != nil {
                guard original.taskScope == signal.scope,
                    case .observation(let priorMessage) = original.payload,
                    priorMessage.content(as: AgentTaskSignal.self)?.data == signal.data
                else { throw CommunicationError.invalidPayload }
                return
            }
            if let status = try await tasks.requestStatus(id, agent: "writer"),
                !["requested", "running", "finishing"].contains(status)
            {
                return
            }
            guard lifecycle == .running, !acceptingRequest, requests[id] == nil
            else {
                try await communications.rejectDelegation(id, failure: "Writer unavailable or busy")
                throw WriterFailure.unavailable
            }
            acceptingRequest = true
            defer { acceptingRequest = false }
            var request = try JSONDecoder().decode(Request.self, from: signal.data)
            guard request.taskID == nil, request.workspaceID == nil, request.request.utf8.count <= 12_000,
                !request.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw WriterFailure.capacity
            }
            let task = try await tasks.beginRequest(
                delegateID: id, taskID: nil,
                goal: request.goal ?? signal.goal ?? request.request,
                input: request.request, sourceDialog: nil, agent: "writer")
            guard task.status == "running" else {
                try await communications.rejectDelegation(id, failure: "Writer unavailable or busy")
                throw WriterFailure.unavailable
            }
            request.goal = request.goal ?? signal.goal
            requests[id] = request
            inputs[id] = input
            updates[id] = []
            phases[id] = "starting"
            await island.begin(delegateID: id, goal: request.goal ?? task.goal)
            if lifecycle == .paused {
                phases[id] = "paused"
                try await tasks.updateRequestPhase(requestID: id, phase: "paused")
                await island.update(delegateID: id, phase: .paused)
                return
            }
            if lifecycle != .running {
                try await report(
                    "Writer stopped during admission; no creative effects ran.", scope: signal.scope, input: input,
                    status: .failed, persistedStatus: "interrupted")
                return
            }
            workers[id] = Task { await run(request, input: input, scope: signal.scope, userInitiated: true) }
            processed += 1
        default: throw CommunicationError.unsupportedContract
        }
    }
    private struct Request: Decodable {
        var request: String
        var goal: String?
        var taskID: String?
        var workspaceID: String? = nil
        private enum CodingKeys: String, CodingKey { case request, goal, taskID, workspaceID }
    }
    private func beginBackground(for id: String) async -> WriterBackgroundExecution? {
        guard lifecycle == .running, sceneActive, !Task.isCancelled, let startBackground else { return nil }
        let token = UUID()
        backgroundRuns[id] = token
        backgroundFailure = nil
        return await startBackground(
            { [weak self] in await self?.expireBackground(id, token: token) },
            { [weak self] failure in await self?.recordBackgroundFailure(failure, id: id, token: token) })
    }
    private func recordBackgroundFailure(_ failure: String, id: String, token: UUID) {
        guard backgroundRuns[id] == token else { return }
        backgroundFailure = String(failure.prefix(256))
    }
    private func expireBackground(_ id: String, token: UUID) async {
        guard lifecycle == .running, backgroundRuns[id] == token, let worker = workers[id],
            !finalizing.contains(id), !cancelling.contains(id), !suspending.contains(id),
            expiredBackgroundRuns.insert(id).inserted
        else { return }
        worker.cancel()
        await streaming.revoke(delegateID: id)
    }
    private func run(_ request: Request, input: AgentInput, scope: AgentTaskScope, userInitiated: Bool = false) async {
        let background = userInitiated ? await beginBackground(for: scope.id) : nil
        var request = request
        var failure: (any Error)?
        var result = ""
        let preview = WriterPreview(
            present: { try await self.execute("preview", input: input) },
            observed: { text in await self.updateProgress(text, input: input) })
        previews[scope.id] = preview
        await preview.setSceneActive(sceneActive)
        let diagnosticCapture = WriterDiagnosticCapture()
        var failureStage = "工作区准备"
        var selectedModel: String?
        do {
            try Task.checkCancellation()
            let stableTaskID = request.taskID ?? ""
            let goal = (request.goal.map { "Goal: " + $0 + "\nUser input: " } ?? "") + request.request
            if eventSequences[scope.id] == nil {
                try await report("已接收任务，正在处理。", scope: scope, input: input, kind: .started)
            }
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
            if workspaceContexts[scope.id] != nil, let taskID = request.taskID {
                let allocation = try await tasks.task(taskID, agent: "writer")
                _ = try await enterEditing(allocation, input: input, resuming: true)
            }
            let tools = try toolPorts(input: input, preview: preview)
            failureStage = "创作执行"
            result = try await WriterWorkflow(
                model: selected,
                history: history.map {
                    WriterHistory(
                        store: $0, taskID: stableTaskID, delegateID: scope.id,
                        goal: goal, modelName: acquired.modelName,
                        toolPaths: Dictionary(
                            uniqueKeysWithValues: descriptor.capabilities.tools.map { ($0.alias, $0.path) }))
                }, diagnostics: diagnosticCapture,
                requestProgress: { fact in
                    let text =
                        "第\(fact.number)轮 · \(fact.phase)" + (fact.path.map { " · " + $0 } ?? "")
                        + (fact.attempt > 1 ? " · 重试\(fact.attempt)" : "")
                    await self.updateSubtitle(fact.path.map { "正在编写 · " + $0 } ?? "正在处理创作步骤", input: input)
                    await self.island.update(delegateID: scope.id, phase: .running, step: text + " · 正在处理")
                },
                roundCompleted: { fact, summary in
                    await background?.advance()
                    await self.updateSubtitle(summary, input: input)
                    let prefix = fact.map { "截至第\($0.number)次请求 · " } ?? ""
                    await self.updateProgress(prefix + summary, input: input, updateWindow: false)
                }
            ).run(
                goal: goal,
                scope: scope.id, tools: tools,
                progress: { text in await self.updateProgress(text, input: input) },
                revisions: { await self.takeUpdates(scope.id) }, workspace: workspaceContexts[scope.id])
        } catch { failure = error }
        backgroundRuns.removeValue(forKey: scope.id)
        let backgroundExpired = expiredBackgroundRuns.remove(scope.id) != nil
        let outcome = try? JSONDecoder().decode([String: String].self, from: Data(result.utf8))
        let refusal = outcome?["completionKind"] == "declined" ? outcome?["summary"] : nil
        let subtitle: String
        if let refusal {
            subtitle = refusal
        } else if let question = failure as? WriterNeedsInput {
            subtitle = "等待补充 · " + question.question
        } else if failure == nil, !preparedWorkspaces.contains(scope.id) {
            subtitle = "请求已处理，未创建作品"
        } else if failure == nil {
            let verification = (try? JSONDecoder().decode([String: String].self, from: Data(result.utf8)))?[
                "verification"]
            subtitle =
                ["deferred", "unavailable", "unverified"].contains(verification ?? "unverified")
                ? "作品已保存，未进行视觉验证" : "作品已保存"
        } else if backgroundExpired {
            subtitle = "后台执行已中断，草稿保留"
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
        preparedWorkspaces.remove(scope.id)
        if suspending.remove(scope.id) != nil, !cancelling.contains(scope.id), Task.isCancelled,
            !(failure is WriterCleanupFailure)
        {
            await background?.finish(false)
            workers.removeValue(forKey: scope.id)
            return
        }
        if let question = failure as? WriterNeedsInput, !cancelling.contains(scope.id) {
            let interaction = UUID().uuidString
            waiting[scope.id] = interaction
            do {
                try await report(question.question, scope: scope, input: input, interactionID: interaction)
                await background?.finish(true)
                workers.removeValue(forKey: scope.id)
                if waiting[scope.id] == nil, lifecycle == .running, let next = requests[scope.id] {
                    workers[scope.id] = Task { await run(next, input: input, scope: scope, userInitiated: true) }
                }
                return
            } catch { failure = error }
            if lifecycle == .paused, !cancelling.contains(scope.id) {
                await background?.finish(false)
                workers.removeValue(forKey: scope.id)
                return
            }
        }
        var backgroundSucceeded = false
        do {
            let expired = backgroundExpired && Task.isCancelled && failure is CancellationError
            let interrupted = (lifecycle == .stopped || expired) && !cancelling.contains(scope.id)
            let declined = refusal != nil && failure == nil && !interrupted && !cancelling.contains(scope.id)
            let status: AgentTaskSignal.Status =
                failure == nil && !interrupted && refusal == nil
                ? .succeeded
                : (cancelling.contains(scope.id) && !(failure is WriterCleanupFailure)) ? .cancelled : .failed
            var details = ["delegateID": scope.id]
            details["taskID"] = requests[scope.id]?.taskID ?? request.taskID
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
                : interrupted && expired
                    ? "系统已结束 Writer 的后台执行，已有草稿保留。"
                    : interrupted
                        ? "创作已中断，草稿已保留。"
                        : diagnostic.map { "创作未完成：" + $0.message } ?? refusal ?? result
            try await Task {
                try await self.report(
                    finalText, scope: scope, input: input, status: status, kind: declined ? .declined : nil,
                    failure: diagnostic,
                    persistedStatus: interrupted ? "interrupted" : nil)
            }.value
            backgroundSucceeded = status == .succeeded
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
        await background?.finish(backgroundSucceeded)
        workers.removeValue(forKey: scope.id)
        if failures.count > 16, let key = failures.keys.sorted().first { failures.removeValue(forKey: key) }
        // Completion persistence and delivery never own the creative slot.
        startReports()
    }
    private func forget(_ id: String) {
        preparedWorkspaces.remove(id)
        completedLibraryOperations.remove(id)
        searchMatches.removeValue(forKey: id)
        workspaceContexts.removeValue(forKey: id)
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
    private func toolPorts(input: AgentInput, preview: WriterPreview) throws -> WriterTools {
        let library = try WriterControlDomain.library.registry()
        let editing = try WriterControlDomain.editing.registry()
        let editingTools = try WriterControlDomain.editing.definitions(editing)
        let libraryTools = try WriterControlDomain.library.definitions(library)
        guard let delegateID = input.taskScope?.id else { throw CommunicationError.unauthorized }
        return WriterTools(
            definitions: editingTools,
            execute: { call in
                let args = try JSONDecoder().decode([String: String].self, from: Data(call.argumentsJSON.utf8))
                let inLibrary = await self.workspaceContexts[delegateID] == nil
                let resolved: ToolCall
                do {
                    resolved = try (inLibrary ? library : editing).resolveTool(call.name, arguments: args)
                } catch {
                    throw WriterToolFailure(
                        "Invalid tool or parameters for the current phase. Follow the active tool schema.",
                        context: ["command": call.name, "validationCode": "invalidParameters", "executed": "false"])
                }
                let operation = String(resolved.toolPath.split(separator: ".").last ?? "")
                if operation == "ask" {
                    guard let question = args["question"], !question.isEmpty, question.utf8.count <= 2048 else {
                        throw WriterFailure.invalidOutput
                    }
                    return .waiting(question)
                }
                if ["searchWorkspaces", "enter", "create", "open", "delete"].contains(operation) {
                    return try await self.libraryCall(operation, args: args, input: input, preview: preview)
                }
                if ["render", "finish", "restore"].contains(operation) {
                    await preview.settle()
                }
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
                    operation == "finish"
                    ? try await self.finalize(
                        args["summary"] ?? "",
                        input: input, outcome: args["outcome"] ?? "artifact")
                    : try await self.execute(operation, args: args, input: input)
                if ["replace", "move", "remove", "removeTree", "restore"].contains(
                    operation)
                {
                    await preview.changed()
                }
                if operation == "edit" {
                    let value = try JSONDecoder().decode([String: String].self, from: Data(response.utf8))
                    guard let id = value["streamID"], let instruction = value["instruction"],
                        let context = value["context"]
                    else { throw WriterFailure.invalidOutput }
                    return .write(streamID: id, instruction: instruction, context: context)
                }
                if operation == "render" {
                    if let bytes = try await self.streaming.snapshot(delegateID: delegateID) {
                        return .visual(response, try ChatImage(id: UUID().uuidString, data: bytes))
                    }
                    return .observation(response + "\nScreenshot unavailable; do not claim visual verification.")
                }
                if operation == "finish" { return .finished(response) }
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
            refresh: { await preview.flush() }, library: libraryTools)
    }
    private struct WorkspaceSearchResult: Decodable {
        let matches: [[String: String]]
    }
    private func libraryCall(_ command: String, args: [String: String], input: AgentInput, preview: WriterPreview)
        async throws
        -> WriterToolOutcome
    {
        guard let id = input.taskScope?.id, let request = requests[id] else { throw CommunicationError.unauthorized }
        if command == "searchWorkspaces" {
            let result = try await execute(command, args: args, input: input)
            let page = try JSONDecoder().decode(WorkspaceSearchResult.self, from: Data(result.utf8))
            if args["before"] == nil { searchMatches[id] = [] }
            searchMatches[id, default: []].formUnion(page.matches.compactMap { $0["taskID"] })
            completedLibraryOperations.insert(id)
            return .observation(result)
        }
        guard let matches = searchMatches[id] else {
            throw WriterToolFailure(
                "Search the workspace catalog with a relevant keyword first.",
                context: ["condition": "workspaceSearchRequired"])
        }
        if command == "create" {
            guard let title = args["title"], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                let entry = args["entry"], !entry.isEmpty
            else { throw WriterToolFailure("Supply a title and relative entry file path to create a workspace.") }
            completedLibraryOperations.remove(id)
            let allocation: WriterWorkspaceRecord
            if workspaceContexts[id] != nil, let current = request.taskID {
                allocation = try await tasks.createWorkspace(requestID: id, title: title, replacing: current)
            } else if let reserved = request.taskID {
                allocation = try await tasks.task(reserved, agent: "writer")
            } else {
                allocation = try await tasks.createWorkspace(requestID: id, title: title)
                requests[id]?.taskID = allocation.id
            }
            return try await selectEditing(allocation, input: input, preview: preview, title: title, entry: entry)
        }
        guard let taskID = args["taskID"], matches.contains(taskID) else {
            throw WriterToolFailure(
                "Use an actual taskID returned by workspace search.",
                context: ["condition": "workspaceSearchRequired"])
        }
        if command == "open" || command == "delete" {
            if command == "delete", workspaceContexts[id] != nil, request.taskID == taskID {
                throw WriterToolFailure("Switch to a different workspace before deleting the active work.")
            }
            let result = try await execute(command, args: args, input: input)
            completedLibraryOperations.insert(id)
            if command == "delete" { searchMatches[id]?.remove(taskID) }
            return .observation(result)
        }
        completedLibraryOperations.remove(id)
        let allocation = try await tasks.task(taskID, agent: "writer")
        return try await selectEditing(allocation, input: input, preview: preview)
    }

    private func finalize(_ summary: String, input: AgentInput, outcome: String = "artifact") async throws -> String {
        guard let id = input.taskScope?.id else { throw CommunicationError.unauthorized }
        guard (updates[id] ?? []).isEmpty else {
            throw WriterToolFailure("Newly accepted requirements must be processed before publication.")
        }
        guard ["artifact", "explanation", "declined"].contains(outcome),
            !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw WriterFailure.invalidOutput
        }
        if outcome == "declined" {
            guard workspaceContexts[id] == nil, summary.utf8.count <= 2048 else { throw WriterFailure.invalidOutput }
            return String(
                decoding: try JSONEncoder().encode(["summary": summary, "completionKind": "declined"]),
                as: UTF8.self)
        }
        if outcome == "explanation" {
            guard !preparedWorkspaces.contains(id) else {
                throw WriterToolFailure("Editing has begun; an explanation cannot bypass render and publication.")
            }
            return String(
                decoding: try JSONEncoder().encode([
                    "summary": summary, "completionKind": "explanation", "status": "completed",
                ]), as: UTF8.self)
        }
        if !preparedWorkspaces.contains(id) {
            guard completedLibraryOperations.contains(id) else { throw WriterFailure.incomplete }
            return String(
                decoding: try JSONEncoder().encode([
                    "summary": summary, "libraryResult": "completed", "status": "completed",
                ]), as: UTF8.self)
        }
        finalizing.insert(id)
        defer { finalizing.remove(id) }
        do { return try await execute("publish", args: ["summary": summary], input: input) } catch let error
            as WriterToolFailure
        {
            if error.description.contains("renderRequired") { throw error }
            throw WriterCleanupFailure(
                primary: error, cleanup: WriterToolFailure("Publication outcome uncertain; never replay."))
        }
    }

    private func selectEditing(
        _ target: WriterWorkspaceRecord, input: AgentInput, preview: WriterPreview,
        title: String? = nil, entry: String? = nil
    ) async throws -> WriterToolOutcome {
        guard let id = input.taskScope?.id else { throw CommunicationError.unauthorized }
        guard let previous = workspaceContexts[id], let previousTask = requests[id]?.taskID else {
            return try await enterEditing(target, input: input, resuming: false, title: title, entry: entry)
        }
        if previous.workspaceID == target.workspaceID {
            return .observation(
                "This workspace is already active. Existing read references and savepoints still apply.")
        }
        let priorAllocation = try await tasks.task(previousTask, agent: "writer")
        await preview.resetForWorkspace()
        try await streaming.release(delegateID: id)
        try Task.checkCancellation()
        do {
            return try await enterEditing(target, input: input, resuming: false, title: title, entry: entry)
        } catch {
            let primary = error
            try Task.checkCancellation()
            do {
                try await streaming.release(delegateID: id)
                _ = try await enterEditing(priorAllocation, input: input, resuming: true)
            } catch {
                throw WriterCleanupFailure(primary: primary, cleanup: error)
            }
            throw WriterToolFailure(
                "Switch failed. Previous workspace restored; reread files for fresh references. "
                    + String(describing: primary),
                context: ["command": "enter"])
        }
    }

    private func enterEditing(
        _ allocation: WriterWorkspaceRecord, input: AgentInput, resuming: Bool,
        title: String? = nil, entry: String? = nil
    ) async throws -> WriterToolOutcome {
        guard let id = input.taskScope?.id, let request = requests[id] else { throw CommunicationError.unauthorized }
        var start = [
            "workspaceID": allocation.workspaceID,
            "createWorkspace": allocation.workspaceReady ? "false" : "true",
        ]
        start["title"] = title
        start["entry"] = entry
        start["subtitle"] = request.goal ?? request.request
        let response = try await execute(resuming ? "resume" : "start", args: start, input: input)
        preparedWorkspaces.insert(id)
        let outcome = try await bindWorkspace(allocation, evidence: response, input: input)
        return outcome
    }
    private func bindWorkspace(
        _ allocation: WriterWorkspaceRecord, evidence: String, input: AgentInput
    ) async throws -> WriterToolOutcome {
        guard let scope = input.taskScope else { throw CommunicationError.unauthorized }
        let data = try JSONDecoder().decode([String: String].self, from: Data(evidence.utf8))
        guard data["workspaceID"] == allocation.workspaceID, let title = data["title"], let entry = data["entry"],
            let status = data["presentationStatus"]
        else { throw WriterFailure.invalidOutput }
        let context = WriterWorkspaceContext(
            workspaceID: allocation.workspaceID, title: title, entry: entry, presentationStatus: status)
        let previous = workspaceContexts[scope.id].flatMap { _ in requests[scope.id]?.taskID }
        var result = evidence
        if let previous, previous != allocation.id {
            var details = data
            details["previousTaskID"] = previous
            details["previousWorkspace"] =
                "Previous draft retained. Its read references and savepoints are no longer active."
            result = String(decoding: try JSONEncoder().encode(details), as: UTF8.self)
        }
        let bind: @Sendable () async throws -> Void = { [tasks] in
            if let previous {
                try await tasks.switchWorkspace(requestID: scope.id, from: previous, to: allocation.id)
            } else {
                try await tasks.prepareWorkspace(
                    allocation.workspaceID, taskID: allocation.id, delegateID: scope.id, agent: "writer")
            }
        }
        if previous != allocation.id {
            if let history { try await history.bindingWorkspace(bind) } else { try await bind() }
        }
        requests[scope.id]?.taskID = allocation.id
        requests[scope.id]?.workspaceID = allocation.workspaceID
        workspaceContexts[scope.id] = context
        if let window = data["windowID"], !window.isEmpty {
            windowIDs[scope.id] = window
        } else if previous != allocation.id {
            windowIDs.removeValue(forKey: scope.id)
        }
        let summary =
            windowIDs[scope.id] != nil && ["preview", "observed", "errors"].contains(status)
            ? "已打开作品窗口。" : "已进入工作区。窗口呈现状态：\(status)。"
        await updateProgress(summary, input: input)
        return .entered(context, evidence: result)
    }
    private func execute(_ operation: String, args: [String: String] = [:], input: AgentInput) async throws -> String {
        guard let consumer else { throw WriterFailure.unavailable }
        let path = Self.workspacePath + operation
        let capabilities = descriptor.capabilities
        let call: ToolCall
        if let internalTool = capabilities.internalTools.first(where: { $0.path == path }) {
            call = try internalTool.call(args)
        } else {
            call = try capabilities.resolveTool(operation, arguments: args)
        }
        sequence += 1
        let output = OutputEnvelope(
            source: .writer, context: input.context, output: .toolCall(call), sequence: sequence,
            taskScope: input.taskScope)
        let result = try await consumer.executeReturning(output)
        if result.isCancellationOnly { throw CancellationError() }
        guard !result.isError, let response = result.tool else {
            var details = ["tool": path]
            details["command"] = operation == "publish" ? "finish" : operation
            details["path"] = args["path"]
            details["dispatchFailure"] = result.failureCode?.rawValue
            details["toolFailureCode"] = result.tool?.failureCode?.rawValue
            if result.failureCode != nil { details["repairable"] = "false" }
            throw WriterToolFailure(result.failure ?? result.tool?.value ?? "Missing tool response", context: details)
        }
        return response.value
    }
    private func updateSubtitle(_ text: String, input: AgentInput) async {
        guard let run = input.taskScope?.id, preparedWorkspaces.contains(run) else { return }
        do { _ = try await execute("describe", args: ["subtitle": String(text.prefix(160))], input: input) } catch {
            deliveryFailures[run] = "窗口状态尚未更新：" + String(String(describing: error).prefix(256))
        }
    }
    private func updateProgress(_ text: String, input: AgentInput, updateWindow: Bool = true) async {
        guard let id = input.taskScope?.id, requests[id] != nil, waiting[id] == nil, !cancelling.contains(id)
        else { return }
        lastSteps[id] = String(text.prefix(1000))
        if updateWindow, previews[id] != nil { await updateSubtitle(text, input: input) }
        await island.update(delegateID: id, phase: .running, step: text)
    }

    private func report(
        _ text: String, scope: AgentTaskScope, input: AgentInput, status: AgentTaskSignal.Status? = nil,
        interactionID: String? = nil, kind: WriterTaskEvent.Kind? = nil,
        failure: WriterFailureDiagnostic? = nil, persistedStatus: String? = nil
    )
        async throws
    {
        let execution = try await tasks.request(scope.id, agent: "writer")
        let taskID = execution.taskID.isEmpty ? nil : execution.taskID
        let artifact =
            status == .succeeded ? try? JSONDecoder().decode([String: String].self, from: Data(text.utf8)) : nil
        let savedSummary = artifact?["summary"] ?? text
        let unverified =
            artifact?["workspaceID"] != nil
            && ["deferred", "unavailable", "unverified"].contains(artifact?["verification"] ?? "unverified")
        let summary = unverified ? savedSummary + "\n作品已保存，但未进行页面视觉验证。" : savedSummary
        let display = (taskID.map { "taskID=" + $0 + "\n" } ?? "") + summary
        let eventKind =
            kind
            ?? (status == nil
                ? .userInput
                : status == .succeeded ? .completed : status == .cancelled ? .cancelled : .failed)
        let displayPhase: WriterIslandPresentation.Phase =
            eventKind == .declined
            ? .declined
            : persistedStatus == "interrupted"
                ? .interrupted
                : status == .succeeded
                    ? .completed
                    : status == .failed
                        ? .failed
                        : status == .cancelled ? .cancelled : interactionID == nil ? .running : .waitingUser
        let eventSequence = (eventSequences[scope.id] ?? 0) + 1
        eventSequences[scope.id] = eventSequence
        phases[scope.id] = status == .cancelled ? "cancelling" : interactionID == nil ? "running" : "waitingUser"
        lastSteps[scope.id] = String(display.prefix(1000))
        if status == nil, requests[scope.id] != nil {
            try await tasks.updateRequestPhase(
                requestID: scope.id, phase: interactionID == nil ? "running" : "waitingUser")
        }
        let event = WriterTaskEvent(
            sequence: eventSequence, kind: eventKind,
            workspaceID: artifact?["libraryResult"] != nil || artifact?["completionKind"] == "explanation"
                ? nil : artifact?["workspaceID"] ?? requests[scope.id]?.workspaceID, goal: requests[scope.id]?.goal,
            windowID: windowIDs[scope.id],
            taskID: taskID, delegateID: scope.id, failure: failure)
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
            try await tasks.completeRequest(
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
        if previews[scope.id] != nil { await updateSubtitle(summary, input: input) }
        await island.update(delegateID: scope.id, phase: displayPhase, step: summary)
        let pending = PendingReport(content: content, scope: scope, input: input)
        var queue = pendingReports[scope.id] ?? []
        // Preserve the in-flight identity; replace only unsent facts of the same kind.
        // A waiting question can only be superseded after its matching input resumes Writer.
        queue.removeAll {
            let kind = $0.content.writerEvent?.kind
            return kind == eventKind && $0.content.writerEvent?.eventID != deliveringEvent
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
                try await deliver(pending)
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
    private func deliver(_ pending: PendingReport) async throws {
        guard let messaging else { throw WriterFailure.unavailable }
        let content = pending.content
        let scope = pending.scope
        let evidence = try content.signal(.progress, scope: scope)
        let delivered = try await messaging.sendResult(evidence.message(), parent: pending.input, to: .assistant)
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
    private func sendCompletion(_ completion: WriterTaskCompletion) async throws -> DeliveryReport {
        guard let messaging else { throw WriterFailure.unavailable }
        let message = completion.message
        let parent = AgentInput(
            id: UUID().uuidString, sessionID: completion.signal.scope.sessionID, payload: .observation(message))
        return try await messaging.sendResult(message, parent: parent, to: .assistant)
    }
}

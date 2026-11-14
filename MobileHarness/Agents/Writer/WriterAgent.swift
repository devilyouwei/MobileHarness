import AgentCore
import Foundation
import FunctionContracts
import ModelKit
import StorageChat
import StorageCore
import StorageTasks
import UI

public actor WriterAgent: Agent {
    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>
    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    private let model: @Sendable () async throws -> ChatModel
    private let streaming: any ArtifactStreaming
    private let history: WriterHistoryStore?
    private let communications: any AgentMessageRepository
    private let executions: any WriterExecutionRepository
    private let startBackground: WriterBackgroundExecution.Start?
    private let language: @Sendable () -> String
    private let island: WriterIslandPresentation
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
    private var cancellationAdmissions: [String: Task<Void, Error>] = [:]
    private struct PendingReport: Sendable {
        let content: AgentTaskContent
        let scope: AgentTaskScope
        let input: AgentInput
    }
    // One pending fact per kind plus one immutable in-flight fact. The first draft and retry are emitted once.
    private var pendingReports: [String: [PendingReport]] = [:]
    private var reportWorker: Task<Void, Never>?
    private var deliveringEvent: String?
    private var deliveryFailures: [String: String] = [:]
    private var eventSequences: [String: UInt64] = [:]
    private var reportedMilestones: [String: Set<WriterDelegationEvent.Kind>] = [:]
    private var lastSteps: [String: String] = [:]
    private var windowIDs: [String: String] = [:]
    private var phases: [String: String] = [:]
    private var inbox: [(AgentTaskRequest, AgentInput)] = []
    private var inboxWorker: Task<Void, Never>?
    private var finalizing: Set<String> = []
    private var preparedWorkspaces: Set<String> = []
    private struct CreationKey: Hashable {
        let title: String
        let entry: String
    }
    private struct CreationReservation {
        let workspaceID: String
        var entered = false
    }
    private var creations: [String: [CreationKey: CreationReservation]] = [:]
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
        history: WriterHistoryStore? = nil, executions: any WriterExecutionRepository,
        communications: any AgentMessageRepository, startBackground: WriterBackgroundExecution.Start? = nil,
        language: @escaping @Sendable () -> String = { "en" }
    ) throws {
        guard executions.storageScope == communications.storageScope,
            history.map({ $0.storageScope == executions.storageScope }) ?? true
        else { throw RecordStorageError.invalidRecord }
        self.executions = executions
        self.communications = communications
        self.startBackground = startBackground
        self.language = language
        island = WriterIslandPresentation(language: language)
        notifications = WriterNotifications(executions: executions, communications: communications)
        self.history = history
        self.model = model
        self.streaming = streaming
        let config = try AgentConfigurations.load(named: "Writer")
        descriptor = AgentDescriptor(
            category: config.category,
            id: .writer, name: "Writer", inputs: config.communication.inputKinds,
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
            sender: { [weak self] report in
                guard let self else { throw WriterFailure.unavailable }
                return try await self.sendReport(report)
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
        inboxWorker?.cancel()
        await inboxWorker?.value
        for admission in Array(cancellationAdmissions.values) { _ = await admission.result }
        let selected = workers
        suspending.formUnion(selected.keys)
        for worker in selected.values { worker.cancel() }
        for id in selected.keys { await streaming.revoke(delegateID: id) }
        for worker in selected.values { await worker.value }
        reportWorker?.cancel()
        await reportWorker?.value
        await notifications.pause()
        for (id, _) in requests {
            await island.update(delegateID: id, phase: .paused)
            if requests[id] != nil {
                try await executions.updateRequestPhase(requestID: id, phase: "paused")
            }
        }
    }
    public func resume() async throws {
        guard lifecycle == .paused else { return }
        lifecycle = .running
        for (id, _) in requests {
            await island.update(delegateID: id, phase: waiting[id] == nil ? .running : .waitingUser)
            if requests[id] != nil {
                try await executions.updateRequestPhase(
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
        startInbox()
        await notifications.resume()
    }
    public func stop() async {
        lifecycle = .stopped
        inboxWorker?.cancel()
        await inboxWorker?.value
        for (message, input) in inbox {
            await rejectMessage(message.id, text: "Writer has stopped.", input: input)
        }
        inbox.removeAll()
        for admission in Array(cancellationAdmissions.values) { _ = await admission.result }
        let selected = workers
        for worker in selected.values { worker.cancel() }
        for id in selected.keys { await streaming.revoke(delegateID: id) }
        for worker in selected.values { await worker.value }
        for (id, input) in inputs {
            if let scope = input.taskScope {
                do {
                    try await report(
                        "Writing was interrupted. The draft was kept.", scope: scope, input: input, status: .failed,
                        persistedStatus: "interrupted")
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
        reportedMilestones.removeAll()
        await island.stop()
        await notifications.stop()
        messaging = nil
        continuation.finish()
        consumer = nil
    }
    public func status() -> AgentStatus {
        .init(
            lifecycle: lifecycle, queuedInputs: inbox.count + updates.values.reduce(0) { $0 + $1.count },
            processedInputs: processed)
    }
    public func observationSnapshot() async -> AgentStateSnapshot {
        let presentationFailure = await island.lastFailure
        let notificationFailure = await notifications.lastFailure
        let id = requests.keys.first
        return .init(
            path: "agents.writer",
            business: [
                "agentID": .text("writer"),
                "activeWorkspaces": .texts(requests.values.compactMap(\.workspaceID).sorted()),
                "presentationFailure": presentationFailure.map { .text($0) } ?? .unknown,
                "phase": .text(
                    id == nil ? "idle" : lifecycle == .paused ? "paused" : id.flatMap { phases[$0] } ?? "starting"),
                "workspaceID": id.flatMap { requests[$0]?.workspaceID }.map { .text($0) } ?? .unknown,

                "goal": id.flatMap { requests[$0]?.request }.map { .text($0) } ?? .unknown,
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
        guard case .observation(let message) = input.payload, input.metadata.origin == .agent,
            input.metadata.source == AgentID.assistant.rawValue, input.metadata.incarnation != nil
        else { throw CommunicationError.unauthorized }
        guard let content = message.content(as: AgentTaskRequest.self)
        else { throw CommunicationError.unsupportedContract }
        try await enqueue(content, input: input)
    }

    private func enqueue(_ content: AgentTaskRequest, input: AgentInput) async throws {
        try content.validate()
        guard input.id == content.id, input.taskScope == nil,
            let record = try await communications.agentMessage(input.id),
            record.sender == input.metadata.source, record.receiver == descriptor.id.rawValue,
            record.contract == AgentTaskRequest.contract,
            try JSONDecoder().decode(AgentTaskRequest.self, from: record.payload) == content
        else { throw CommunicationError.unauthorized }
        guard try await !communications.isAgentMessageConsumed(input.id) else { return }
        guard lifecycle == .running || lifecycle == .paused else { throw WriterFailure.unavailable }
        guard !inbox.contains(where: { $0.0.id == content.id }) else { return }
        guard inbox.count < 8 else { throw CommunicationError.capacityExceeded }
        inbox.append((content, input))
        startInbox()
    }

    private func startInbox() {
        guard lifecycle == .running, inboxWorker == nil, !inbox.isEmpty else { return }
        inboxWorker = Task { await drainInbox() }
    }

    private func drainInbox() async {
        defer {
            inboxWorker = nil
            startInbox()
        }
        while lifecycle == .running, !Task.isCancelled, let (content, input) = inbox.first {
            do {
                try await processMessage(content, input: input)
            } catch is CancellationError where lifecycle != .running || Task.isCancelled {
                return
            } catch {
                let text = (error as? WriterToolFailure)?.description ?? "Writer could not process this message."
                await rejectMessage(content.id, text: text, input: input)
            }
            inbox.removeFirst()
        }
    }

    private var presentationCopy: AppLanguage { AppLanguage(preferredLanguage: language()) }

    private func rejectMessage(_ id: String, text: String, input: AgentInput) async {
        do {
            guard try await !communications.isAgentMessageConsumed(id) else { return }
            let report = try AgentTaskResponse(
                rejecting: id, sessionID: input.sessionID, text: presentationCopy.text(text))
            guard let rejection = report.rejection else { throw CommunicationError.invalidPayload }
            try await communications.rejectAgentMessage(
                id, eventID: rejection.eventID, payload: report.message.encodedContent())
            await notifications.wake()
        } catch {
            backgroundFailure = String(describing: error)
        }
    }

    private func processMessage(_ content: AgentTaskRequest, input: AgentInput) async throws {
        guard try await !communications.isAgentMessageConsumed(content.id) else { return }
        let explicitStop = Self.isExplicitStopMessage(content.text)
        if let active = inputs.values.first, let scope = active.taskScope {
            guard scope.sessionID == input.sessionID, let request = requests[scope.id]
            else { throw WriterToolFailure("Writer is working on another assignment.") }
            guard !cancelling.contains(scope.id), cancellationAdmissions[scope.id] == nil,
                !finalizing.contains(scope.id)
            else { throw WriterToolFailure("Writer is finishing the current assignment. Wait for cleanup.") }
            let question = waiting[scope.id]
            let direction: WriterInboxIntent
            if let replyTo = content.replyTo {
                guard replyTo == scope.id, content.interactionID == question
                else { throw WriterToolFailure("That question has closed. Send your request again.") }
            }
            if explicitStop {
                direction = .stop
            } else {
                let held = models[scope.id]
                let selected: ChatModel
                if let held { selected = held } else { selected = try await model() }
                direction = try await WriterWorkflow.inboxIntent(
                    content.text, goal: request.request,
                    question: content.interactionID == nil ? nil : lastSteps[scope.id], model: selected.capability,
                    language: request.language)
            }
            guard direction != .newWork else {
                throw WriterToolFailure("Wait for Writer to finish before starting a new assignment.")
            }
            try Task.checkCancellation()
            guard lifecycle == .running else { throw CancellationError() }
            guard inputs[scope.id]?.taskScope == scope, waiting[scope.id] == question, !finalizing.contains(scope.id)
            else { throw WriterToolFailure("The assignment or question changed. Send the message again.") }
            if direction == .followUp, question != nil, content.interactionID != question {
                throw WriterToolFailure("Wait for Writer’s question before answering.")
            }
            try await communications.associateAgentMessage(content.id, receiver: "writer", replyTo: scope.id)
            if direction == .stop {
                try await acceptCancellation(content.id, scope: scope, reason: content.text)
            } else {
                try await acceptInput(
                    AgentTaskContent(text: content.text, interactionID: question), messageID: content.id, scope: scope)
            }
            return
        }
        guard content.replyTo == nil, !explicitStop
        else { throw WriterToolFailure("This Writer assignment has ended.") }
        guard let consumer else { throw WriterFailure.unavailable }
        let scope = AgentTaskScope(
            id: input.id, requester: .assistant, executor: .writer, sessionID: input.sessionID, execution: .background)
        try Task.checkCancellation()
        guard lifecycle == .running else { throw CancellationError() }
        let release = try await consumer.authorizeReceivedTask(scope, input)
        do {
            try await startRequest(
                Request(request: content.text),
                input: AgentInput(
                    id: input.id, sessionID: input.sessionID, payload: input.payload, metadata: input.metadata,
                    turn: input.turn, taskScope: scope),
                scope: scope)
        } catch {
            await release()
            throw error
        }
    }

    private func acceptInput(_ content: AgentTaskContent, messageID: String, scope: AgentTaskScope) async throws {
        let id = scope.id
        guard !finalizing.contains(id) else { throw CommunicationError.scopeClosed }
        guard content.interactionID == waiting[id] else { throw CommunicationError.invalidPayload }
        guard requests[id] != nil, !cancelling.contains(id), cancellationAdmissions[id] == nil,
            (updates[id]?.count ?? 0) < 8
        else { throw WriterFailure.capacity }
        if let interaction = waiting[id] {
            guard var request = requests[id], let original = inputs[id] else {
                throw CommunicationError.invalidPayload
            }
            request.request +=
                "\n" + (try AgentPrompts.text("Writer/Prompts", "clarification", ["text": content.text]))
            guard request.request.utf8.count <= 12_000 else { throw WriterFailure.capacity }
            guard
                try await executions.acceptWriterInput(
                    messageID, requestID: id, questionID: interaction)
            else { return }
            requests[id] = request
            waiting.removeValue(forKey: id)
            phases[id] = "running"
            if lifecycle == .running, workers[id] == nil {
                workers[id] = Task { await run(request, input: original, scope: scope, userInitiated: true) }
            }
            let event = WriterDelegationEvent(
                sequence: (eventSequences[id] ?? 0) + 1, kind: .inputAccepted, delegateID: id)
            eventSequences[id] = event.sequence
            enqueueReport(
                try AgentTaskContent(
                    text: presentationCopy.text("Got your update. Continuing the project."), writerEvent: event),
                scope: scope, input: original, kind: .inputAccepted)
            await island.update(delegateID: id, phase: .running, step: "Got your update. Continuing the project.")
        } else {
            let pendingBytes = updates[id, default: []].reduce(0) { $0 + $1.utf8.count + 32 }
            guard (requests[id]?.request.utf8.count ?? 0) + pendingBytes + content.text.utf8.count + 32 <= 12_000
            else {
                throw WriterFailure.capacity
            }
            guard
                try await executions.acceptWriterInput(messageID, requestID: id, questionID: nil)
            else { return }
            updates[id, default: []].append(content.text)
            await island.update(
                delegateID: id, phase: .running, step: "Got your update. It will be used in the next editing step.")
        }
    }

    private func startRequest(_ request: Request, input: AgentInput, scope: AgentTaskScope) async throws {
        var request = request
        request.language = AgentPrompts.normalizedLanguage(language())
        let id = scope.id
        guard lifecycle == .running, requests[id] == nil
        else { throw WriterFailure.unavailable }
        guard request.request.utf8.count <= 12_000,
            !request.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw WriterFailure.capacity }
        let goal = request.request
        let delegation = try await executions.beginRequest(
            delegateID: id, workspaceID: nil, goal: goal, input: request.request, sourceDialog: nil, agent: "writer")
        guard delegation.status == "running" else { throw WriterFailure.unavailable }
        requests[id] = request
        inputs[id] = input
        updates[id] = []
        phases[id] = "starting"
        await island.begin(delegateID: id, goal: goal)
        if lifecycle == .paused {
            phases[id] = "paused"
            try await executions.updateRequestPhase(requestID: id, phase: "paused")
            await island.update(delegateID: id, phase: .paused)
            return
        }
        if lifecycle != .running {
            if requests[id] != nil {
                try await report(
                    "Writer stopped during admission; no creative effects ran.", scope: scope, input: input,
                    status: .failed, persistedStatus: "interrupted")
            }
            return
        }
        workers[id] = Task { await run(request, input: input, scope: scope, userInitiated: true) }
        processed += 1
    }

    private static func isExplicitStopMessage(_ text: String) -> Bool {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".。!！")))
            .lowercased()
        switch command {
        case "取消当前创作", "请取消当前创作", "停止当前创作", "请停止当前创作",
            "cancel this assignment", "please cancel this assignment", "stop this assignment":
            return true
        default:
            return false
        }
    }

    private func acceptCancellation(_ messageID: String, scope: AgentTaskScope, reason: String) async throws {
        let id = scope.id
        guard lifecycle != .stopped, let original = inputs[id], requests[id] != nil else {
            throw CommunicationError.scopeClosed
        }
        guard !cancelling.contains(id), cancellationAdmissions[id] == nil else {
            throw CommunicationError.scopeClosed
        }
        let admission = Task {
            let accepted = try await executions.acceptWriterCancellation(messageID, requestID: id, reason: reason)
            if accepted, requests[id] != nil {
                await cancelExecution(scope, original: original)
            }
        }
        cancellationAdmissions[id] = admission
        defer { cancellationAdmissions[id] = nil }
        try await admission.value
    }

    private func cancelExecution(_ scope: AgentTaskScope, original: AgentInput) async {
        let id = scope.id
        cancelling.insert(id)
        phases[id] = "cancelling"
        if let worker = workers[id] {
            worker.cancel()
            await streaming.revoke(delegateID: id)
        } else {
            workers[id] = Task {
                await streaming.revoke(delegateID: id)
                do {
                    try await streaming.release(delegateID: id)
                    try await report(
                        "Writing was cancelled. The draft was kept.", scope: scope, input: original, status: .cancelled)
                } catch {
                    failures[id] = String(describing: error)
                    do {
                        try await report(
                            "Cancellation cleanup failed: " + String(describing: error), scope: scope, input: original,
                            status: .failed)
                    } catch { failures[id] = String(describing: error) }
                }
                workers.removeValue(forKey: id)
                startReports()
            }
        }
        if cancelling.contains(id) {
            await island.update(
                delegateID: id, phase: .cancelling, step: "Stopping the model and closing file operations.")
        }
    }

    private struct Request {
        var request: String
        var workspaceID: String? = nil
        var language = "en"
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
        await AgentPrompts.$language.withValue(request.language) {
            await runInLanguage(request, input: input, scope: scope, userInitiated: userInitiated)
        }
    }

    private func runInLanguage(_ request: Request, input: AgentInput, scope: AgentTaskScope, userInitiated: Bool) async
    {
        let background = userInitiated ? await beginBackground(for: scope.id) : nil
        let request = request
        var failure: (any Error)?
        var result = ""
        let copy = AppLanguage(preferredLanguage: request.language)
        let preview = WriterPreview(
            present: { try await self.execute("preview", input: input) },
            observed: { text in await self.updateProgress(copy.text(text), input: input) })
        previews[scope.id] = preview
        await preview.setSceneActive(sceneActive)
        let diagnosticCapture = WriterDiagnosticCapture()
        var failureStage = "Workspace preparation"
        var selectedModel: String?
        do {
            try Task.checkCancellation()
            let goal = request.request
            if eventSequences[scope.id] == nil {
                try await report("Assignment received. Working on it.", scope: scope, input: input, kind: .started)
            }
            failureStage = "Model setup"
            await island.update(delegateID: scope.id, phase: .running, step: "Preparing the writing model.")
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
            if workspaceContexts[scope.id] != nil, let workspaceID = request.workspaceID {
                let allocation = try await executions.workspace(workspaceID, agent: "writer")
                _ = try await enterEditing(allocation, input: input, resuming: true)
            }
            let tools = try toolPorts(input: input, preview: preview)
            failureStage = "Writing"
            result = try await WriterWorkflow(
                model: selected,
                history: history.map {
                    WriterHistory(
                        store: $0, delegateID: scope.id,
                        goal: goal, modelName: acquired.modelName,
                        toolPaths: Dictionary(
                            uniqueKeysWithValues: descriptor.capabilities.tools.map { ($0.alias, $0.path) }))
                }, diagnostics: diagnosticCapture,
                requestProgress: { fact in
                    let text =
                        copy.format(
                            "Round %@ · %@", String(fact.number), copy.text(WriterRequestNaming.phase(fact.phase)))
                        + (fact.path.map { " · " + $0 } ?? "")
                        + (fact.attempt > 1 ? copy.format(" · Retry %@", String(fact.attempt)) : "")
                    await self.updateSubtitle(
                        fact.path.map { copy.format("Writing · %@", $0) } ?? copy.text("Working on the project"),
                        input: input)
                    await self.island.update(
                        delegateID: scope.id, phase: .running, step: text + copy.text(" · Processing"))
                },
                roundCompleted: { fact, summary in
                    await background?.advance()
                    await self.updateSubtitle(summary, input: input)
                    let prefix = fact.map { copy.format("Through request %@ · ", String($0.number)) } ?? ""
                    await self.updateProgress(prefix + summary, input: input, updateWindow: false)
                },
                milestone: { await self.reportMilestone($0, input: input) }
            ).run(
                goal: goal,
                scope: scope.id, tools: tools,
                progress: { text in await self.updateProgress(text, input: input) },
                revisions: { try await self.takeUpdates(scope.id) }, workspace: workspaceContexts[scope.id])
        } catch { failure = error }
        if let admission = cancellationAdmissions[scope.id] { _ = try? await admission.value }
        if cancelling.contains(scope.id) {
            failure = failure ?? CancellationError()
        }
        backgroundRuns.removeValue(forKey: scope.id)
        let backgroundExpired = expiredBackgroundRuns.remove(scope.id) != nil
        let outcome = try? JSONDecoder().decode([String: String].self, from: Data(result.utf8))
        let refusal = outcome?["completionKind"] == "declined" ? outcome?["summary"] : nil
        let cancellation = outcome?["completionKind"] == "cancelled" ? outcome?["summary"] : nil
        let subtitle: String
        if let cancellation {
            subtitle = cancellation
        } else if let refusal {
            subtitle = refusal
        } else if let question = failure as? WriterNeedsInput {
            subtitle = copy.format("Waiting for input · %@", question.question)
        } else if failure == nil, !preparedWorkspaces.contains(scope.id) {
            subtitle = "Request completed without creating a project"
        } else if failure == nil {
            let verification = (try? JSONDecoder().decode([String: String].self, from: Data(result.utf8)))?[
                "verification"]
            subtitle =
                ["deferred", "unavailable", "unverified"].contains(verification ?? "unverified")
                ? "Project saved without visual verification" : "Project saved"
        } else if backgroundExpired {
            subtitle = "Background work was interrupted. The draft was kept."
        } else if suspending.contains(scope.id) {
            subtitle = "Writing paused. The draft was kept."
        } else if cancelling.contains(scope.id) {
            subtitle = "Generation stopped. The draft was kept."
        } else {
            subtitle = "Writing failed. The draft was kept."
        }
        await Task { await self.updateSubtitle(self.presentationCopy.text(subtitle), input: input) }.value
        await preview.stop()
        previews.removeValue(forKey: scope.id)
        do { try await Task { [streaming] in try await streaming.release(delegateID: scope.id) }.value } catch {
            if failure == nil { failureStage = "Workspace cleanup" }
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
            if let admission = cancellationAdmissions[scope.id] { _ = try? await admission.value }
            let expired = backgroundExpired && Task.isCancelled && failure is CancellationError
            let interrupted = (lifecycle == .stopped || expired) && !cancelling.contains(scope.id)
            let declined = refusal != nil && failure == nil && !interrupted && !cancelling.contains(scope.id)
            let status: AgentTaskSignal.Status =
                (cancelling.contains(scope.id) && !(failure is WriterCleanupFailure))
                    || (cancellation != nil && failure == nil && !interrupted)
                ? .cancelled
                : (failure == nil && !interrupted && refusal == nil ? .succeeded : .failed)
            var details = ["delegateID": scope.id]
            details["workspaceID"] = requests[scope.id]?.workspaceID ?? request.workspaceID
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
                    failures[scope.id] = "Failed to deliver diagnostic: " + String(describing: error)
                }
            }
            let finalText =
                status == .cancelled
                ? cancellation ?? "Writing was cancelled. The draft was kept."
                : interrupted && expired
                    ? "The system ended Writer’s background execution. The draft was kept."
                    : interrupted
                        ? "Writing was interrupted. The draft was kept."
                        : diagnostic.map { _ in "Writer could not complete the project." } ?? refusal ?? result
            try await Task {
                try await self.report(
                    finalText, scope: scope, input: input, status: status, kind: declined ? .declined : nil,
                    failure: diagnostic,
                    persistedStatus: interrupted ? "interrupted" : nil,
                    cancellationReason: status == .cancelled ? cancellation : nil)
            }.value
            backgroundSucceeded = status == .succeeded
        } catch {
            let description = String(String(describing: error).prefix(256))
            failures[scope.id] = "Task finalization failed: " + description
            // Even a persistence/encoding failure must produce a failed delivery rather than
            // leave a permanently busy creative slot with no event to retire it.
            do {
                try await report(
                    "Task finalization failed: " + description, scope: scope, input: input, status: .failed)
            } catch {
                failures[scope.id] =
                    "Task failed and report preparation failed: " + String(String(describing: error).prefix(256))
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
        creations.removeValue(forKey: id)
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
        reportedMilestones.removeValue(forKey: id)
        suspending.remove(id)
        cancelling.remove(id)
    }
    private func takeUpdates(_ id: String) throws -> [String] {
        let value = updates[id] ?? []
        for text in value {
            requests[id]?.request +=
                "\n" + (try AgentPrompts.text("Writer/Prompts", "additionalRequirement", ["text": text]))
        }
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
                        try AgentPrompts.text("Writer/WorkspaceFeedback", "invalidParameters"),
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
                    "list": "Viewing workspace", "read": "Reading files", "search": "Searching file contents",
                    "edit": "Writing file", "replace": "Editing selection", "render": "Rendering and checking page",
                    "rename": "Renaming project", "finish": "Saving project", "move": "Organizing files",
                    "remove": "Deleting file", "restore": "Restoring draft",
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
                    return .write(try JSONDecoder().decode(ArtifactEditPreparation.self, from: Data(response.utf8)))
                }
                if operation == "render" {
                    if let bytes = try await self.streaming.snapshot(delegateID: delegateID) {
                        return .visual(response, try ChatImage(id: UUID().uuidString, data: bytes))
                    }
                    return .observation(response + (try AgentPrompts.text("Writer/WorkspaceFeedback", "noScreenshot")))
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
            searchMatches[id, default: []].formUnion(page.matches.compactMap { $0["workspaceID"] })
            completedLibraryOperations.insert(id)
            return .observation(result)
        }
        if command == "create" {
            return try await createWorkspace(args, request: request, input: input, preview: preview)
        }
        guard let workspaceID = args["workspaceID"], WorkspaceID(rawValue: workspaceID) != nil else {
            throw WriterToolFailure(
                try AgentPrompts.text("Writer/WorkspaceFeedback", "workspaceID"))
        }
        if command == "delete" {
            guard searchMatches[id]?.contains(workspaceID) == true else {
                throw WriterToolFailure(
                    try AgentPrompts.text("Writer/WorkspaceFeedback", "searchBeforeDelete"),
                    context: ["condition": "workspaceSearchRequired"])
            }
            if workspaceContexts[id] != nil, request.workspaceID == workspaceID {
                throw WriterToolFailure(try AgentPrompts.text("Writer/WorkspaceFeedback", "activeDelete"))
            }
        } else {
            let allocation: WriterWorkspaceRecord?
            do {
                allocation = try await executions.workspace(workspaceID, agent: "writer")
            } catch RecordStorageError.missingRecord { allocation = nil }
            guard let allocation, allocation.workspaceReady else {
                throw WriterToolFailure(
                    try AgentPrompts.text("Writer/WorkspaceFeedback", "unavailable", ["workspaceID": workspaceID]),
                    context: ["command": command, "condition": "workspaceUnavailable", "workspaceID": workspaceID])
            }
            if command == "enter" {
                completedLibraryOperations.remove(id)
                return try await selectEditing(allocation, input: input, preview: preview)
            }
        }
        let result = try await execute(command, args: args, input: input)
        completedLibraryOperations.insert(id)
        if command == "delete" { searchMatches[id]?.remove(workspaceID) }
        return .observation(result)
    }

    private func createWorkspace(
        _ args: [String: String], request: Request, input: AgentInput, preview: WriterPreview
    ) async throws -> WriterToolOutcome {
        guard let id = input.taskScope?.id else { throw CommunicationError.unauthorized }
        guard let title = args["title"]?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw WriterToolFailure(try AgentPrompts.text("Writer/WorkspaceFeedback", "emptyTitle"))
        }
        guard let entry = args["entry"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            ArtifactFilePath.isEntry(entry)
        else {
            throw WriterToolFailure(
                try AgentPrompts.text("Writer/WorkspaceFeedback", "invalidEntry"),
                context: ["condition": "invalidEntry"])
        }
        let key = CreationKey(title: title, entry: entry)
        let reservation = creations[id]?[key]
        if let reservation, reservation.entered {
            let next =
                request.workspaceID == reservation.workspaceID
                ? try AgentPrompts.text("Writer/WorkspaceFeedback", "editExisting")
                : try AgentPrompts.text("Writer/WorkspaceFeedback", "enterExisting")
            throw WriterToolFailure(
                try AgentPrompts.text(
                    "Writer/WorkspaceFeedback", "alreadyCreated", ["workspaceID": reservation.workspaceID]) + next,
                context: [
                    "condition": "workspaceAlreadyCreated", "workspaceID": reservation.workspaceID, "entry": entry,
                ])
        }
        completedLibraryOperations.remove(id)
        let allocation: WriterWorkspaceRecord
        if let reservation {
            allocation = try await executions.workspace(reservation.workspaceID, agent: "writer")
        } else if workspaceContexts[id] != nil, let current = request.workspaceID {
            allocation = try await executions.createWorkspace(requestID: id, title: title, replacing: current)
        } else if let reserved = request.workspaceID {
            allocation = try await executions.workspace(reserved, agent: "writer")
        } else {
            allocation = try await executions.createWorkspace(requestID: id, title: title)
            requests[id]?.workspaceID = allocation.id
        }
        creations[id, default: [:]][key] = CreationReservation(workspaceID: allocation.id)
        let outcome = try await selectEditing(allocation, input: input, preview: preview, title: title, entry: entry)
        // A corrected startup may reuse the allocation. Retire all its creation keys together.
        for (attempt, reservation) in creations[id] ?? [:] where reservation.workspaceID == allocation.id {
            creations[id]?[attempt]?.entered = true
        }
        return outcome
    }

    private func finalize(_ summary: String, input: AgentInput, outcome: String = "artifact") async throws -> String {
        guard let id = input.taskScope?.id else { throw CommunicationError.unauthorized }
        if let admission = cancellationAdmissions[id] { _ = try? await admission.value }
        try Task.checkCancellation()
        guard !cancelling.contains(id) else { throw CancellationError() }
        guard (updates[id] ?? []).isEmpty else {
            throw WriterToolFailure(try AgentPrompts.text("Writer/WorkspaceFeedback", "pendingRequirements"))
        }
        guard ["artifact", "explanation", "declined", "cancelled"].contains(outcome),
            !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw WriterFailure.invalidOutput
        }
        if outcome == "declined" || outcome == "cancelled" {
            guard summary.utf8.count <= 2048, outcome == "cancelled" || workspaceContexts[id] == nil else {
                throw WriterFailure.invalidOutput
            }
            return String(
                decoding: try JSONEncoder().encode(["summary": summary, "completionKind": outcome]),
                as: UTF8.self)
        }
        if outcome == "explanation" {
            guard !preparedWorkspaces.contains(id) else {
                throw WriterToolFailure(try AgentPrompts.text("Writer/WorkspaceFeedback", "editedExplanation"))
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
                primary: error,
                cleanup: WriterToolFailure(try AgentPrompts.text("Writer/WorkspaceFeedback", "uncertainPublication")))
        }
    }

    private func selectEditing(
        _ target: WriterWorkspaceRecord, input: AgentInput, preview: WriterPreview,
        title: String? = nil, entry: String? = nil
    ) async throws -> WriterToolOutcome {
        guard let id = input.taskScope?.id else { throw CommunicationError.unauthorized }
        guard let previous = workspaceContexts[id], let previousWorkspaceID = requests[id]?.workspaceID else {
            return try await enterEditing(target, input: input, resuming: false, title: title, entry: entry)
        }
        if previous.workspaceID == target.workspaceID {
            return .observation(
                try AgentPrompts.text("Writer/WorkspaceFeedback", "alreadyActive"))
        }
        let priorAllocation = try await executions.workspace(previousWorkspaceID, agent: "writer")
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
                try AgentPrompts.text("Writer/WorkspaceFeedback", "switchRestored")
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
        start["subtitle"] = request.request
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
            let status = data["presentationStatus"], let entryExists = data["entryExists"].flatMap(Bool.init),
            let entryEmpty = data["entryEmpty"].flatMap(Bool.init)
        else { throw WriterFailure.invalidOutput }
        let context = WriterWorkspaceContext(
            workspaceID: allocation.workspaceID, title: title, entry: entry, entryExists: entryExists,
            entryEmpty: entryEmpty,
            presentationStatus: status)
        let previous = workspaceContexts[scope.id].flatMap { _ in requests[scope.id]?.workspaceID }
        var result = evidence
        if let previous, previous != allocation.id {
            var details = data
            details["previousWorkspaceID"] = previous
            details["previousWorkspace"] =
                try AgentPrompts.text("Writer/WorkspaceFeedback", "previousWorkspace")
            result = String(decoding: try JSONEncoder().encode(details), as: UTF8.self)
        }
        let bind: @Sendable () async throws -> Void = { [executions] in
            if let previous {
                try await executions.switchWorkspace(requestID: scope.id, from: previous, to: allocation.id)
            } else {
                try await executions.prepareWorkspace(
                    workspaceID: allocation.id, delegateID: scope.id, agent: "writer")
            }
        }
        if previous != allocation.id {
            if let history { try await history.bindingWorkspace(bind) } else { try await bind() }
        }
        requests[scope.id]?.workspaceID = allocation.workspaceID
        workspaceContexts[scope.id] = context
        if let window = data["windowID"], !window.isEmpty {
            windowIDs[scope.id] = window
        } else if previous != allocation.id {
            windowIDs.removeValue(forKey: scope.id)
        }
        let summary =
            windowIDs[scope.id] != nil && ["preview", "observed", "errors"].contains(status)
            ? "Project window opened." : "Workspace opened. Window status: \(status)."
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
            guard let alias = capabilities.tools.first(where: { $0.path == path })?.alias else {
                throw WriterFailure.invalidOutput
            }
            call = try capabilities.resolveTool(alias, arguments: args)
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
            let failure = result.failure ?? result.tool?.value ?? "Missing tool response"
            if operation == "read", failure == "missingFile", let scope = input.taskScope,
                let entry = workspaceContexts[scope.id]?.entry, args["path"] == entry
            {
                details["condition"] = "workspaceEntryMissing"
                throw WriterToolFailure(
                    try AgentPrompts.text("Writer/WorkspaceFeedback", "missingEntry", ["entry": entry]),
                    context: details)
            }
            throw WriterToolFailure(failure, context: details)
        }
        return response.value
    }
    private func updateSubtitle(_ text: String, input: AgentInput) async {
        guard let run = input.taskScope?.id, preparedWorkspaces.contains(run) else { return }
        do { _ = try await execute("describe", args: ["subtitle": String(text.prefix(160))], input: input) } catch {
            deliveryFailures[run] = "Window state update pending: " + String(String(describing: error).prefix(256))
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
        interactionID: String? = nil, kind: WriterDelegationEvent.Kind? = nil,
        failure: WriterFailureDiagnostic? = nil, persistedStatus: String? = nil, cancellationReason: String? = nil
    )
        async throws
    {
        let execution = try await executions.request(scope.id, agent: "writer")
        let workspaceID = execution.workspaceID.isEmpty ? nil : execution.workspaceID
        let artifact =
            status == .succeeded ? try? JSONDecoder().decode([String: String].self, from: Data(text.utf8)) : nil
        let savedSummary = artifact?["summary"] ?? presentationCopy.text(text)
        let unverified =
            artifact?["workspaceID"] != nil
            && ["deferred", "unavailable", "unverified"].contains(artifact?["verification"] ?? "unverified")
        let summary =
            unverified
            ? savedSummary + "\n" + presentationCopy.text("The project was saved without visual verification.")
            : savedSummary
        let display = (workspaceID.map { "Workspace " + $0 + "\n" } ?? "") + summary
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
            try await executions.updateRequestPhase(
                requestID: scope.id, phase: interactionID == nil ? "running" : "waitingUser")
        }
        let event = WriterDelegationEvent(
            sequence: eventSequence, kind: eventKind,
            workspaceID: workspaceID, goal: requests[scope.id].map { String($0.request.prefix(240)) },
            windowID: windowIDs[scope.id], delegateID: scope.id, failure: failure)
        let content = try AgentTaskContent(
            text: String(display.prefix(1000)),
            stage: status == nil ? (interactionID == nil ? .running : .waitingUser) : .completed,
            interactionID: interactionID, writerEvent: event)
        if let status {
            let completion = try AgentTaskResponse(content.signal(.result, scope: scope, status: status))
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
            try await executions.completeRequest(
                WriterDelegationNotification(delegateID: scope.id, agent: "writer", eventID: event.eventID, data: data),
                status: persistedStatus ?? (status == .succeeded ? "completed" : status.rawValue),
                failure: status == .failed ? failure.map(WriterDiagnostics.describe) ?? summary : nil,
                cancellationReason: cancellationReason)
            await island.update(delegateID: scope.id, phase: displayPhase, step: summary)
            forget(scope.id)
            await notifications.wake()
            return
        }
        if let interactionID {
            try await executions.saveInteraction(
                delegateID: scope.id, interactionID: interactionID, data: JSONEncoder().encode(content))
        }
        if previews[scope.id] != nil { await updateSubtitle(summary, input: input) }
        await island.update(delegateID: scope.id, phase: displayPhase, step: summary)
        enqueueReport(content, scope: scope, input: input, kind: eventKind)
    }

    private func reportMilestone(_ milestone: WriterMilestone, input: AgentInput) {
        guard let scope = input.taskScope, let request = requests[scope.id],
            waiting[scope.id] == nil, !cancelling.contains(scope.id), !suspending.contains(scope.id)
        else { return }
        let kind: WriterDelegationEvent.Kind
        let text: String
        switch milestone {
        case .draftUpdated:
            kind = .draftUpdated
            text = "The first changes are in the draft. Work continues."
        case .recovering:
            kind = .recovering
            text = "A writing step failed. Retrying."
        case .renderIssue:
            kind = .recovering
            text = "The render check found a problem. Fixing it."
        }
        guard reportedMilestones[scope.id, default: []].insert(kind).inserted else { return }
        let sequence = (eventSequences[scope.id] ?? 0) + 1
        eventSequences[scope.id] = sequence
        let event = WriterDelegationEvent(
            sequence: sequence, kind: kind, workspaceID: workspaceContexts[scope.id]?.workspaceID,
            goal: String(request.request.prefix(240)), windowID: windowIDs[scope.id], delegateID: scope.id)
        do {
            enqueueReport(
                try AgentTaskContent(text: presentationCopy.text(text), writerEvent: event), scope: scope, input: input,
                kind: kind)
        } catch {
            deliveryFailures[scope.id] =
                "Writer report preparation failed: " + String(String(describing: error).prefix(256))
        }
    }

    private func enqueueReport(
        _ content: AgentTaskContent, scope: AgentTaskScope, input: AgentInput, kind: WriterDelegationEvent.Kind
    ) {
        var queue = pendingReports[scope.id] ?? []
        queue.removeAll {
            $0.content.writerEvent?.kind == kind && $0.content.writerEvent?.eventID != deliveringEvent
        }
        queue.append(PendingReport(content: content, scope: scope, input: input))
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
                deliveryFailures[id] =
                    "Writer report delivery pending: " + String(String(describing: error).prefix(256))
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
        let report = try AgentTaskResponse(content.signal(.progress, scope: scope))
        let delivered = try await messaging.sendResult(report.message, parent: pending.input, to: .assistant)
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
    private func sendReport(_ report: AgentTaskResponse) async throws -> DeliveryReport {
        guard let messaging, let sessionID = report.signal?.scope.sessionID ?? report.rejection?.sessionID
        else { throw WriterFailure.unavailable }
        let message = report.message
        let parent = AgentInput(id: UUID().uuidString, sessionID: sessionID, payload: .observation(message))
        return try await messaging.sendResult(message, parent: parent, to: .assistant)
    }
}

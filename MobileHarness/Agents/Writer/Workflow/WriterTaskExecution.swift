import AgentCore
import Foundation
import FunctionContracts
import ModelKit
import StorageChat
import StorageCore
import StorageTasks
import UI

extension WriterAgent {
    func processMessage(_ content: AgentTaskRequest, input: AgentInput) async throws {
        guard try await !communications.isAgentMessageConsumed(content.id) else { return }
        if let active = inputs.values.first, let scope = active.taskScope {
            guard scope.sessionID == input.sessionID, scope.requester.rawValue == input.metadata.source,
                let request = requests[scope.id]
            else { throw WriterToolFailure("Writer is working on another assignment.") }
            guard !cancelling.contains(scope.id), cancellationAdmissions[scope.id] == nil,
                !finalizing.contains(scope.id)
            else { throw WriterToolFailure("Writer is finishing the current assignment. Wait for cleanup.") }
            let question = waiting[scope.id]
            if let replyTo = content.replyTo {
                guard replyTo == scope.id, content.operation == .update || content.interactionID == question
                else { throw WriterToolFailure("That question has closed. Send your request again.") }
            }
            let direction: WriterInboxIntent
            if content.operation == .update || content.operation == .answer {
                direction = .followUp
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
        guard content.replyTo == nil
        else { throw WriterToolFailure("This Writer assignment has ended.") }
        guard let consumer else { throw WriterFailure.unavailable }
        let scope = AgentTaskScope(
            id: input.id, requester: AgentID(rawValue: input.metadata.source), executor: .writer,
            sessionID: input.sessionID, execution: .background)
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
            guard request.request.utf8.count <= WriterBudget.request else { throw WriterFailure.capacity }
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
            let event = AgentTaskEvent(
                sequence: (eventSequences[id] ?? 0) + 1, kind: .inputAccepted)
            eventSequences[id] = event.sequence
            enqueueReport(
                try AgentTaskContent(
                    text: presentationCopy.text("Got your update. Continuing the project."), event: event),
                scope: scope, input: original, kind: .inputAccepted)
            await island.update(delegateID: id, phase: .running, step: "Got your update. Continuing the project.")
        } else {
            let pendingBytes = updates[id, default: []].reduce(0) { $0 + $1.utf8.count + 32 }
            guard
                (requests[id]?.request.utf8.count ?? 0) + pendingBytes + content.text.utf8.count + 32
                    <= WriterBudget.request
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
        guard request.request.utf8.count <= WriterBudget.request,
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

    func acceptCancellation(_ messageID: String, scope: AgentTaskScope, reason: String) async throws {
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

    func cancelExecution(_ scope: AgentTaskScope, original: AgentInput) async {
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
    func run(_ request: Request, input: AgentInput, scope: AgentTaskScope, userInitiated: Bool = false) async {
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
                            "Round %@ · %@", String(fact.number), copy.text(fact.phase))
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
    func forget(_ id: String) {
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
}

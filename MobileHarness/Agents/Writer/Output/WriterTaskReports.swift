import AgentCore
import Foundation
import FunctionContracts
import ModelKit
import StorageChat
import StorageCore
import StorageTasks
import UI

extension WriterAgent {
    /// The rejection is published once; the receiver records it. Writer only closes its own received record.
    func rejectMessage(_ content: AgentTaskRequest, text: String, input: AgentInput) async {
        do {
            guard try await !communications.isAgentMessageConsumed(content.id) else { return }
            try await communications.receiveAgentMessage(content.id, receiver: descriptor.id.rawValue, consumed: true)
            let report = try AgentTaskResponse(
                rejecting: content.id, sessionID: input.sessionID, text: presentationCopy.text(text))
            try await sendReport(report, reference: content.replyTo ?? content.id)
        } catch {
            deliveryFailures[content.id] = String(String(describing: error).prefix(256))
        }
    }

    func updateSubtitle(_ text: String, input: AgentInput) async {
        guard let run = input.taskScope?.id, preparedWorkspaces.contains(run) else { return }
        do { _ = try await execute("describe", args: ["subtitle": String(text.prefix(160))], input: input) } catch {
            deliveryFailures[run] = "Window state update pending: " + String(String(describing: error).prefix(256))
        }
    }
    func updateProgress(_ text: String, input: AgentInput, updateWindow: Bool = true) async {
        guard let id = input.taskScope?.id, requests[id] != nil, waiting[id] == nil, !cancelling.contains(id)
        else { return }
        lastSteps[id] = String(text.prefix(1000))
        if updateWindow, previews[id] != nil { await updateSubtitle(text, input: input) }
        await island.update(delegateID: id, phase: .running, step: text)
    }

    func report(
        _ text: String, scope: AgentTaskScope, input: AgentInput, status: AgentTaskSignal.Status? = nil,
        interactionID: String? = nil, kind: AgentTaskEvent.Kind? = nil,
        failure: AgentTaskFailure? = nil, persistedStatus: String? = nil, cancellationReason: String? = nil
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
        lastSteps[scope.id] = String(summary.prefix(1000))
        let event = AgentTaskEvent(
            sequence: eventSequence, kind: eventKind,
            goal: requests[scope.id].map { String($0.request.prefix(240)) },
            windowID: windowIDs[scope.id], failure: failure)
        let content = try AgentTaskContent(
            text: String(summary.prefix(1000)),
            stage: status == nil ? (interactionID == nil ? .running : .waitingUser) : .completed,
            interactionID: interactionID, artifactID: workspaceID, event: event)
        if let status {
            let signal = try content.signal(.result, scope: scope, status: status)
            let completion = try AgentTaskResponse(signal)
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
                scope.id, eventID: event.eventID, result: data,
                status: persistedStatus ?? (status == .succeeded ? "completed" : status.rawValue),
                failure: status == .failed ? failure.map(WriterDiagnostics.describe) ?? summary : nil,
                cancellationReason: cancellationReason)
            await island.update(delegateID: scope.id, phase: displayPhase, step: summary)
            forget(scope.id)
            // Published once; a missed report is not resent.
            do {
                try await sendReport(completion, reference: scope.id)
            } catch {
                deliveryFailures[scope.id] =
                    "Writer report not delivered: " + String(String(describing: error).prefix(256))
            }
            var retirement: String?
            do {
                guard let consumer else { throw WriterFailure.unavailable }
                try await consumer.retireTask(signal)
            } catch {
                retirement = String(String(describing: error).prefix(1024))
            }
            // Completion is persisted; a failed retirement is recorded, never retried as another completion.
            do { try await executions.retireRequest(scope.id, failure: retirement) } catch {
                failures[scope.id] = "Writer retirement not recorded: " + String(String(describing: error).prefix(256))
            }
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

    func reportMilestone(_ milestone: WriterMilestone, input: AgentInput) {
        guard let scope = input.taskScope, let request = requests[scope.id],
            waiting[scope.id] == nil, !cancelling.contains(scope.id), !suspending.contains(scope.id)
        else { return }
        let kind: AgentTaskEvent.Kind
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
        let event = AgentTaskEvent(
            sequence: sequence, kind: kind, goal: String(request.request.prefix(240)), windowID: windowIDs[scope.id])
        do {
            enqueueReport(
                try AgentTaskContent(
                    text: presentationCopy.text(text), artifactID: workspaceContexts[scope.id]?.workspaceID,
                    event: event),
                scope: scope, input: input, kind: kind)
        } catch {
            deliveryFailures[scope.id] =
                "Writer report preparation failed: " + String(String(describing: error).prefix(256))
        }
    }

    func enqueueReport(
        _ content: AgentTaskContent, scope: AgentTaskScope, input: AgentInput, kind: AgentTaskEvent.Kind
    ) {
        var queue = pendingReports[scope.id] ?? []
        queue.removeAll {
            $0.content.event?.kind == kind && $0.content.event?.eventID != deliveringEvent
        }
        queue.append(PendingReport(content: content, scope: scope, input: input))
        pendingReports[scope.id] = queue
        startReports()
    }

    func startReports() {
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
            deliveringEvent = pending.content.event?.eventID
            do {
                try await deliver(pending)
                deliveryFailures.removeValue(forKey: id)
            } catch {
                if Task.isCancelled || lifecycle == .paused { return }
                // Published once; a missed report is not resent.
                deliveryFailures[id] =
                    "Writer report not delivered: " + String(String(describing: error).prefix(256))
            }
            pendingReports[id]?.removeAll { $0.content.event?.eventID == deliveringEvent }
            if pendingReports[id]?.isEmpty == true { pendingReports.removeValue(forKey: id) }
        }
    }
    func deliver(_ pending: PendingReport) async throws {
        guard let messaging else { throw WriterFailure.unavailable }
        let content = pending.content
        let scope = pending.scope
        let report = try AgentTaskResponse(content.signal(.progress, scope: scope))
        try await messaging.publish(report.message, parent: pending.input)
    }
    func presentIsland(_ operation: String, parameters: [String: String], sessionID: String) async throws {
        guard let consumer else { throw WriterFailure.unavailable }
        let call = ToolCall(id: UUID().uuidString, toolPath: "UI.Island." + operation, arguments: parameters)
        sequence += 1
        let result = try await consumer.callInternalTool(
            .init(
                source: .writer, context: ProcessingContext(sessionID: sessionID, source: "writer"),
                output: .toolCall(call), sequence: sequence))
        if result.isCancellationOnly { throw CancellationError() }
        guard !result.isError, result.tool != nil else {
            throw WriterToolFailure(result.failure ?? "Island presentation rejected", context: ["tool": call.toolPath])
        }
    }
    private func sendReport(_ report: AgentTaskResponse, reference: String) async throws {
        guard let messaging, let sessionID = report.signal?.scope.sessionID ?? report.rejection?.sessionID
        else { throw WriterFailure.unavailable }
        let parent = AgentInput(
            id: report.signal?.scope.id ?? report.rejection?.messageID ?? UUID().uuidString, sessionID: sessionID,
            payload: .observation(report.message))
        try await messaging.publish(report.publication(scope: reference), parent: parent)
    }
}

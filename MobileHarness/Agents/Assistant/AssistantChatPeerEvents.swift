import AgentCore
import Foundation
import ModelKit
import OSLog
import StorageChat
import StorageCore
import StorageTasks
import UI

extension AssistantChatWorker {
    func receivePeerEvent(
        _ signal: AgentTaskSignal, content: AgentTaskContent, event: AgentTaskEvent, input: AgentInput
    ) async throws {
        let snapshot = try await contextRepository.snapshot()
        let prior = snapshot.state.taskViews?[signal.scope.id]
        if let prior, prior.scope != signal.scope { throw CommunicationError.scopeClosed }
        if prior?.terminal == true || (prior?.stage == .waitingUser && event.kind.isMilestone)
            || prior?.event?.eventID == event.eventID
            || event.sequence <= (prior?.event?.sequence ?? 0)
        {
            return
        }
        let origin = trackedTasks[signal.scope.id]?.originDialog
        try await contextRepository.recordSignal(
            input, disposition: .control, admissionSequence: snapshot.revision + 1, consumed: true,
            retainingLast: 4096
        ) { context in
            let prior = context.state.taskViews?[signal.scope.id]
            if let prior, prior.scope != signal.scope { throw CommunicationError.scopeClosed }
            if prior?.terminal == true || (prior?.stage == .waitingUser && event.kind.isMilestone)
                || prior?.event?.eventID == event.eventID
                || event.sequence <= (prior?.event?.sequence ?? 0)
            {
                return
            }
            if context.state.taskViews?.count == 256, prior == nil {
                guard let retired = context.state.taskViews?.first(where: { $0.value.terminal })?.key
                else { throw CommunicationError.capacityExceeded }
                context.state.taskViews?[retired] = nil
            }
            var view = AgentTaskView(scope: signal.scope, content: content)
            view.goal = event.goal ?? prior?.goal
            view.originDialog = prior?.originDialog ?? origin
            view.createdAt = prior?.createdAt ?? Date()
            if event.kind == .inputAccepted {
                view.facts = prior?.facts
            } else {
                view.retainFacts(from: prior)
            }
            if context.state.taskViews == nil { context.state.taskViews = [:] }
            context.state.taskViews?[signal.scope.id] = view
        }
        if event.kind != .inputAccepted,
            let view = (try await contextRepository.snapshot()).state.taskViews?[signal.scope.id],
            view.event?.eventID == event.eventID
        {
            try await enqueuePeerTaskNotice(view, input: input)
        }
    }

    func receivePeerCompletion(
        signal: AgentTaskSignal, content: AgentTaskContent, event: AgentTaskEvent, input: AgentInput
    ) async throws {
        let origin = trackedTasks[signal.scope.id]?.originDialog
        let snapshot = try await contextRepository.snapshot()
        if snapshot.state.taskViews?[signal.scope.id]?.event?.eventID == event.eventID { return }
        let evidence = AgentInput(
            id: event.eventID, sessionID: input.sessionID, payload: input.payload, metadata: input.metadata)
        try await contextRepository.recordSignal(
            evidence, disposition: .control, admissionSequence: snapshot.revision + 1,
            consumed: true, retainingLast: 4096
        ) { context in
            if context.state.taskViews?.count == 256,
                context.state.taskViews?[signal.scope.id] == nil,
                let retired = context.state.taskViews?.first(where: { $0.value.terminal })?.key
            {
                context.state.taskViews?[retired] = nil
            }
            guard (context.state.taskViews?.count ?? 0) < 256 || context.state.taskViews?[signal.scope.id] != nil else {
                throw CommunicationError.capacityExceeded
            }
            let prior = context.state.taskViews?[signal.scope.id]
            var view = AgentTaskView(scope: signal.scope, content: content, terminal: true)
            view.goal = event.goal ?? prior?.goal
            view.originDialog = prior?.originDialog ?? origin
            view.createdAt = prior?.createdAt ?? Date()
            view.retainFacts(from: prior)
            context.state.taskViews = context.state.taskViews ?? [:]
            context.state.taskViews?[signal.scope.id] = view
            if let state = context.tasks.task(signal.scope.id)?.state,
                ![.succeeded, .failed, .cancelled, .interrupted].contains(state)
            {
                try context.tasks.report(signal, agent: signal.scope.executor)
            }
        }
        if let view = (try await contextRepository.snapshot()).state.taskViews?[signal.scope.id] {
            try await enqueuePeerTaskNotice(view, input: input)
        }
    }

    static func peerTaskFacts(
        from views: [String: AgentTaskView], dialog: String, budget: Int, templates: PromptTemplates
    ) throws -> String {
        let recent = views.values.filter { $0.originDialog == dialog && $0.facts?.isEmpty == false }
            .sorted {
                ($0.facts?.last?.receivedAt ?? .distantPast) > ($1.facts?.last?.receivedAt ?? .distantPast)
            }
            .prefix(2)
        guard !recent.isEmpty else { return "" }
        let heading = try templates.render("taskEventsHeading")
        var block = heading
        for view in recent {
            var entries = view.facts?.map { ["event": $0.kind.rawValue, "text": $0.text] } ?? []
            let fact = [
                "agent": view.scope.executor.rawValue,
                "artifactID": view.artifactID ?? "",
                "goal": String((view.goal ?? view.event?.goal ?? "").prefix(120)),
            ]
            let header = String(decoding: try JSONEncoder().encode(fact), as: UTF8.self)
            while !entries.isEmpty {
                let events = String(decoding: try JSONEncoder().encode(entries), as: UTF8.self)
                let line = try templates.render("taskEvent", variables: ["task": header, "events": events])
                if block.utf8.count + line.utf8.count <= budget {
                    block += line
                    break
                }
                entries.removeFirst()
            }
        }
        return block == heading ? "" : block
    }

    func enqueuePeerTaskNotice(_ view: AgentTaskView, input: AgentInput) async throws {
        if fullDuplex {
            guard view.originDialog == (try await contextRepository.snapshot()).state.history.current.id else { return }
            try await admitPeerText(
                view.text, input: input)
            return
        }
        guard let event = view.event, let originDialog = view.originDialog else { return }
        try await recordPeerTurn(id: event.eventID, text: view.text, originDialog: originDialog)
        guard presentsReply else { return }
        if view.terminal {
            peerNotices.removeAll {
                $0.scopeID == view.scope.id && ($0.kind?.isMilestone == true || $0.kind == .userInput)
            }
        }
        let anchor = AgentInput(
            id: event.eventID, sessionID: input.sessionID, payload: input.payload, metadata: input.metadata)
        enqueuePeerTaskNotice(
            PeerTaskNotice(
                input: anchor, scopeID: view.scope.id, originDialog: originDialog, kind: event.kind,
                interactionID: view.interactionID, text: try Self.peerNoticeText(view.text, from: view.scope.executor)))
    }

    static func peerNoticeText(_ text: String, from agent: AgentID) throws -> String {
        try AgentPrompts.load(named: State.configurationName).render(
            "taskNotice", variables: ["agent": agent.rawValue, "text": String(text.prefix(180))])
    }

    /// Half duplex has no semantic admission, so the peer report is written to the conversation directly.
    func recordPeerTurn(id: String, text: String, originDialog: String) async throws {
        guard originDialog == (try await contextRepository.snapshot()).state.history.current.id,
            try await !conversations.containsInput(id)
        else { return }
        _ = try await conversations.admitUserInput(id: id, user: String(text.prefix(16_384)), model: "")
        try await conversations.finish(id, state: .completed)
    }

    func enqueuePeerTaskNotice(_ notice: PeerTaskNotice) {
        if peerNotices.count == 8 {
            let index = peerNotices.firstIndex(where: { $0.kind?.isMilestone == true }) ?? peerNotices.startIndex
            peerNotices.remove(at: index)
            Logger(subsystem: "dev.mobileharness", category: "PeerTaskNotice").warning(
                "Assistant Writer notice queue full")
        }
        peerNotices.append(notice)
        drain()
    }

    func playPeerTaskNotice(_ notice: PeerTaskNotice) async {
        let input = notice.input
        defer {
            activePeerTaskNoticeID = nil
            activeInput = nil
            worker = nil
            finishHostCancellation(input)
            drain()
        }
        do {
            let snapshot = try await contextRepository.snapshot()
            try Task.checkCancellation()
            guard lifecycle == .running, snapshot.state.history.current.id == notice.originDialog else { return }
            if notice.kind == .userInput || notice.kind?.isMilestone == true {
                let view = snapshot.state.taskViews?[notice.scopeID]
                guard view?.terminal == false else { return }
                if notice.kind == .userInput, view?.interactionID != notice.interactionID { return }
            }
            replyInputs.insert(input.id)
            try await emitPlayback(notice.text, for: input)
            emit(.control("agent.finished"), for: input)
        } catch is CancellationError {
            if hostCancelledInput?.id != input.id { emit(.control("agent.cancelled"), for: input) }
        } catch {
            emitFailure(error, for: input)
        }
    }
}

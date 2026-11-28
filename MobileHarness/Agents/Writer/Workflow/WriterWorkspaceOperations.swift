import AgentCore
import Foundation
import FunctionContracts
import ModelKit
import StorageChat
import StorageCore
import StorageTasks
import UI

extension WriterAgent {
    func toolPorts(input: AgentInput, preview: WriterPreview) throws -> WriterTools {
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
                if WriterToolGroup.fileMutations.contains(operation) {
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

    func enterEditing(
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
}

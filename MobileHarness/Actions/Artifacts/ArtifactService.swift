import Foundation
import FunctionContracts
import StorageCore

public protocol ArtifactCapability: Sendable {
    func perform(invocation: any FunctionInput) async throws -> String
}

/// Deterministic, task-scoped editing. Model cognition never enters this owner.
public actor ArtifactService: ArtifactCapability, ArtifactStreaming {
    public typealias Present = @Sendable (WorkspaceID, String, String, [String: String], Bool) async throws -> String
    private struct Session {
        let id: WorkspaceID
        let sessionID: String
        var title: String
        var entry: String
        let editor: ArtifactEditing
        var revision: UUID?
        var rendered = false
        var verification = "unverified"
        var stream: UUID?
        var lastCheckpoint = ContinuousClock.now
        var previewFiles: [String: String]?
        var savepoints: [String: (ArtifactDraft, String)] = [:]
        var editBase: ArtifactDraft?
        var generation = 0
    }
    private let workspace: ArtifactWorkspace
    private let present: Present
    private let prepare: @Sendable (WorkspaceID, Bool) async throws -> Void
    private let describe: @Sendable (WorkspaceID, String?, String?) async throws -> Void
    private let capture: @Sendable (WorkspaceID) async throws -> Data?
    private var sessions: [String: Session] = [:]
    private var admitting: Set<String> = []
    private var lockedProjects: Set<WorkspaceID> = []
    private enum Lane { case mutation, observation }
    private struct Work {
        let delegateID: String?
        let lane: Lane
        let cleanup: Bool
        let cancel: @Sendable () -> Void
        let join: @Sendable () async -> Void
    }
    private var work: [UUID: Work] = [:]
    private var revoked: Set<String> = []
    private var releases: [String: Task<Void, any Error>] = [:]
    private var shutdownTask: Task<Void, any Error>?
    private var closed = false
    private var cleanupFailure: (any Error)?
    public init(
        workspace: ArtifactWorkspace,
        prepare: @escaping @Sendable (WorkspaceID, Bool) async throws -> Void = { _, _ in },
        capture: @escaping @Sendable (WorkspaceID) async throws -> Data? = { _ in nil },
        describe: @escaping @Sendable (WorkspaceID, String?, String?) async throws -> Void = { _, _, _ in },
        present: @escaping Present
    ) {
        self.prepare = prepare
        self.workspace = workspace
        self.present = present
        self.capture = capture
        self.describe = describe
    }
    public func perform(invocation: any FunctionInput) async throws -> String {
        let owner = invocation.context.source == "writer" ? invocation.context.taskID : nil
        if let owner, let session = sessions[owner], session.sessionID != invocation.context.sessionID {
            throw ActionExecutionError.invalidInvocation
        }
        let lane: Lane = invocation.call.parameters["command"] == "preview" ? .observation : .mutation
        return try await run(delegateID: owner, lane: lane) {
            try await self.performAdmitted(invocation: invocation)
        }
    }
    private func performAdmitted(invocation: any FunctionInput) async throws -> String {
        let args = invocation.call.parameters
        guard let command = args["command"] else { throw ArtifactWorkspaceError.missingFile }
        guard let delegateID = invocation.context.taskID, invocation.context.source == "writer" else {
            throw ActionExecutionError.invalidInvocation
        }
        if command == "searchWorkspaces" {
            guard let query = args["query"] else { throw ArtifactWorkspaceError.invalidQuery }
            return try encode(
                await workspace.search(query.trimmingCharacters(in: .whitespacesAndNewlines), before: args["before"]))
        }
        if command == "open" || command == "delete" {
            guard let task = args["taskID"], let id = WorkspaceID(agent: "writer", taskID: task) else {
                throw ArtifactWorkspaceError.invalidPath
            }
            guard !lockedProjects.contains(id) else { throw ArtifactWorkspaceError.busy }
            lockedProjects.insert(id)
            defer { lockedProjects.remove(id) }
            if command == "delete" {
                try await prepare(id, true)
                try await workspace.delete(id)
                return try encode(["workspaceID": id.rawValue, "status": "deleted"])
            }
            try await prepare(id, false)
            if let draft = try await workspace.checkpoint(for: id) {
                let presentation = try await present(id, draft.title, draft.entry, draft.draft.files, true)
                return try workspaceEvidence(id, title: draft.title, entry: draft.entry, presentation: presentation)
            }
            let project = try await workspace.project(id)
            let presentation = try await present(id, project.title, project.entry, project.files, false)
            return try workspaceEvidence(id, title: project.title, entry: project.entry, presentation: presentation)
        }
        switch command {
        case "start", "resume":
            guard sessions[delegateID] == nil, !admitting.contains(delegateID), sessions.count + admitting.count < 1
            else {
                throw ArtifactWorkspaceError.busy
            }
            guard let raw = args["workspaceID"], let id = WorkspaceID(rawValue: raw),
                id.agent == invocation.context.source
            else { throw ArtifactWorkspaceError.invalidPath }
            guard !lockedProjects.contains(id) else { throw ArtifactWorkspaceError.busy }
            admitting.insert(delegateID)
            lockedProjects.insert(id)
            defer { admitting.remove(delegateID) }
            do {
                let original = try await workspace.published(id)
                let checkpoint = try await workspace.checkpoint(for: id)
                guard
                    args["createWorkspace"] == "true" || original != nil || checkpoint != nil
                else {
                    throw ArtifactWorkspaceError.missingProject
                }
                let entry = args["entry"] ?? checkpoint?.entry ?? original?.entry ?? "index.html"
                try ArtifactDraft.validatePath(entry)
                guard ["html", "md", "txt"].contains((entry as NSString).pathExtension.lowercased()) else {
                    throw ArtifactWorkspaceError.invalidPath
                }
                let title = args["title"] ?? checkpoint?.title ?? original?.title ?? "作品"
                guard !title.isEmpty else { throw ArtifactWorkspaceError.invalidTitle }
                let draft = try checkpoint?.draft ?? ArtifactDraft(files: original?.files ?? [:])
                if original == nil, checkpoint == nil {
                    try await workspace.checkpoint(
                        .init(
                            workspaceID: id, baseRevision: nil, title: title, entry: entry, draft: draft,
                            interrupted: true))
                }
                sessions[delegateID] = Session(
                    id: id, sessionID: invocation.context.sessionID,
                    title: title, entry: entry, editor: ArtifactEditing(draft: draft),
                    revision: original?.revision)
                if command == "start" { try await prepare(id, false) }
                var visible = draft.files
                if visible[entry] == nil {
                    visible[entry] =
                        entry.hasSuffix(".html")
                        ? "<!doctype html><meta charset=utf-8><h2>Writer</h2><p>正在准备创作…</p>" : "正在准备创作…"
                }
                let presentation = try await present(id, title, entry, visible, true)
                try await describe(id, title, args["subtitle"])
                return try workspaceEvidence(id, title: title, entry: entry, presentation: presentation)
            } catch {
                sessions.removeValue(forKey: delegateID)
                lockedProjects.remove(id)
                throw error
            }
        default: break
        }
        guard var session = sessions[delegateID] else { throw ArtifactWorkspaceError.missingProject }
        if command == "describe" {
            try await describe(session.id, nil, args["subtitle"])
            return "Presentation metadata accepted; closed windows remain closed."
        }
        if command == "rename" || command == "edit", let title = args["title"] {
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ArtifactWorkspaceError.invalidTitle
            }
            if command == "rename" {
                session.title = title
                let draft = await session.editor.snapshot()
                try await workspace.checkpoint(
                    .init(
                        workspaceID: session.id, baseRevision: session.revision, title: title, entry: session.entry,
                        draft: draft,
                        interrupted: true))
                sessions[delegateID] = session
                try await describe(session.id, title, nil)
                return "Title updated: " + title
            }
        }
        if command == "preview" {
            let visible: ArtifactDraft
            if let stream = session.stream {
                visible = try await session.editor.preview(stream, checkpointOnly: true)
            } else {
                visible = await session.editor.snapshot()
            }
            if visible.files == session.previewFiles { return try encode(["status": "unchanged"]) }
            guard let entry = visible.files[session.entry], !entry.isEmpty else {
                return try encode(["status": "unchanged"])
            }
            let result = try await present(session.id, session.title, session.entry, visible.files, true)
            // A preview awaits independently of streaming. Never write its old Session over a newer edit.
            if sessions[delegateID]?.generation == session.generation {
                sessions[delegateID]?.previewFiles = visible.files
            }
            return result
        }
        guard session.stream == nil else { throw ArtifactWorkspaceError.busy }
        switch command {
        case "list":
            let files = await session.editor.snapshot().files
            let prefix = args["path"] ?? ""
            let paths = files.keys.sorted().filter { prefix.isEmpty || $0 == prefix || $0.hasPrefix(prefix + "/") }
            return try encode(paths.map { ["path": $0, "bytes": String(files[$0]?.utf8.count ?? 0)] })
        case "read":
            guard let path = args["path"] else { throw ArtifactWorkspaceError.invalidPath }
            if let raw = args["line"] {
                guard let line = Int(raw) else { throw ArtifactWorkspaceError.invalidPath }
                return try encode(
                    await session.editor.readLines(path: path, line: line, count: try integer(args, "limit", 60)))
            }
            return try encode(
                await session.editor.read(
                    path: path, offset: try integer(args, "offset", 0), limit: try integer(args, "limit", 2500)))
        case "search":
            guard let query = args["query"], !query.isEmpty else {
                throw ArtifactWorkspaceError.invalidQuery
            }
            let offset = try integer(args, "offset", 0)
            guard offset >= 0 else { throw ArtifactWorkspaceError.invalidReadRange }
            let files = await session.editor.snapshot().files
            let prefix = args["path"] ?? ""
            var matches: [[String: String]] = []
            var total = 0
            for (path, content) in files.sorted(by: { $0.key < $1.key })
            where prefix.isEmpty || path == prefix || path.hasPrefix(prefix + "/") {
                for (line, text) in content.components(separatedBy: "\n").enumerated() where text.contains(query) {
                    if total >= offset, matches.count < 16 {
                        matches.append([
                            "path": path, "line": String(line + 1), "text": String(text.prefix(120)),
                            "textTruncated": String(text.count > 120),
                        ])
                    }
                    total += 1
                }
            }
            return try encode(
                SearchResult(
                    matches: matches, total: total,
                    nextOffset: offset + matches.count < total ? offset + matches.count : nil))
        case "move", "removeTree":
            guard let path = args["path"] else { throw ArtifactWorkspaceError.invalidPath }
            let movingEntry = session.entry == path || session.entry.hasPrefix(path + "/")
            let destination = command == "move" ? args["destination"] : nil
            guard command != "move" || destination != nil, command != "removeTree" || !movingEntry else {
                throw ArtifactWorkspaceError.invalidPath
            }
            if movingEntry, let destination {
                let nextEntry = destination + session.entry.dropFirst(path.count)
                guard ["html", "md", "txt"].contains((nextEntry as NSString).pathExtension.lowercased()) else {
                    throw ArtifactWorkspaceError.invalidPath
                }
            }
            let draft = try await session.editor.relocate(path: path, destination: destination)
            if movingEntry, let destination { session.entry = destination + session.entry.dropFirst(path.count) }
            session.rendered = false
            session.generation += 1
            sessions[delegateID] = session
            try await save(session, draft)
            return "Draft updated. Repair affected links/imports, then render the complete change set."
        case "diff":
            guard let id = args["savepoint"], let (base, _) = session.savepoints[id] else {
                throw ArtifactWorkspaceError.missingFile
            }
            let latest = await session.editor.snapshot()
            let paths = Set(base.files.keys).union(latest.files.keys).sorted().filter {
                base.files[$0] != latest.files[$0] && (args["path"] == nil || args["path"] == $0)
            }
            let offset = try integer(args, "offset", 0)
            guard offset >= 0 else { throw ArtifactWorkspaceError.invalidReadRange }
            let changes = paths.dropFirst(offset).prefix(2).map { path in
                let before = (base.files[path] ?? "").components(separatedBy: "\n")
                let after = (latest.files[path] ?? "").components(separatedBy: "\n")
                let common = zip(before, after).prefix { $0 == $1 }.count
                return [
                    "path": path, "firstChangedLine": String(common + 1),
                    "before": String(before.dropFirst(common).joined(separator: "\n").prefix(300)),
                    "after": String(after.dropFirst(common).joined(separator: "\n").prefix(300)),
                    "note": "Excerpts capped at 300 characters; read files for complete contents.",
                ]
            }
            return try encode(
                SearchResult(
                    matches: changes, total: paths.count,
                    nextOffset: offset + changes.count < paths.count ? offset + changes.count : nil))
        case "savepoint":
            guard session.stream == nil else { throw ArtifactWorkspaceError.busy }
            let id = "savepoint_\(session.savepoints.count + 1)"
            session.savepoints[id] = (await session.editor.snapshot(), session.entry)
            sessions[delegateID] = session
            return try encode(["savepoint": id])
        case "restore":
            guard let id = args["savepoint"], let (draft, entry) = session.savepoints[id] else {
                throw ArtifactWorkspaceError.missingFile
            }
            try await session.editor.restore(draft)
            session.entry = entry
            session.rendered = false
            session.generation += 1
            sessions[delegateID] = session
            try await save(session, draft)
            return "Savepoint restored. Render before finishing."
        case "edit":
            guard let path = args["path"] else { throw ArtifactWorkspaceError.invalidPath }
            guard let instruction = args["instruction"], !instruction.isEmpty else {
                throw ArtifactWorkspaceError.invalidInstruction
            }
            let reference = args["reference"]
            if args["reference"] != nil && reference == nil { throw ArtifactWorkspaceError.readRequired }
            let rawRefs = (args["contextReferences"] ?? "").split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let related = try await session.editor.relatedContext(rawRefs)
            let lower = try optionalInteger(args, "start")
            let upper = try optionalInteger(args, "end")
            let base = await session.editor.snapshot()
            let id = try await session.editor.begin(
                path: path, reference: reference,
                start: lower, end: upper)
            if let title = args["title"] { session.title = title }
            session.stream = id
            session.previewFiles = nil
            session.editBase = base
            session.generation += 1
            session.rendered = false
            sessions[delegateID] = session
            if let title = args["title"] { try await describe(session.id, title, nil) }
            let context = try await session.editor.context(for: id) + related
            return try encode([
                "streamID": id.uuidString, "instruction": "File: \(path)\n\(instruction)",
                "context": context,
            ])
        case "replace":
            guard let path = args["path"], let raw = args["reference"], let reference = Optional(raw),
                let old = args["oldText"], let new = args["newText"]
            else { throw ArtifactWorkspaceError.readRequired }
            let before = await session.editor.snapshot()
            let draft = try await session.editor.replace(path: path, reference: reference, old: old, new: new)
            session.rendered = false
            session.generation += 1
            sessions[delegateID] = session
            try await workspace.checkpoint(
                .init(
                    workspaceID: session.id, baseRevision: session.revision,
                    title: session.title, entry: session.entry, draft: draft, interrupted: true))
            return try encode(Self.changes(before: before.files, after: draft.files))
        case "remove":
            guard let path = args["path"], path != session.entry,
                let raw = args["reference"], let reference = Optional(raw)
            else { throw ArtifactWorkspaceError.readRequired }
            let draft = try await session.editor.remove(path: path, reference: reference)
            session.rendered = false
            session.generation += 1
            sessions[delegateID] = session
            try await workspace.checkpoint(
                .init(
                    workspaceID: session.id, baseRevision: session.revision,
                    title: session.title, entry: session.entry, draft: draft, interrupted: true))
            return "File removed from draft."
        case "render":
            guard session.stream == nil else { throw ArtifactWorkspaceError.busy }
            let draft = await session.editor.snapshot()
            let result = try await present(session.id, session.title, session.entry, draft.files, false)
            guard sessions[delegateID] != nil else { throw ArtifactWorkspaceError.conflict }
            session.verification =
                (try? JSONDecoder().decode([String: String].self, from: Data(result.utf8)))?["status"] ?? "unverified"
            session.rendered = true
            sessions[delegateID] = session
            return "Draft revision: \(session.generation). Rendering is execution evidence, not semantic acceptance.\n"
                + result
        case "finish":
            guard session.rendered, session.stream == nil, session.verification != "errors" else {
                throw ArtifactWorkspaceError.renderRequired
            }
            let draft = await session.editor.snapshot()
            let project = try await workspace.publish(
                id: session.id, expecting: session.revision, title: session.title, draft: draft, entry: session.entry)
            session.revision = project.revision
            sessions[delegateID] = session
            return try encode([
                "workspaceID": project.id.rawValue, "revision": project.revision.uuidString,
                "summary": String((args["summary"] ?? "作品已保存").prefix(512)),
                "verification": session.verification,
            ])
        default: throw ArtifactWorkspaceError.invalidPath
        }
    }
    public func append(streamID: String, delegateID: String, text: String) async throws {
        try await run(delegateID: delegateID) {
            try await self.appendAdmitted(streamID: streamID, delegateID: delegateID, text: text)
        }
    }
    private func appendAdmitted(streamID: String, delegateID: String, text: String) async throws {
        guard var session = sessions[delegateID], let id = UUID(uuidString: streamID), session.stream == id else {
            throw ArtifactWorkspaceError.conflict
        }
        try Task.checkCancellation()
        try await session.editor.append(text, to: id)
        if session.lastCheckpoint.duration(to: .now) >= .milliseconds(200) {
            session.lastCheckpoint = .now
            sessions[delegateID] = session
            let preview = try await session.editor.preview(id)
            try await workspace.checkpoint(
                .init(
                    workspaceID: session.id, baseRevision: session.revision,
                    title: session.title, entry: session.entry, draft: preview, interrupted: true))

        }
    }
    public func complete(streamID: String, delegateID: String) async throws -> String {
        try await run(delegateID: delegateID) {
            try await self.completeAdmitted(streamID: streamID, delegateID: delegateID)
        }
    }
    private func completeAdmitted(streamID: String, delegateID: String) async throws -> String {
        guard var session = sessions[delegateID], let id = UUID(uuidString: streamID), session.stream == id else {
            throw ArtifactWorkspaceError.conflict
        }
        let draft = try await session.editor.finish(id)
        session.stream = nil
        sessions[delegateID] = session
        try await workspace.checkpoint(
            .init(
                workspaceID: session.id, baseRevision: session.revision,
                title: session.title, entry: session.entry, draft: draft, interrupted: true))

        let changes = Self.changes(before: session.editBase?.files ?? [:], after: draft.files)
        session.editBase = nil
        guard sessions[delegateID] != nil else { throw ArtifactWorkspaceError.conflict }
        sessions[delegateID] = session
        return try encode(changes)
    }
    public func abort(streamID: String, delegateID: String) async throws {
        try await run(delegateID: delegateID, cleanup: true) {
            try await self.abortAdmitted(streamID: streamID, delegateID: delegateID)
        }
    }
    private func abortAdmitted(streamID: String, delegateID: String) async throws {
        guard var session = sessions[delegateID], let id = UUID(uuidString: streamID), session.stream == id else {
            return
        }
        var errors: [any Error] = []
        do {
            let preview = try await session.editor.preview(id)
            try await workspace.checkpoint(
                .init(
                    workspaceID: session.id, baseRevision: session.revision,
                    title: session.title, entry: session.entry, draft: preview, interrupted: true))
        } catch { errors.append(error) }
        do { try await session.editor.cancel(id) } catch { errors.append(error) }
        session.stream = nil
        sessions[delegateID] = session
        if !errors.isEmpty { throw NativeCleanupFailure(errors: errors) }
    }
    public func snapshot(delegateID: String) async throws -> Data? {
        try await run(delegateID: delegateID, lane: .observation) {
            try await self.snapshotAdmitted(delegateID: delegateID)
        }
    }
    private func snapshotAdmitted(delegateID: String) async throws -> Data? {
        guard let session = sessions[delegateID], session.rendered else { return nil }
        return try await capture(session.id)
    }
    public func revoke(delegateID: String) {
        let selected = work.values.filter { $0.delegateID == delegateID }
        guard sessions[delegateID] != nil || !selected.isEmpty || releases[delegateID] != nil else { return }
        revoked.insert(delegateID)
        for operation in selected where !operation.cleanup { operation.cancel() }
    }
    public func release(delegateID: String) async throws {
        if let shutdownTask { return try await shutdownTask.value }
        if let release = releases[delegateID] { return try await release.value }
        if let cleanupFailure { throw cleanupFailure }
        revoke(delegateID: delegateID)
        let selected = work.values.filter { $0.delegateID == delegateID }
        guard sessions[delegateID] != nil || !selected.isEmpty else {
            revoked.remove(delegateID)
            return
        }
        let release = Task {
            for operation in selected { await operation.join() }
            try await self.releaseAdmitted(delegateID: delegateID)
        }
        releases[delegateID] = release
        defer {
            releases[delegateID] = nil
            revoked.remove(delegateID)
        }
        do { try await release.value } catch {
            cleanupFailure = error
            closed = true
            throw error
        }
    }
    private func releaseAdmitted(delegateID: String) async throws {
        guard let session = sessions[delegateID] else { return }
        var failure: (any Error)?
        if let stream = session.stream {
            do { try await abortAdmitted(streamID: stream.uuidString, delegateID: delegateID) } catch {
                failure = error
            }
        }
        await session.editor.close()
        sessions.removeValue(forKey: delegateID)
        lockedProjects.remove(session.id)
        if let failure { throw failure }
    }
    /// The Actions root closes admission before joining effects, including host streaming continuations.
    public func shutdown() async throws {
        if let shutdownTask { return try await shutdownTask.value }
        closed = true
        let selected = Array(work.values)
        for operation in selected where !operation.cleanup { operation.cancel() }
        let retiring = releases
        let shutdown = Task {
            for operation in selected { await operation.join() }
            var errors: [any Error] = []
            for release in retiring.values {
                do { try await release.value } catch { errors.append(error) }
            }
            for id in Array(self.sessions.keys) where retiring[id] == nil {
                do { try await self.releaseAdmitted(delegateID: id) } catch { errors.append(error) }
            }
            if let failure = self.cleanupFailure, errors.isEmpty { errors.append(failure) }
            if !errors.isEmpty { throw NativeCleanupFailure(errors: errors) }
        }
        shutdownTask = shutdown
        try await shutdown.value
    }
    /// Zero waiting slots: source intake uses caller backpressure; previews have a separate lane.
    private func run<Value: Sendable>(
        delegateID: String?, lane: Lane = .mutation, cleanup: Bool = false,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard !closed else { throw ArtifactWorkspaceError.closed }
        if let delegateID {
            guard releases[delegateID] == nil, cleanup || !revoked.contains(delegateID) else {
                throw ArtifactWorkspaceError.conflict
            }
            guard !work.values.contains(where: { $0.delegateID == delegateID && $0.lane == lane }) else {
                throw ArtifactWorkspaceError.busy
            }
        }
        guard work.count < 8 else { throw ArtifactWorkspaceError.busy }
        let id = UUID()
        let task = Task {
            defer { self.work[id] = nil }
            try Task.checkCancellation()
            let result = try await operation()
            try Task.checkCancellation()
            return result
        }
        work[id] = Work(
            delegateID: delegateID, lane: lane, cleanup: cleanup,
            cancel: { task.cancel() }, join: { _ = await task.result })
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
    private struct SearchResult: Encodable {
        let matches: [[String: String]]
        let total: Int
        let nextOffset: Int?
    }
    private func integer(_ args: [String: String], _ key: String, _ fallback: Int) throws -> Int {
        try optionalInteger(args, key) ?? fallback
    }
    private func optionalInteger(_ args: [String: String], _ key: String) throws -> Int? {
        guard let raw = args[key] else { return nil }
        guard let value = Int(raw) else { throw ArtifactWorkspaceError.invalidPath }
        return value
    }
    private func save(_ session: Session, _ draft: ArtifactDraft) async throws {
        try await workspace.checkpoint(
            .init(
                workspaceID: session.id, baseRevision: session.revision,
                title: session.title, entry: session.entry, draft: draft, interrupted: true))
    }
    /// Bounded change evidence; source is not echoed into the control history.
    private static func changes(before: [String: String], after: [String: String]) -> [[String: String]] {
        Set(before.keys).union(after.keys).sorted().compactMap { path in
            guard before[path] != after[path] else { return nil }
            let old = (before[path] ?? "").components(separatedBy: "\n")
            let new = (after[path] ?? "").components(separatedBy: "\n")
            let common = zip(old, new).prefix { $0 == $1 }.count
            return [
                "path": path, "firstChangedLine": String(common + 1),
                "beforeBytes": String(before[path]?.utf8.count ?? 0),
                "afterBytes": String(after[path]?.utf8.count ?? 0),
                "status": "draft edited; render before finish",
            ]
        }
    }
    private func workspaceEvidence(_ id: WorkspaceID, title: String, entry: String, presentation: String) throws
        -> String
    {
        let details = try? JSONDecoder().decode([String: String].self, from: Data(presentation.utf8))
        return try encode([
            "workspaceID": id.rawValue, "title": title, "entry": entry, "windowID": details?["windowID"] ?? "",
            "presentationStatus": details?["status"] ?? "unverified", "presentation": presentation,
        ])
    }
    private func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}

import Foundation
import FunctionContracts

public protocol ArtifactCapability: Sendable {
    func perform(invocation: any FunctionInput) async throws -> String
}

/// Deterministic, task-scoped editing. Model cognition never enters this owner.
public actor ArtifactService: ArtifactCapability, ArtifactStreaming {
    public typealias Present = @Sendable (UUID, String, String, [String: String], Bool) async throws -> String
    private struct Session {
        let id: UUID
        let title: String
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
    private let prepare: @Sendable (UUID, Bool) async throws -> Void
    private let capture: @Sendable (UUID) async throws -> Data?
    private var sessions: [String: Session] = [:]
    private var admitting: Set<String> = []
    private var lockedProjects: Set<UUID> = []
    public init(
        workspace: ArtifactWorkspace, prepare: @escaping @Sendable (UUID, Bool) async throws -> Void = { _, _ in },
        capture: @escaping @Sendable (UUID) async throws -> Data? = { _ in nil },
        present: @escaping Present
    ) {
        self.prepare = prepare
        self.workspace = workspace
        self.present = present
        self.capture = capture
    }
    public func perform(invocation: any FunctionInput) async throws -> String {
        let args = invocation.call.parameters
        guard let command = args["command"] else { throw ArtifactWorkspaceError.missingFile }
        if invocation.context.source == "assistant" {
            switch command {
            case "projects":
                return try encode(await workspace.inventory())
            case "open", "delete":
                guard let raw = args["projectID"], let id = UUID(uuidString: raw), !lockedProjects.contains(id) else {
                    throw ArtifactWorkspaceError.busy
                }
                lockedProjects.insert(id)
                defer { lockedProjects.remove(id) }
                if command == "delete" {
                    try await prepare(id, true)
                    try await workspace.delete(id)
                    return "deleted"
                }
                try await prepare(id, false)
                if let draft = try await workspace.checkpoint(for: id) {
                    return try await present(id, draft.title, draft.entry, draft.draft.files, true)
                }
                let project = try await workspace.project(id)
                return try await present(project.id, project.title, project.entry, project.files, false)
            default: throw ActionExecutionError.invalidInvocation
            }
        }
        guard let taskID = invocation.context.taskID, invocation.context.source == "writer" else {
            throw ActionExecutionError.invalidInvocation
        }
        switch command {
        case "start", "resume":
            guard sessions[taskID] == nil, !admitting.contains(taskID), sessions.count + admitting.count < 1 else {
                throw ArtifactWorkspaceError.busy
            }
            let id: UUID
            if let value = args["projectID"] {
                guard let parsed = UUID(uuidString: value) else { throw ArtifactWorkspaceError.invalidPath }
                id = parsed
            } else {
                id = UUID()
            }
            guard !lockedProjects.contains(id) else { throw ArtifactWorkspaceError.busy }
            admitting.insert(taskID)
            lockedProjects.insert(id)
            defer { admitting.remove(taskID) }
            do {
                let original = try await workspace.list().first(where: { $0.id == id })
                let checkpoint = try await workspace.checkpoint(for: id)
                guard
                    args["projectID"] == nil || args["createProject"] == "true" || original != nil || checkpoint != nil
                else {
                    throw ArtifactWorkspaceError.missingProject
                }
                let entry = args["entry"] ?? checkpoint?.entry ?? original?.entry ?? "index.html"
                try ArtifactDraft.validatePath(entry)
                guard ["html", "md", "txt"].contains((entry as NSString).pathExtension.lowercased()) else {
                    throw ArtifactWorkspaceError.invalidPath
                }
                let title = args["title"] ?? checkpoint?.title ?? original?.title ?? "作品"
                guard !title.isEmpty, title.utf8.count <= 160 else { throw ArtifactWorkspaceError.invalidTitle }
                let draft = try checkpoint?.draft ?? ArtifactDraft(files: original?.files ?? [:])
                try await workspace.checkpoint(
                    .init(
                        projectID: id, baseRevision: original?.revision,
                        title: title, entry: entry, draft: draft, interrupted: true))
                sessions[taskID] = Session(
                    id: id, title: title, entry: entry, editor: ArtifactEditing(draft: draft),
                    revision: original?.revision)
                if command == "start" { try await prepare(id, false) }
                var visible = draft.files
                if visible[entry] == nil {
                    visible[entry] =
                        entry.hasSuffix(".html")
                        ? "<!doctype html><meta charset=utf-8><h2>Writer</h2><p>正在准备创作…</p>" : "正在准备创作…"
                }
                let presentation = try await present(id, title, entry, visible, true)
                let details = (try? JSONDecoder().decode([String: String].self, from: Data(presentation.utf8))) ?? [:]
                return try encode(["projectID": id.uuidString, "entry": entry, "windowID": details["windowID"] ?? ""])
            } catch {
                sessions.removeValue(forKey: taskID)
                lockedProjects.remove(id)
                throw error
            }
        case "projects":
            return try encode(await workspace.inventory())
        default: break
        }
        guard var session = sessions[taskID] else { throw ArtifactWorkspaceError.missingProject }
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
            session.previewFiles = visible.files
            sessions[taskID] = session
            return try await present(session.id, session.title, session.entry, visible.files, true)
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
            return try encode(await session.editor.read(path: path, offset: try integer(args, "offset", 0)))
        case "search":
            guard let query = args["query"], !query.isEmpty, query.utf8.count <= 1024 else {
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
            sessions[taskID] = session
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
        case "versions":
            let project = try await workspace.project(session.id)
            return try encode((project.previousVersions + [project.revision]).map(\.uuidString))
        case "restoreVersion":
            guard let raw = args["revision"], let revision = UUID(uuidString: raw) else {
                throw ArtifactWorkspaceError.invalidPath
            }
            let draft = try await workspace.version(session.id, revision: revision)
            let entry = args["entry"] ?? session.entry
            guard draft.files[entry] != nil,
                ["html", "md", "txt"].contains((entry as NSString).pathExtension.lowercased())
            else {
                throw ArtifactWorkspaceError.missingFile
            }
            try await session.editor.restore(draft)
            session.entry = entry
            session.rendered = false
            session.generation += 1
            sessions[taskID] = session
            try await save(session, draft)
            return "Historical version restored to draft only. Render and finish to publish a new version."
        case "savepoint":
            guard session.stream == nil else { throw ArtifactWorkspaceError.busy }
            guard session.savepoints.count < 8 else { throw ArtifactWorkspaceError.savepointLimit }
            let id = UUID().uuidString
            session.savepoints[id] = (await session.editor.snapshot(), session.entry)
            sessions[taskID] = session
            return try encode(["savepoint": id])
        case "restore":
            guard let id = args["savepoint"], let (draft, entry) = session.savepoints[id] else {
                throw ArtifactWorkspaceError.missingFile
            }
            try await session.editor.restore(draft)
            session.entry = entry
            session.rendered = false
            session.generation += 1
            sessions[taskID] = session
            try await save(session, draft)
            return "Savepoint restored. Render before finishing."
        case "edit":
            guard let path = args["path"], let instruction = args["instruction"], !instruction.isEmpty,
                instruction.utf8.count <= 2048
            else { throw ArtifactWorkspaceError.invalidPath }
            let reference = args["reference"].flatMap(UUID.init(uuidString:))
            if args["reference"] != nil && reference == nil { throw ArtifactWorkspaceError.readRequired }
            let rawRefs = (args["contextReferences"] ?? "").split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let refs = rawRefs.compactMap(UUID.init(uuidString:))
            guard refs.count == rawRefs.count else { throw ArtifactWorkspaceError.readRequired }
            let related = try await session.editor.relatedContext(refs)
            let lower = try optionalInteger(args, "start")
            let upper = try optionalInteger(args, "end")
            let base = await session.editor.snapshot()
            let id = try await session.editor.begin(
                path: path, reference: reference,
                start: lower, end: upper)
            session.stream = id
            session.previewFiles = nil
            session.editBase = base
            session.generation += 1
            session.rendered = false
            sessions[taskID] = session
            let context = try await session.editor.context(for: id) + related
            return try encode([
                "streamID": id.uuidString, "instruction": "File: \(path)\n\(instruction)",
                "context": context,
            ])
        case "replace":
            guard let path = args["path"], let raw = args["reference"], let reference = UUID(uuidString: raw),
                let old = args["oldText"], let new = args["newText"]
            else { throw ArtifactWorkspaceError.readRequired }
            let before = await session.editor.snapshot()
            let draft = try await session.editor.replace(path: path, reference: reference, old: old, new: new)
            session.rendered = false
            session.generation += 1
            sessions[taskID] = session
            try await workspace.checkpoint(
                .init(
                    projectID: session.id, baseRevision: session.revision,
                    title: session.title, entry: session.entry, draft: draft, interrupted: true))
            return try encode(Self.changes(before: before.files, after: draft.files))
        case "remove":
            guard let path = args["path"], path != session.entry,
                let raw = args["reference"], let reference = UUID(uuidString: raw)
            else { throw ArtifactWorkspaceError.readRequired }
            let draft = try await session.editor.remove(path: path, reference: reference)
            session.rendered = false
            session.generation += 1
            sessions[taskID] = session
            try await workspace.checkpoint(
                .init(
                    projectID: session.id, baseRevision: session.revision,
                    title: session.title, entry: session.entry, draft: draft, interrupted: true))
            return "File removed from draft."
        case "render":
            guard session.stream == nil else { throw ArtifactWorkspaceError.busy }
            let draft = await session.editor.snapshot()
            let result = try await present(session.id, session.title, session.entry, draft.files, false)
            guard sessions[taskID] != nil else { throw ArtifactWorkspaceError.conflict }
            session.verification =
                (try? JSONDecoder().decode([String: String].self, from: Data(result.utf8)))?["status"] ?? "unverified"
            session.rendered = true
            sessions[taskID] = session
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
            sessions[taskID] = session
            return try encode([
                "projectID": project.id.uuidString, "revision": project.revision.uuidString,
                "summary": String((args["summary"] ?? "作品已保存").prefix(512)),
                "verification": session.verification,
            ])
        default: throw ArtifactWorkspaceError.invalidPath
        }
    }
    public func append(streamID: String, taskID: String, text: String) async throws {
        guard var session = sessions[taskID], let id = UUID(uuidString: streamID), session.stream == id else {
            throw ArtifactWorkspaceError.conflict
        }
        try Task.checkCancellation()
        try await session.editor.append(text, to: id)
        if session.lastCheckpoint.duration(to: .now) >= .milliseconds(200) {
            session.lastCheckpoint = .now
            sessions[taskID] = session
            let preview = try await session.editor.preview(id)
            try await workspace.checkpoint(
                .init(
                    projectID: session.id, baseRevision: session.revision,
                    title: session.title, entry: session.entry, draft: preview, interrupted: true))

        }
    }
    public func complete(streamID: String, taskID: String) async throws -> String {
        guard var session = sessions[taskID], let id = UUID(uuidString: streamID), session.stream == id else {
            throw ArtifactWorkspaceError.conflict
        }
        let draft = try await session.editor.finish(id)
        session.stream = nil
        sessions[taskID] = session
        try await workspace.checkpoint(
            .init(
                projectID: session.id, baseRevision: session.revision,
                title: session.title, entry: session.entry, draft: draft, interrupted: true))

        let changes = Self.changes(before: session.editBase?.files ?? [:], after: draft.files)
        session.editBase = nil
        guard sessions[taskID] != nil else { throw ArtifactWorkspaceError.conflict }
        sessions[taskID] = session
        return try encode(changes)
    }
    public func abort(streamID: String, taskID: String) async throws {
        guard var session = sessions[taskID], let id = UUID(uuidString: streamID), session.stream == id else { return }
        let preview = try await session.editor.preview(id)
        try await workspace.checkpoint(
            .init(
                projectID: session.id, baseRevision: session.revision,
                title: session.title, entry: session.entry, draft: preview, interrupted: true))
        try await session.editor.cancel(id)
        session.stream = nil
        sessions[taskID] = session
    }
    public func snapshot(taskID: String) async throws -> Data? {
        guard let session = sessions[taskID], session.rendered else { return nil }
        return try await capture(session.id)
    }
    public func release(taskID: String) async throws {
        guard let session = sessions[taskID] else { return }
        var failure: (any Error)?
        if let stream = session.stream {
            do { try await abort(streamID: stream.uuidString, taskID: taskID) } catch { failure = error }
        }
        await session.editor.close()
        sessions.removeValue(forKey: taskID)
        lockedProjects.remove(session.id)
        if let failure { throw failure }
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
                projectID: session.id, baseRevision: session.revision,
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
    private func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}

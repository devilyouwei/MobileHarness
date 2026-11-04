import Foundation
import StorageFiles

public enum ArtifactWorkspaceError: String, Error, Sendable, CustomStringConvertible {
    case invalidPath, missingFile, existingFile, ambiguousMatch, readRequired, missingProject, conflict, busy
    case invalidReadRange, readReferenceLimit, relatedContextLimit, savepointLimit, invalidTitle, invalidQuery
    case renderRequired
    case archiveFormatLimit
    public var description: String {
        let detail: String
        switch self {
        case .renderRequired: detail = "Render the latest complete draft and resolve reported errors before publishing."
        case .ambiguousMatch:
            detail =
                "oldText must be nonempty and match exactly once inside the fresh read range; reread or narrow the range. No file changed."
        case .invalidReadRange: detail = "Use an existing line/offset and the declared read page size."
        case .readReferenceLimit: detail = "This editing session already retains 128 read references."
        case .relatedContextLimit:
            detail = "Select at most eight read references and 24000 UTF-8 bytes of related context."
        case .savepointLimit: detail = "This editing session has eight savepoints; reuse a returned savepoint."
        case .invalidTitle: detail = "Use a nonempty title of at most 160 UTF-8 bytes."
        case .invalidQuery: detail = "Use a nonempty query of at most 1024 UTF-8 bytes."
        case .archiveFormatLimit:
            detail = "This export requires ZIP64, which is unsupported; share source files separately."
        default: return rawValue
        }
        return rawValue + ": " + detail
    }
}

/// A value transaction: invalid edits never change the draft or the published project.
public struct ArtifactDraft: Codable, Equatable, Sendable {
    public private(set) var files: [String: String]
    private var observed: Set<String> = []
    public init(files: [String: String] = [:]) throws {
        self.files = files
        try validate()
    }
    public static func validatePath(_ path: String) throws {
        guard path.utf8.count <= 160, !path.isEmpty,
            path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".")
                    && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
            }),
            ["html", "css", "js", "svg", "json", "txt", "md"].contains((path as NSString).pathExtension.lowercased())
        else { throw ArtifactWorkspaceError.invalidPath }
    }
    public func validate() throws {
        for path in files.keys {
            try Self.validatePath(path)
        }
        for path in files.keys {
            guard !files.keys.contains(where: { $0.hasPrefix(path + "/") }) else {
                throw ArtifactWorkspaceError.invalidPath
            }
        }
    }
    public mutating func read(_ path: String, offset: Int = 0, limit: Int = 12_000) throws -> String {
        try Self.validatePath(path)
        guard let text = files[path] else { throw ArtifactWorkspaceError.missingFile }
        guard offset >= 0, (1...12_000).contains(limit), offset <= text.count else {
            throw ArtifactWorkspaceError.invalidReadRange
        }
        observed.insert(path)
        return String(text.dropFirst(offset).prefix(limit))
    }
    public mutating func create(_ path: String, content: String) throws {
        guard files[path] == nil else { throw ArtifactWorkspaceError.existingFile }
        try update(path, content: content)
        observed.insert(path)
    }
    public mutating func replace(_ path: String, old: String, new: String) throws {
        guard observed.contains(path) else { throw ArtifactWorkspaceError.readRequired }
        guard let text = files[path] else { throw ArtifactWorkspaceError.missingFile }
        guard !old.isEmpty, let range = text.range(of: old, options: .literal),
            text.range(of: old, options: .literal, range: text.index(after: range.lowerBound)..<text.endIndex) == nil
        else { throw ArtifactWorkspaceError.ambiguousMatch }
        var next = text
        next.replaceSubrange(range, with: new)
        try update(path, content: next)
    }
    public mutating func delete(_ path: String) throws {
        guard observed.contains(path) else { throw ArtifactWorkspaceError.readRequired }
        guard files.removeValue(forKey: path) != nil else { throw ArtifactWorkspaceError.missingFile }
        observed.remove(path)
    }
    private mutating func update(_ path: String, content: String) throws {
        var candidate = files
        candidate[path] = content
        let valid = try ArtifactDraft(files: candidate)
        files = valid.files
    }
}

public struct ArtifactProject: Codable, Sendable, Equatable {
    public let id: UUID
    public let revision: UUID
    public let title: String
    public let files: [String: String]
    public let previousVersions: [UUID]
    public let entryPath: String
    public var entry: String { entryPath }
    public init(
        id: UUID, revision: UUID, title: String, files: [String: String], previousVersions: [UUID],
        entryPath: String = "index.html"
    ) {
        self.id = id
        self.revision = revision
        self.title = title
        self.files = files
        self.previousVersions = previousVersions
        self.entryPath = entryPath
    }
}

public struct ArtifactWorkspaceIndex: Codable, Sendable {
    public var projects: [ArtifactProject] = []
    public var pendingDeletions: [UUID] = []
    public var drafts: [ArtifactCheckpoint] = []
    public init() {}
}

/// One serial publisher, at most two cancellation-aware waiters. Immutable versions keep WebKit readers stable.
public actor ArtifactWorkspace {
    private let disk: DiskFileStore
    private let index: any DocumentStore<ArtifactWorkspaceIndex>
    private var busy = false
    private var waiters: [(UUID, CheckedContinuation<Void, any Error>)] = []
    public init(disk: DiskFileStore, index: any DocumentStore<ArtifactWorkspaceIndex>) {
        self.disk = disk
        self.index = index
    }
    public func list() async throws -> [ArtifactProject] { try await index.load()?.value.projects ?? [] }
    public func inventory() async throws -> [[String: String]] {
        let value = try await index.load()?.value ?? ArtifactWorkspaceIndex()
        var result = value.projects.map {
            [
                "projectID": $0.id.uuidString, "title": $0.title, "entry": $0.entry, "revision": $0.revision.uuidString,
                "state": "published",
            ]
        }
        for draft in value.drafts {
            if let index = result.firstIndex(where: { $0["projectID"] == draft.projectID.uuidString }) {
                result[index]["state"] = "interruptedDraft"
            } else {
                result.append([
                    "projectID": draft.projectID.uuidString, "title": draft.title, "entry": draft.entry,
                    "state": "interruptedDraft",
                ])
            }
        }
        return result
    }
    public func project(_ id: UUID) async throws -> ArtifactProject {
        guard let project = try await list().first(where: { $0.id == id }) else {
            throw ArtifactWorkspaceError.missingProject
        }
        _ = try ArtifactDraft(files: project.files)
        return project
    }
    /// Read retained immutable source through the confined Storage interface, never a shell or host path.
    public func version(_ id: UUID, revision: UUID) async throws -> ArtifactDraft {
        let current = try await project(id)
        if current.revision == revision { return try ArtifactDraft(files: current.files) }
        guard current.previousVersions.contains(revision) else { throw ArtifactWorkspaceError.missingFile }
        let prefix = key(id, revision) + "/"
        var cursor: String?
        var files: [String: String] = [:]
        do {
            repeat {
                try Task.checkCancellation()
                let page = try await disk.listObjects(cursor: cursor, limit: 128)
                cursor = page.next
                for name in page.keys where name.hasPrefix(prefix) {
                    guard let info = try await disk.info(name),
                        let data = try await disk.read(name, maximumBytes: max(1, Int(info.bytes))),
                        var text = String(data: data, encoding: .utf8)
                    else { throw ArtifactWorkspaceError.missingFile }
                    let path = String(name.dropFirst(prefix.count))
                    if path.hasSuffix(".html"), text.hasPrefix("\u{feff}") { text.removeFirst() }
                    files[path] = text
                    _ = try ArtifactDraft(files: files)
                }
            } while cursor != nil
        } catch {
            if let cursor { await disk.closeListing(cursor) }
            throw error
        }
        guard !files.isEmpty else { throw ArtifactWorkspaceError.missingFile }
        return try ArtifactDraft(files: files)
    }
    public func entry(_ project: ArtifactProject) async throws -> URL {
        try await disk.fileURL(
            key(project.id, project.revision) + "/" + project.entry, maximumBytes: Int.max)
    }
    public func publish(
        id: UUID, expecting revision: UUID?, title: String, draft: ArtifactDraft, entry: String = "index.html"
    ) async throws -> ArtifactProject {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        try draft.validate()
        try ArtifactDraft.validatePath(entry)
        guard let content = draft.files[entry], !content.isEmpty,
            !title.isEmpty, title.utf8.count <= 160
        else { throw ArtifactWorkspaceError.missingFile }
        let snapshot = try await index.load()
        var value = snapshot?.value ?? ArtifactWorkspaceIndex()
        let previous = value.projects.first(where: { $0.id == id })
        guard previous?.revision == revision else { throw ArtifactWorkspaceError.conflict }
        // Projects and versions live until explicit deletion; admission is not a lifetime task quota.
        let history = previous.map { $0.previousVersions + [$0.revision] } ?? []
        let next = ArtifactProject(
            id: id, revision: UUID(), title: title, files: draft.files, previousVersions: history, entryPath: entry)
        let prefix = key(id, next.revision)
        do {
            for (path, content) in draft.files.sorted(by: { $0.key < $1.key }) {
                try Task.checkCancellation()
                let encoded =
                    path.lowercased().hasSuffix(".html") && !content.hasPrefix("\u{feff}")
                    ? "\u{feff}" + content : content
                try await disk.putIfAbsent(Data(encoded.utf8), key: prefix + "/" + path)
            }
            try Task.checkCancellation()
            value.projects.removeAll { $0.id == id }
            value.projects.append(next)
            value.drafts.removeAll { $0.projectID == id }
            _ = try await index.save(value, expecting: snapshot?.revision)
        } catch {
            do { try await disk.remove(prefix) } catch let cleanup {
                throw BinaryPublicationError(publication: error, cleanup: cleanup)
            }
            throw error
        }
        return next
    }
    public func delete(_ id: UUID) async throws {
        try await acquire()
        defer { release() }
        guard let snapshot = try await index.load(),
            snapshot.value.projects.contains(where: { $0.id == id })
                || snapshot.value.drafts.contains(where: { $0.projectID == id })
                || snapshot.value.pendingDeletions.contains(id)
        else {
            throw ArtifactWorkspaceError.missingProject
        }
        var next = snapshot.value
        next.projects.removeAll { $0.id == id }
        next.drafts.removeAll { $0.projectID == id }
        var pending = next.pendingDeletions
        if !pending.contains(id) { pending.append(id) }
        next.pendingDeletions = pending
        // Remove the index first: a cleanup failure cannot leave a live entry pointing at missing files.
        let committed = try await index.save(next, expecting: snapshot.revision)
        try await disk.remove(id.uuidString)
        next.pendingDeletions = pending.filter { $0 != id }
        _ = try await index.save(next, expecting: committed.revision)
    }
    public func checkpoint(_ checkpoint: ArtifactCheckpoint) async throws {
        try await acquire()
        defer { release() }
        try checkpoint.draft.validate()
        let snapshot = try await index.load()
        var value = snapshot?.value ?? ArtifactWorkspaceIndex()
        guard value.projects.first(where: { $0.id == checkpoint.projectID })?.revision == checkpoint.baseRevision else {
            throw ArtifactWorkspaceError.conflict
        }
        var drafts = value.drafts
        let identities = Set(value.projects.map(\.id) + drafts.map(\.projectID) + (value.pendingDeletions))
        drafts.removeAll { $0.projectID == checkpoint.projectID }
        drafts.append(checkpoint)
        value.drafts = drafts
        let directory = checkpoint.projectID.uuidString
        _ = try await disk.directory(directory)
        do {
            _ = try await index.save(value, expecting: snapshot?.revision)
        } catch {
            if !identities.contains(checkpoint.projectID) {
                do { try await disk.remove(directory) } catch let cleanup {
                    throw BinaryPublicationError(publication: error, cleanup: cleanup)
                }
            }
            throw error
        }
    }
    public func checkpoint(for id: UUID) async throws -> ArtifactCheckpoint? {
        try await index.load()?.value.drafts.first { $0.projectID == id }
    }
    private func acquire() async throws {
        try Task.checkCancellation()
        if !busy {
            busy = true
            return
        }
        guard waiters.count < 2 else { throw ArtifactWorkspaceError.busy }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        do { try Task.checkCancellation() } catch {
            release()
            throw error
        }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().1.resume() }
    }
    private func key(_ id: UUID, _ revision: UUID) -> String { id.uuidString + "/" + revision.uuidString }
}

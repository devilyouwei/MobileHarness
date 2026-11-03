import Foundation
import StorageFiles

public enum WebWorkspaceError: String, Error, Sendable {
    case invalidPath, missingFile, existingFile, ambiguousMatch, readRequired, capacity, missingProject, conflict, busy
}

/// A value transaction: invalid edits never change the draft or the published project.
public struct WebDraft: Codable, Equatable, Sendable {
    public private(set) var files: [String: String]
    private var observed: Set<String> = []
    public static let maximumFileBytes = 65_536
    public static let maximumBytes = 262_144
    public init(files: [String: String] = [:]) throws {
        self.files = files
        try validate()
    }
    public static func validatePath(_ path: String) throws {
        guard path.utf8.count <= 160, !path.isEmpty,
            path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".")
                    && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
            }), ["html", "css", "js", "svg", "json", "txt"].contains((path as NSString).pathExtension.lowercased())
        else { throw WebWorkspaceError.invalidPath }
    }
    public func validate() throws {
        guard files.count <= 32, files.values.reduce(0, { $0 + $1.utf8.count }) <= Self.maximumBytes else {
            throw WebWorkspaceError.capacity
        }
        for (path, text) in files {
            try Self.validatePath(path)
            guard text.utf8.count <= Self.maximumFileBytes else { throw WebWorkspaceError.capacity }
        }
        for path in files.keys {
            guard !files.keys.contains(where: { $0.hasPrefix(path + "/") }) else {
                throw WebWorkspaceError.invalidPath
            }
        }
    }
    public mutating func read(_ path: String, offset: Int = 0, limit: Int = 12_000) throws -> String {
        try Self.validatePath(path)
        guard let text = files[path] else { throw WebWorkspaceError.missingFile }
        guard offset >= 0, (1...12_000).contains(limit), offset <= text.count else {
            throw WebWorkspaceError.capacity
        }
        observed.insert(path)
        return String(text.dropFirst(offset).prefix(limit))
    }
    public mutating func create(_ path: String, content: String) throws {
        guard files[path] == nil else { throw WebWorkspaceError.existingFile }
        try update(path, content: content)
        observed.insert(path)
    }
    public mutating func replace(_ path: String, old: String, new: String) throws {
        guard observed.contains(path) else { throw WebWorkspaceError.readRequired }
        guard let text = files[path] else { throw WebWorkspaceError.missingFile }
        guard !old.isEmpty, let range = text.range(of: old, options: .literal),
            text.range(of: old, options: .literal, range: text.index(after: range.lowerBound)..<text.endIndex) == nil
        else { throw WebWorkspaceError.ambiguousMatch }
        var next = text
        next.replaceSubrange(range, with: new)
        try update(path, content: next)
    }
    public mutating func delete(_ path: String) throws {
        guard observed.contains(path) else { throw WebWorkspaceError.readRequired }
        guard files.removeValue(forKey: path) != nil else { throw WebWorkspaceError.missingFile }
        observed.remove(path)
    }
    private mutating func update(_ path: String, content: String) throws {
        var candidate = files
        candidate[path] = content
        let valid = try WebDraft(files: candidate)
        files = valid.files
    }
}

public struct WebProject: Codable, Sendable, Equatable {
    public let id: UUID
    public let revision: UUID
    public let title: String
    public let files: [String: String]
    public let previousVersions: [UUID]
}

public struct WebWorkspaceIndex: Codable, Sendable {
    public var projects: [WebProject] = []
    public var pendingDeletions: [UUID]? = []
    public init() {}
}

/// One serial publisher, no waiting queue. Immutable versions keep WebKit readers stable.
public actor WebWorkspace {
    private let disk: DiskFileStore
    private let index: any DocumentStore<WebWorkspaceIndex>
    private var busy = false
    public init(disk: DiskFileStore, index: any DocumentStore<WebWorkspaceIndex>) {
        self.disk = disk
        self.index = index
    }
    public func list() async throws -> [WebProject] { try await index.load()?.value.projects ?? [] }
    public func project(_ id: UUID) async throws -> WebProject {
        guard let project = try await list().first(where: { $0.id == id }) else {
            throw WebWorkspaceError.missingProject
        }
        _ = try WebDraft(files: project.files)
        return project
    }
    public func entry(_ project: WebProject) async throws -> URL {
        try await disk.fileURL(
            key(project.id, project.revision) + "/index.html", maximumBytes: WebDraft.maximumFileBytes + 3)
    }
    public func publish(id: UUID, expecting revision: UUID?, title: String, draft: WebDraft) async throws -> WebProject
    {
        guard !busy else { throw WebWorkspaceError.busy }
        busy = true
        defer { busy = false }
        try Task.checkCancellation()
        try draft.validate()
        guard let html = draft.files["index.html"], !html.isEmpty,
            !title.isEmpty, title.utf8.count <= 160
        else { throw WebWorkspaceError.missingFile }
        let snapshot = try await index.load()
        var value = snapshot?.value ?? WebWorkspaceIndex()
        let previous = value.projects.first(where: { $0.id == id })
        guard previous?.revision == revision else { throw WebWorkspaceError.conflict }
        guard previous != nil || value.projects.count + (value.pendingDeletions?.count ?? 0) < 8 else {
            throw WebWorkspaceError.capacity
        }
        // Keep versions until explicit project deletion; bounded retention rejects before disk mutation.
        let history = previous.map { $0.previousVersions + [$0.revision] } ?? []
        guard history.count < 16 else { throw WebWorkspaceError.capacity }
        let next = WebProject(id: id, revision: UUID(), title: title, files: draft.files, previousVersions: history)
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
        guard !busy else { throw WebWorkspaceError.busy }
        busy = true
        defer { busy = false }
        guard let snapshot = try await index.load(),
            snapshot.value.projects.contains(where: { $0.id == id })
                || snapshot.value.pendingDeletions?.contains(id) == true
        else {
            throw WebWorkspaceError.missingProject
        }
        var next = snapshot.value
        next.projects.removeAll { $0.id == id }
        var pending = next.pendingDeletions ?? []
        if !pending.contains(id) { pending.append(id) }
        next.pendingDeletions = pending
        // Remove the index first: a cleanup failure cannot leave a live entry pointing at missing files.
        let committed = try await index.save(next, expecting: snapshot.revision)
        try await disk.remove(id.uuidString)
        next.pendingDeletions = pending.filter { $0 != id }
        _ = try await index.save(next, expecting: committed.revision)
    }
    private func key(_ id: UUID, _ revision: UUID) -> String { id.uuidString + "/" + revision.uuidString }
}

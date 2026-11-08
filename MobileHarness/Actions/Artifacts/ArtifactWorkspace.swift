import Foundation
import StorageCore
import StorageDatabase
import StorageFiles

public enum ArtifactWorkspaceError: String, Error, Sendable, CustomStringConvertible {
    case invalidPath, missingFile, existingFile, ambiguousMatch, readRequired, missingProject, conflict, busy
    case invalidReadRange, invalidInstruction, invalidTitle, invalidQuery
    case renderRequired, closed
    case archiveFormatLimit
    public var description: String {
        let detail: String
        switch self {
        case .renderRequired: detail = "Render the latest complete draft and resolve reported errors before publishing."
        case .ambiguousMatch:
            detail =
                "oldText must be nonempty and match exactly once inside the fresh read range; reread or narrow the range. No file changed."
        case .invalidReadRange: detail = "Use a valid line/offset and a positive read count."
        case .invalidInstruction: detail = "Supply a nonempty edit instruction."
        case .invalidTitle: detail = "Use a nonempty title."
        case .invalidQuery: detail = "Use a nonempty literal query."
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
        guard !path.isEmpty,
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
        guard offset >= 0, limit > 0, offset <= text.count else {
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
    public let id: WorkspaceID
    public let revision: UUID
    public let title: String
    public let files: [String: String]
    public let entryPath: String
    public var entry: String { entryPath }
    public init(
        id: WorkspaceID, revision: UUID, title: String, files: [String: String],
        entryPath: String = "index.html"
    ) {
        self.id = id
        self.revision = revision
        self.title = title
        self.files = files
        self.entryPath = entryPath
    }
}

/// Artifact validation over the current filesystem workspace. Snapshots are values, not versions.
public actor ArtifactWorkspace {
    private let disk: DiskFileStore
    private let catalog: any WorkspaceRepository
    private let store: WorkspaceStore
    public init(disk: DiskFileStore, catalog: any WorkspaceRepository) {
        self.disk = disk
        self.catalog = catalog
        store = WorkspaceStore(disk: disk, index: catalog)
    }
    public func list() async throws -> [ArtifactProject] {
        var result: [ArtifactProject] = []
        for item in try await catalog.directory() where !item.deleting {
            if let value = try await published(item.id) { result.append(value) }
        }
        return result
    }
    public func inventory() async throws -> [[String: String]] {
        try await catalog.directory().filter { !$0.deleting }.map(Self.metadata)
    }
    func search(_ query: String, before: String?) async throws -> WorkspaceMatches {
        let page = try await catalog.search(query, before: before)
        return WorkspaceMatches(matches: page.matches.map(Self.metadata), nextBefore: page.nextBefore)
    }
    struct WorkspaceMatches: Encodable, Sendable {
        let matches: [[String: String]]
        let nextBefore: String?
    }
    private static func metadata(_ item: WorkspaceSummary) -> [String: String] {
        [
            "agentID": item.id.agent, "taskID": item.id.taskID, "workspaceID": item.id.rawValue, "title": item.title,
            "entry": item.entry, "state": item.hasDraft ? "draft" : "saved",
        ]
    }
    public func published(_ id: WorkspaceID) async throws -> ArtifactProject? {
        guard let (info, files) = try await store.read(id), let token = info.revision else { return nil }
        _ = try ArtifactDraft(files: files)
        return .init(id: id, revision: token, title: info.title, files: files, entryPath: info.entry)
    }
    public func project(_ id: WorkspaceID) async throws -> ArtifactProject {
        guard let value = try await published(id) else { throw ArtifactWorkspaceError.missingProject }
        return value
    }
    public func entry(_ project: ArtifactProject) async throws -> URL {
        try await disk.fileURL(project.id.rawValue + "/" + project.entry, maximumBytes: Int.max)
    }
    public func publish(
        id: WorkspaceID, expecting token: UUID?, title: String, draft: ArtifactDraft, entry: String = "index.html"
    ) async throws -> ArtifactProject {
        try draft.validate()
        try ArtifactDraft.validatePath(entry)
        guard let content = draft.files[entry], !content.isEmpty else {
            throw ArtifactWorkspaceError.missingFile
        }
        guard !title.isEmpty else { throw ArtifactWorkspaceError.invalidTitle }
        do {
            let info = try await store.write(
                id, expecting: token, title: title, entry: entry, files: draft.files, published: true)
            guard let token = info.revision else { throw ArtifactWorkspaceError.conflict }
            return .init(id: id, revision: token, title: title, files: draft.files, entryPath: entry)
        } catch RecordStorageError.conflict { throw ArtifactWorkspaceError.conflict }
    }
    public func delete(_ id: WorkspaceID) async throws {
        try await catalog.markDeleting(id)
        try await disk.remove(id.rawValue)
        try await catalog.finishDeleting(id)
    }
    public func checkpoint(_ value: ArtifactCheckpoint) async throws {
        try value.draft.validate()
        do {
            _ = try await store.write(
                value.workspaceID, expecting: value.baseRevision, title: value.title, entry: value.entry,
                files: value.draft.files, published: false)
        } catch RecordStorageError.conflict { throw ArtifactWorkspaceError.conflict }
    }
    public func checkpoint(for id: WorkspaceID) async throws -> ArtifactCheckpoint? {
        guard let (info, files) = try await store.read(id), info.hasDraft else { return nil }
        return .init(
            workspaceID: id, baseRevision: info.revision, title: info.title, entry: info.entry,
            draft: try ArtifactDraft(files: files), interrupted: true)
    }
}

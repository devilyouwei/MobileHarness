import Foundation
import FunctionContracts
import StorageCore

/// Current recoverable content; acceptance remains separate from editing and rendering.
public struct ArtifactCheckpoint: Codable, Sendable {
    public let workspaceID: WorkspaceID
    public let baseRevision: UUID?
    public let title: String
    public let entry: String
    public let draft: ArtifactDraft
    public let interrupted: Bool
    public init(
        workspaceID: WorkspaceID, baseRevision: UUID?, title: String, entry: String, draft: ArtifactDraft,
        interrupted: Bool
    ) {
        self.workspaceID = workspaceID
        self.baseRevision = baseRevision
        self.title = title
        self.entry = entry
        self.draft = draft
        self.interrupted = interrupted
    }
}

/// A single-project transaction. References are runtime-created and invalidated only when their file changes.
/// One stream, no queue; callers await append, so content is never dropped under load.
public actor ArtifactEditing {
    public struct Read: Encodable, Sendable {
        public let reference: String
        public let path: String
        public let offset: Int
        public let nextOffset: Int
        public let total: Int
        public let content: String
        public let startLine: Int
        public let version: UInt64
    }
    private struct Selection {
        let path: String
        let start: Int
        let end: Int
        let generation: UInt64
    }
    private struct Stream {
        let id: UUID
        let path: String
        let selection: Selection?
        var content = ""
        var parser: ArtifactContentParser
    }
    private var draft: ArtifactDraft
    private var versions: [String: UInt64] = [:]
    private var references: [String: Selection] = [:]
    private var nextReference: UInt64 = 0
    private var stream: Stream?
    private var closed = false
    public init(draft: ArtifactDraft) { self.draft = draft }
    public func snapshot() -> ArtifactDraft { draft }
    public func read(path: String, offset: Int = 0, limit: Int = 2500) throws -> Read {
        guard !closed else { throw ArtifactWorkspaceError.conflict }
        guard nextReference < UInt64.max else { throw ArtifactWorkspaceError.conflict }
        let text = try draft.read(path, offset: offset, limit: limit)
        nextReference += 1
        let id = "read_\(nextReference)"
        references[id] = Selection(
            path: path, start: offset, end: offset + text.count, generation: versions[path, default: 0])
        return Read(
            reference: id, path: path, offset: offset, nextOffset: offset + text.count,
            total: draft.files[path]?.count ?? 0, content: text,
            startLine: String((draft.files[path] ?? "").prefix(offset)).filter { $0 == "\n" }.count + 1,
            version: versions[path, default: 0])
    }
    /// Line selection is resolved by the host; model never counts Unicode character offsets.
    public func readLines(path: String, line: Int, count: Int) throws -> Read {
        guard let text = draft.files[path] else { throw ArtifactWorkspaceError.missingFile }
        let lines = text.components(separatedBy: "\n")
        guard line > 0, line <= lines.count, count > 0 else {
            throw ArtifactWorkspaceError.invalidReadRange
        }
        let offset = lines.prefix(line - 1).reduce(0) { $0 + $1.count + 1 }
        let length = lines.dropFirst(line - 1).prefix(count).reduce(0) { $0 + $1.count + 1 }
        return try read(path: path, offset: offset, limit: length)
    }
    public func relatedFiles(_ ids: [String]) throws -> [ArtifactEditPreparation.RelatedFile] {
        try ids.map { id in
            guard let ref = references[id], ref.generation == versions[ref.path, default: 0],
                let text = draft.files[ref.path]
            else { throw ArtifactWorkspaceError.readRequired }
            return .init(
                path: ref.path, version: ref.generation, start: ref.start, end: ref.end,
                text: String(text.dropFirst(ref.start).prefix(ref.end - ref.start)))
        }
    }
    private func invalidate(_ path: String) {
        versions[path, default: 0] += 1
        references = references.filter { $0.value.path != path }
    }
    /// Subtree operations are validated as a value before replacing the draft.
    public func relocate(path: String, destination: String?) throws -> ArtifactDraft {
        guard !closed, stream == nil, !path.isEmpty else { throw ArtifactWorkspaceError.conflict }
        let affected = draft.files.keys.filter { $0 == path || $0.hasPrefix(path + "/") }
        guard !affected.isEmpty else { throw ArtifactWorkspaceError.missingFile }
        for file in affected {
            guard
                references.values.contains(where: {
                    $0.path == file && $0.generation == versions[file, default: 0]
                })
            else { throw ArtifactWorkspaceError.readRequired }
        }
        var files = draft.files
        var targets: [String] = []
        for file in affected { files.removeValue(forKey: file) }
        if let destination {
            guard destination != path, !destination.hasPrefix(path + "/") else {
                throw ArtifactWorkspaceError.invalidPath
            }
            for file in affected {
                let target = destination + file.dropFirst(path.count)
                guard draft.files[target] == nil else { throw ArtifactWorkspaceError.existingFile }
                files[target] = draft.files[file]
                targets.append(target)
            }
        }
        let next = try ArtifactDraft(files: files)
        draft = next
        for file in affected + targets { invalidate(file) }
        return next
    }
    public func restore(_ value: ArtifactDraft) throws {
        guard !closed, stream == nil else { throw ArtifactWorkspaceError.busy }
        try value.validate()
        for path in Set(draft.files.keys).union(value.files.keys) where draft.files[path] != value.files[path] {
            invalidate(path)
        }
        draft = value
    }
    public func begin(path: String, reference: String? = nil, start: Int? = nil, end: Int? = nil) throws -> UUID {
        guard !closed else { throw ArtifactWorkspaceError.conflict }
        guard stream == nil else { throw ArtifactWorkspaceError.busy }
        try ArtifactDraft.validatePath(path)
        let selected: Selection?
        if let reference {
            guard let read = references[reference], read.path == path, read.generation == versions[path, default: 0]
            else {
                throw ArtifactWorkspaceError.readRequired
            }
            let lower = start ?? read.start
            let upper = end ?? read.end
            guard lower >= read.start, upper <= read.end, lower <= upper else { throw ArtifactWorkspaceError.conflict }
            selected = Selection(path: path, start: lower, end: upper, generation: versions[path, default: 0])
        } else {
            guard draft.files[path] == nil, start == nil, end == nil else { throw ArtifactWorkspaceError.readRequired }
            selected = nil
        }
        let id = UUID()
        stream = Stream(id: id, path: path, selection: selected, parser: ArtifactContentParser(path: path))
        return id
    }
    public func append(_ chunk: String, to id: UUID) throws {
        guard !closed, var current = stream, current.id == id else { throw ArtifactWorkspaceError.conflict }
        current.content += chunk
        current.parser.append(chunk)
        stream = current
    }
    func preparedEdit(for id: UUID, instruction: String, relatedFiles: [ArtifactEditPreparation.RelatedFile]) throws
        -> ArtifactEditPreparation
    {
        guard let current = stream, current.id == id else { throw ArtifactWorkspaceError.conflict }
        guard let selection = current.selection, let original = draft.files[current.path] else {
            return .init(
                streamID: id.uuidString, path: current.path, instruction: instruction,
                projectFiles: draft.files.keys.sorted(), relatedFiles: relatedFiles)
        }
        let prefix = String(original.prefix(selection.start).suffix(1000))
        let selected = String(original.dropFirst(selection.start).prefix(selection.end - selection.start))
        let suffix = String(original.dropFirst(selection.end).prefix(1000))
        return .init(
            streamID: id.uuidString, path: current.path, instruction: instruction,
            selection: .init(
                start: selection.start, end: selection.end, before: prefix, selected: selected, after: suffix),
            relatedFiles: relatedFiles)
    }
    /// A preview is a copy. Incomplete contents cannot alter the committed draft.
    public func preview(_ id: UUID, checkpointOnly: Bool = false) throws -> ArtifactDraft {
        guard !closed, let current = stream, current.id == id else { throw ArtifactWorkspaceError.conflict }
        var visible = current
        if checkpointOnly { visible.content = current.parser.checkpoint(in: current.content) }
        return try applying(visible)
    }
    public func finish(_ id: UUID) throws -> ArtifactDraft {
        guard !closed, let current = stream, current.id == id else { throw ArtifactWorkspaceError.conflict }
        let next = try applying(current)
        draft = next
        stream = nil
        invalidate(current.path)
        return next
    }
    public func cancel(_ id: UUID) throws {
        guard stream?.id == id else { throw ArtifactWorkspaceError.conflict }
        stream = nil
    }
    /// Exact patch inside a fresh read range. No generated fragment can alter surrounding bytes.
    public func replace(path: String, reference: String, old: String, new: String) throws -> ArtifactDraft {
        guard !closed, stream == nil, let read = references[reference], read.path == path,
            read.generation == versions[path, default: 0], let original = draft.files[path]
        else { throw ArtifactWorkspaceError.readRequired }
        let lower = original.index(original.startIndex, offsetBy: read.start)
        let upper = original.index(original.startIndex, offsetBy: read.end)
        var selected = String(original[lower..<upper])
        guard !old.isEmpty, let match = selected.range(of: old, options: .literal),
            selected.range(
                of: old, options: .literal, range: selected.index(after: match.lowerBound)..<selected.endIndex) == nil
        else { throw ArtifactWorkspaceError.ambiguousMatch }
        selected.replaceSubrange(match, with: new)
        var files = draft.files
        files[path] = String(original[..<lower]) + selected + String(original[upper...])
        let next = try ArtifactDraft(files: files)
        draft = next
        invalidate(path)
        return next
    }
    public func remove(path: String, reference: String) throws -> ArtifactDraft {
        guard !closed, stream == nil, let read = references[reference], read.path == path,
            read.generation == versions[path, default: 0]
        else { throw ArtifactWorkspaceError.readRequired }
        var files = draft.files
        guard files.removeValue(forKey: path) != nil else { throw ArtifactWorkspaceError.missingFile }
        draft = try ArtifactDraft(files: files)
        invalidate(path)
        return draft
    }
    public func close() {
        closed = true
        stream = nil
        references.removeAll()
    }
    private func applying(_ current: Stream) throws -> ArtifactDraft {
        var files = draft.files
        if let selection = current.selection {
            guard selection.generation == versions[current.path, default: 0], let original = files[current.path] else {
                throw ArtifactWorkspaceError.conflict
            }
            let lower = original.index(original.startIndex, offsetBy: selection.start)
            let upper = original.index(original.startIndex, offsetBy: selection.end)
            files[current.path] = String(original[..<lower]) + current.content + String(original[upper...])
        } else {
            guard files[current.path] == nil else { throw ArtifactWorkspaceError.existingFile }
            files[current.path] = current.content
        }
        return try ArtifactDraft(files: files)
    }
}

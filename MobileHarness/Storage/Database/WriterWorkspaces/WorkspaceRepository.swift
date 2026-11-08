import Foundation
import StorageCore

/// Current file index only. No source bodies or historical versions are persisted here.
public struct WorkspaceFile: Sendable, Equatable {
    public let path: String
    public let bytes: Int
    public let fingerprint: String
    public init(path: String, bytes: Int, fingerprint: String) {
        self.path = path
        self.bytes = bytes
        self.fingerprint = fingerprint
    }
}
public struct WorkspaceSummary: Sendable {
    public let id: WorkspaceID
    public let title: String
    public let entry: String
    /// Invalidation token for current content; never an addressable historical version.
    public let revision: UUID?
    public let hasDraft: Bool
    public let deleting: Bool
    public let files: [WorkspaceFile]
    public let needsIndexRecovery: Bool
    public init(
        id: WorkspaceID, title: String, entry: String, revision: UUID?, hasDraft: Bool, deleting: Bool,
        files: [WorkspaceFile] = [], needsIndexRecovery: Bool = false
    ) {
        self.id = id
        self.title = title
        self.entry = entry
        self.revision = revision
        self.hasDraft = hasDraft
        self.deleting = deleting
        self.files = files
        self.needsIndexRecovery = needsIndexRecovery
    }
}
public protocol WorkspaceRepository: Sendable {
    func directory() async throws -> [WorkspaceSummary]
    func search(_ query: String, before: String?) async throws -> (matches: [WorkspaceSummary], nextBefore: String?)
    func workspace(_ id: WorkspaceID) async throws -> WorkspaceSummary?
    /// Claim fences simultaneous file writers; a crash leaves index recovery required.
    func claim(_ id: WorkspaceID, expecting: UUID?, lease: UUID) async throws
    func commit(_ value: WorkspaceSummary, lease: UUID) async throws
    func release(_ id: WorkspaceID, lease: UUID) async throws
    func markDeleting(_ id: WorkspaceID) async throws
    func finishDeleting(_ id: WorkspaceID) async throws
}

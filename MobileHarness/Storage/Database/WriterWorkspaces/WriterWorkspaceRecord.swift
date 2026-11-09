import Foundation

/// Stable workspace metadata. Execution state belongs exclusively to delegation messages.
public struct WriterWorkspaceRecord: Codable, Sendable, Identifiable {
    public var workspaceReady = false
    public let workspaceID: String
    public var id: String { workspaceID }
    public let title: String
    public let status: String
    public let updatedAt: Date

    public init(workspaceID: String, title: String, status: String, updatedAt: Date) {
        self.workspaceID = workspaceID
        self.title = title
        self.status = status
        self.updatedAt = updatedAt
    }
}

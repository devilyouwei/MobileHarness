import Foundation
import StorageCore

/// Stable workspace metadata. Execution state belongs exclusively to delegation messages.
public struct WriterWorkspaceRecord: Codable, Sendable, Identifiable {
    public var workspaceReady: Bool = false
    public let id: String
    public let dialogID: String
    public let goal: String
    public let agentID: String
    public var workspaceID: String { agentID + "/" + id }
    public let status: String
    public let updatedAt: Date
    public init(
        id: String, dialogID: String, goal: String, agentID: String, status: String,
        updatedAt: Date
    ) {
        self.id = id
        self.dialogID = dialogID
        self.goal = goal
        self.agentID = agentID
        self.status = status
        self.updatedAt = updatedAt
    }
}

import Foundation

public struct WriterHistoryMetadata: Sendable {
    public let traceID: UUID
    public let id: String
    public let createdAt: Date
    public let archivedAt: Date?
    public let title: String?
    public let titleError: String?
    public let revision: UInt64
    public let count: Int
    public let latestUser: String?
    public init(
        id: String, createdAt: Date, archivedAt: Date?, title: String?, titleError: String?,
        revision: UInt64, count: Int, latestUser: String?, traceID: UUID = UUID()
    ) {
        self.id = id
        self.traceID = traceID
        self.createdAt = createdAt
        self.archivedAt = archivedAt
        self.title = title
        self.titleError = titleError
        self.revision = revision
        self.count = count
        self.latestUser = latestUser
    }
}

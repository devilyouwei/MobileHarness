import Foundation
import StorageChat
import StorageCore
import StorageDatabase
import StorageDevices
import StorageFiles
import StorageMedia
import StorageTasks

public final class SQLiteRepositories: Sendable {
    let database: SQLiteDatabase
    public let assistantConversations: SQLiteAssistantConversationRepository
    public let assistantMessages: SQLiteAssistantMessageRepository
    public let assistantTasks: SQLiteAssistantTaskRepository
    public let writerMessages: SQLiteWriterMessageRepository
    public let writerExecutions: SQLiteWriterExecutionRepository
    public let agentMessages: SQLiteAgentMessageRepository
    public let logs: SQLiteModelRequestLogRepository
    public let media: SQLiteMediaRepository
    public let workspaces: SQLiteWorkspaceRepository
    public let devices: SQLiteDeviceRepository
    var lastWriteChanges: Int { database.lastWriteChanges }
    var committedWriteCount: Int { database.committedWriteCount }
    public init(
        url: URL, removeOnClose: Bool = false, failures: StorageFailureReporter = .init(),
        resetWriterFilesAt: URL? = nil
    ) throws {
        let database = try SQLiteDatabase(url: url, removeOnClose: removeOnClose, failures: failures)
        do {
            try database.prepareSchema { try SQLiteSchema.prepare($0, resetWriterFilesAt: resetWriterFilesAt) }
        } catch {
            let primary = error
            do { try database.closeUnpublished() } catch {
                throw StorageFailure(
                    component: "database", operation: "prepare", underlying: primary, cleanupErrors: [error])
            }
            throw primary
        }
        self.database = database
        assistantConversations = SQLiteAssistantConversationRepository(database: database)
        assistantMessages = SQLiteAssistantMessageRepository(database: database)
        assistantTasks = SQLiteAssistantTaskRepository(database: database)
        writerMessages = SQLiteWriterMessageRepository(database: database)
        writerExecutions = SQLiteWriterExecutionRepository(database: database)
        agentMessages = SQLiteAgentMessageRepository(database: database)
        logs = SQLiteModelRequestLogRepository(database: database)
        media = SQLiteMediaRepository(database: database)
        devices = SQLiteDeviceRepository(database: database)
        workspaces = SQLiteWorkspaceRepository(database: database)
    }
    public static func temporary() throws -> SQLiteRepositories {
        try SQLiteRepositories(
            url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite"),
            removeOnClose: true)
    }
    public func recoverInFlight() throws {
        try assistantTasks.recoverInFlight()
        try writerExecutions.recoverInFlight()
        try assistantMessages.recoverInFlight()
        try writerMessages.recoverInFlight()
    }
    func beginClosing() { database.beginClosing() }
    public func shutdown() async throws { try await database.shutdown() }
}

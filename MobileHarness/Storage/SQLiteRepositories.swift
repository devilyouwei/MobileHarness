import Foundation
import Storage
import StorageChat
import StorageDevices
import StorageMedia
import StorageTasks

public final class SQLiteRepositories: Sendable {
    private let database: SQLiteDatabase
    public let chat: SQLiteChatRepository
    public let tasks: SQLiteTaskRepository
    public let media: SQLiteMediaRepository
    public let devices: SQLiteDeviceRepository
    var lastWriteChanges: Int { database.lastWriteChanges }
    var committedWriteCount: Int { database.committedWriteCount }
    public init(url: URL, removeOnClose: Bool = false) throws {
        let database = try SQLiteDatabase(url: url, removeOnClose: removeOnClose)
        try database.migrate([
            (
                "records-v1",
                [
                    SQLiteChatRepository.schemaSQL, SQLiteTaskRepository.schemaSQL, SQLiteMediaRepository.schemaSQL,
                    SQLiteDeviceRepository.schemaSQL,
                ]
            ),
            (
                "record-lifecycle-v2",
                [
                    "CREATE INDEX message_active ON messages(id) WHERE state='generating'",
                    "CREATE INDEX task_active ON tasks(id) WHERE status IN ('running','finishing')",
                ]
            ),
        ])
        self.database = database
        chat = SQLiteChatRepository(database: database)
        tasks = SQLiteTaskRepository(database: database)
        media = SQLiteMediaRepository(database: database)
        devices = SQLiteDeviceRepository(database: database)
    }
    public static func temporary() throws -> SQLiteRepositories {
        try SQLiteRepositories(
            url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite"),
            removeOnClose: true)
    }
    public func recoverInFlight() throws {
        try tasks.recoverInFlight()
        try chat.recoverInFlight()
    }
}

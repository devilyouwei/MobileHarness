import Foundation
import StorageChat
import StorageCore
import StorageDevices
import StorageMedia
import StorageTasks

public final class SQLiteRepositories: Sendable {
    let database: SQLiteDatabase
    public let chat: SQLiteChatRepository
    public let tasks: SQLiteTaskRepository
    public let media: SQLiteMediaRepository
    public let devices: SQLiteDeviceRepository
    var lastWriteChanges: Int { database.lastWriteChanges }
    var committedWriteCount: Int { database.committedWriteCount }
    public init(url: URL, removeOnClose: Bool = false, failures: StorageFailureReporter = .init()) throws {
        let database = try SQLiteDatabase(url: url, removeOnClose: removeOnClose, failures: failures)
        do {
            try database.prepareSchema([
                SQLiteChatRepository.schemaSQL, SQLiteTaskRepository.schemaSQL,
                SQLiteMediaRepository.schemaSQL, SQLiteDeviceRepository.schemaSQL,
            ])
            try SQLiteTaskRepository.prepareNotifications(database)
        } catch {
            let primary = error
            do { try database.closeUnpublished() } catch {
                throw StorageFailure(
                    component: "database", operation: "prepare", underlying: primary, cleanupErrors: [error])
            }
            throw primary
        }
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
    func beginClosing() { database.beginClosing() }
    public func shutdown() async throws { try await database.shutdown() }
}

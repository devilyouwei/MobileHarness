import Foundation
internal import GRDB
import StorageChat
import StorageCore
import StorageTasks

public final class SQLiteAssistantTaskRepository: AssistantTaskRepository, AssistantTaskSummaryRepository {
    public var storageScope: UUID { database.storageScope }
    let database: SQLiteDatabase
    init(database: SQLiteDatabase) { self.database = database }
    internal func recoverInFlight() throws { try database.write { try Self.recoverAssistantTasks($0) } }
}

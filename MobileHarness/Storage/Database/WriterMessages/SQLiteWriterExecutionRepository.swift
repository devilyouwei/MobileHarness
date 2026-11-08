import Foundation
internal import GRDB
import StorageCore
import StorageTasks

public final class SQLiteWriterExecutionRepository: WriterExecutionRepository {
    public var storageScope: UUID { database.storageScope }
    let database: SQLiteDatabase
    init(database: SQLiteDatabase) { self.database = database }
    internal func recoverInFlight() throws { try database.write { try Self.recoverWriterExecutions($0) } }
}

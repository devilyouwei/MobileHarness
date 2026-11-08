import Foundation
internal import GRDB
import StorageChat
import StorageCore

public final class SQLiteModelRequestLogRepository: ModelRequestLogRepository {
    public var storageScope: UUID { database.storageScope }
    let database: SQLiteDatabase
    init(database: SQLiteDatabase) { self.database = database }
}

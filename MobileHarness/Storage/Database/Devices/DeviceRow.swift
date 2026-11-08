import Foundation
internal import GRDB

/// The persisted columns and schema owned by devices; never exposed to application consumers.
struct DeviceRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "devices"
    static let schemaSQL = """
        CREATE TABLE devices(id INTEGER PRIMARY KEY AUTOINCREMENT, native_id TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL, selected INTEGER NOT NULL DEFAULT 0, reconnect INTEGER NOT NULL DEFAULT 0);
        CREATE UNIQUE INDEX selected_device ON devices(selected) WHERE selected=1;
        """
    var id: Int64? = nil
    var nativeID: String
    var name: String
    var selected: Int64 = 0
    var reconnect: Int64 = 0
    enum CodingKeys: String, CodingKey {
        case id
        case nativeID = "native_id"
        case name
        case selected
        case reconnect
    }
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

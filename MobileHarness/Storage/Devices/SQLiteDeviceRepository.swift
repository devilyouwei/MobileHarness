import Foundation
internal import GRDB
import Storage
import StorageDevices

public final class SQLiteDeviceRepository: DeviceRepository {
    private let database: SQLiteDatabase
    internal init(database: SQLiteDatabase) { self.database = database }
    internal static let schemaSQL = """
        CREATE TABLE devices(id INTEGER PRIMARY KEY AUTOINCREMENT, native_id TEXT NOT NULL UNIQUE,
                                name TEXT NOT NULL, selected INTEGER NOT NULL DEFAULT 0, reconnect INTEGER NOT NULL DEFAULT 0);
        CREATE UNIQUE INDEX selected_device ON devices(selected) WHERE selected=1;
        """
    public func device(nativeID: String, name: String) throws -> String {
        try database.write { db in
            try db.execute(
                sql:
                    "INSERT INTO devices(native_id,name) VALUES(?,?) ON CONFLICT(native_id) DO UPDATE SET name=excluded.name",
                arguments: [nativeID, name])
            guard
                let key = try Int64.fetchOne(db, sql: "SELECT id FROM devices WHERE native_id=?", arguments: [nativeID])
            else { throw RecordStorageError.missingRecord }
            return SQLiteRecordKey.id(.device, key)
        }
    }
    public func nativeDevice(_ id: String) throws -> String {
        let key = try BusinessRecordID.number(id, kind: .device)
        return try database.read { db in
            guard
                let native = try String.fetchOne(db, sql: "SELECT native_id FROM devices WHERE id=?", arguments: [key])
            else { throw RecordStorageError.missingRecord }
            return native
        }
    }
    public func selectedDevice() throws -> (id: String, name: String, reconnect: Bool)? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM devices WHERE selected=1") else { return nil }
            return (SQLiteRecordKey.id(.device, row["id"]), row["name"], row["reconnect"] as Bool)
        }
    }
    public func selectDevice(_ id: String?, reconnect: Bool) throws {
        let key = try id.map { try BusinessRecordID.number($0, kind: .device) }
        try database.write { db in
            try db.execute(sql: "UPDATE devices SET selected=0,reconnect=0 WHERE selected=1")
            if let key {
                try db.execute(
                    sql: "UPDATE devices SET selected=1,reconnect=? WHERE id=?", arguments: [reconnect, key])
                guard db.changesCount == 1 else { throw RecordStorageError.missingRecord }
            }
        }
    }
}

import Foundation
internal import GRDB
import StorageCore

enum SQLiteRecordCoding {
    static func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    static func object(_ value: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else {
            throw RecordStorageError.invalidRecord
        }
        return object
    }
    static func payload(_ data: Data) throws -> [String: Any] {
        data.isEmpty ? [:] : try object(String(decoding: data, as: UTF8.self))
    }
    static func allocateMessage(_ db: Database) throws -> Int64 {
        let previous = try Int64.fetchOne(db, sql: "SELECT seq FROM sqlite_sequence WHERE name='business_message'") ?? 0
        guard previous < Int64.max else { throw RecordStorageError.invalidRecord }
        let key = previous + 1
        try db.execute(sql: "DELETE FROM sqlite_sequence WHERE name='business_message'")
        try db.execute(sql: "INSERT INTO sqlite_sequence(name,seq) VALUES('business_message',?)", arguments: [key])
        return key
    }
    static func key(_ id: String) throws -> Int64 {
        guard let value = BusinessRecordID(rawValue: id), [.message, .request].contains(value.kind) else {
            throw RecordStorageError.invalidID
        }
        return value.number
    }
}

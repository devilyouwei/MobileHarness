import Foundation
import StorageCore

internal enum SQLiteRecordKey {
    static func id(_ kind: BusinessRecordID.Kind, _ number: Int64) -> String { "\(kind.rawValue)_\(number)" }
    static func traceIdentity(_ key: Int64, namespace: UInt8) -> UUID {
        let n = UInt64(key)
        return UUID(
            uuid: (
                0, 0, 0, 0, 0, 0, 0, namespace, UInt8(truncatingIfNeeded: n >> 56),
                UInt8(truncatingIfNeeded: n >> 48), UInt8(truncatingIfNeeded: n >> 40),
                UInt8(truncatingIfNeeded: n >> 32), UInt8(truncatingIfNeeded: n >> 24),
                UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)
            ))
    }
}

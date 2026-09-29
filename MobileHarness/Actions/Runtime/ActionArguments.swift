import Foundation

/// Transport decoding only. Domain meaning, permissions and defaults belong to each Action.
public struct ActionArguments: Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidKeys
        case missing(String)
        case invalidValue(String)
    }

    private let values: [String: String]

    public init(_ values: [String: String]) { self.values = values }

    public func validateAllowedKeys(_ allowed: Set<String>) throws {
        guard Set(values.keys).isSubset(of: allowed) else { throw ValidationError.invalidKeys }
    }

    public func requiredString(_ key: String, maximumUTF8Bytes: Int, allowBlank: Bool = false) throws -> String {
        guard let value = values[key] else { throw ValidationError.missing(key) }
        guard value.utf8.count <= maximumUTF8Bytes,
            allowBlank || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ValidationError.invalidValue(key) }
        return value
    }

    public func requiredInt(_ key: String, range: ClosedRange<Int>) throws -> Int {
        let raw = try requiredString(key, maximumUTF8Bytes: 4096)
        guard let value = Int(raw), range.contains(value) else { throw ValidationError.invalidValue(key) }
        return value
    }

    public func requiredFiniteDouble(_ key: String, range: ClosedRange<Double>) throws -> Double {
        let raw = try requiredString(key, maximumUTF8Bytes: 4096)
        guard let value = Double(raw), value.isFinite, range.contains(value) else {
            throw ValidationError.invalidValue(key)
        }
        return value
    }

    public func requiredEnum<Value: RawRepresentable & Sendable>(_ key: String, as type: Value.Type) throws -> Value
    where Value.RawValue == String {
        let raw = try requiredString(key, maximumUTF8Bytes: 4096)
        guard let value = Value(rawValue: raw) else { throw ValidationError.invalidValue(key) }
        return value
    }
}

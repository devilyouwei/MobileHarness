import Foundation

/// A committed business reference; formatting never allocates an identifier.
public struct BusinessRecordID: RawRepresentable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case dialog, message, task, media, device }
    public let kind: Kind
    public let number: Int64
    public var rawValue: String { "\(kind.rawValue)_\(number)" }
    public init?(rawValue: String) {
        let parts = rawValue.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 2, let kind = Kind(rawValue: String(parts[0])),
            let number = Int64(parts[1]), number > 0, String(number) == parts[1]
        else { return nil }
        self.kind = kind
        self.number = number
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid business reference")
        }
        self = value
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public static func parse(_ raw: String) -> String? { Self(rawValue: raw)?.rawValue }
    internal init(kind: Kind, number: Int64) {
        self.kind = kind
        self.number = number
    }
    public static func number(_ id: String, kind: BusinessRecordID.Kind) throws -> Int64 {
        guard let value = BusinessRecordID(rawValue: id), value.kind == kind else {
            throw RecordStorageError.invalidID
        }
        return value.number
    }
}

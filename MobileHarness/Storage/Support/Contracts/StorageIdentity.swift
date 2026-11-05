import Foundation

/// A committed business reference; formatting never allocates an identifier.
public struct BusinessRecordID: RawRepresentable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case dialog, message, request, task, media, device }
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

/// Stable agent-owned workspace identity. Never accepts an absolute path or caller-supplied directory.
public struct WorkspaceID: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public let agent: String
    public let taskID: String
    public var rawValue: String { agent + "/" + taskID }
    public init?(rawValue: String) {
        let parts = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        self.init(agent: String(parts[0]), taskID: String(parts[1]))
    }
    public init?(agent: String, taskID: String) {
        guard !agent.isEmpty, agent.utf8.count <= 64,
            agent.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
            BusinessRecordID(rawValue: taskID)?.kind == .task
        else { return nil }
        self.agent = agent
        self.taskID = taskID
    }
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        guard let id = Self(rawValue: try value.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid workspace identity")
        }
        self = id
    }
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(rawValue)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

import Foundation

/// One preset variable declared by an Agent's `states` configuration. Executable behavior is bound by name in Swift.
public struct AgentStateDeclaration: Decodable, Sendable, Equatable {
    public enum Kind: String, Decodable, Sendable { case typed, semantic }
    public enum Access: String, Decodable, Sendable { case readWrite, readOnly }
    public enum ValueType: String, Decodable, Sendable { case bool, `enum`, text }

    public let name: String
    public let kind: Kind
    public let access: Access
    public let type: ValueType
    public let values: [String]
    public let meaning: String
    public let trigger: String?

    private enum CodingKeys: String, CodingKey { case name, kind, access, type, values, meaning, trigger }
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: Key.self).allKeys.map(\.stringValue)
        guard Set(keys).isSubset(of: ["name", "kind", "access", "type", "values", "meaning", "trigger"]),
            Set(keys).isSuperset(of: ["name", "kind", "access", "type", "meaning"])
        else { throw AgentStateError.invalidDeclaration }
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        name = try fields.decode(String.self, forKey: .name)
        kind = try fields.decode(Kind.self, forKey: .kind)
        access = try fields.decode(Access.self, forKey: .access)
        type = try fields.decode(ValueType.self, forKey: .type)
        values = try fields.decodeIfPresent([String].self, forKey: .values) ?? []
        meaning = try fields.decode(String.self, forKey: .meaning)
        trigger = try fields.decodeIfPresent(String.self, forKey: .trigger)
        try validate()
    }

    public func validate() throws {
        guard AgentStateVariables.validName(name),
            !meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, meaning.utf8.count <= 1024,
            type == .enum
                ? !values.isEmpty && values.count <= 16 && Set(values).count == values.count
                    && values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }) : values.isEmpty,
            kind == .typed || type == .text,
            trigger.map({ AgentStateVariables.validName($0.replacingOccurrences(of: ".", with: "_")) }) ?? true
        else { throw AgentStateError.invalidDeclaration }
    }

    /// Normalizes a value according to its type; the stored form is always a string.
    func parse(_ raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .bool:
            guard let value = ["true": "true", "false": "false"][text.lowercased()] else {
                throw AgentStateError.invalidValue(name)
            }
            return value
        case .enum:
            guard values.contains(text) else { throw AgentStateError.invalidValue(name) }
            return text
        case .text:
            guard !text.isEmpty else { throw AgentStateError.invalidValue(name) }
            return text
        }
    }
}

public enum AgentStateError: Error, Equatable, Sendable {
    case invalidDeclaration
    case invalidName(String)
    case readOnly(String)
    case invalidValue(String)
    case valueTooLong(String)
    case unknownVariable(String)
    /// Clearing or replacing a variable that drives a process needs a summary of what happened.
    case noteRequired(String)
    /// The variable's process cannot end and restart inside one call in the current mode.
    case replacementUnavailable(String)
}

/// Who wrote a variable. Models are limited by `access`; the host and Agent code are not.
public enum AgentStateSource: String, Codable, Sendable { case model, host }

/// The change one write made. `old == new` means the value was re-asserted and only its time moved.
public struct AgentStateChange: Codable, Sendable, Equatable {
    public let name: String
    public let old: String?
    public let new: String?
    public let note: String?
    public let source: AgentStateSource
    public let date: Date
    public var changed: Bool { old != new }
}

/// An Agent's own variable table: string values with write times, bounded in memory.
///
/// Declared variables are never evicted. Free (undeclared) semantic variables share a count and byte budget; a write
/// that would exceed it evicts the earliest-written free variables instead of failing.
public struct AgentStateVariables: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public let value: String
        public let writtenAt: Date
        let sequence: UInt64
    }
    public static let maximumFreeVariables = 32
    public static let maximumValueBytes = 1024
    public static let maximumFreeBytes = 8 * 1024

    public private(set) var entries: [String: Entry] = [:]
    private var sequence: UInt64 = 0
    public init() {}

    /// Lowercase letter first, then lowercase letters, digits or `_`; no namespace separators.
    public static func validName(_ name: String) -> Bool {
        guard (1...32).contains(name.utf8.count), let first = name.utf8.first, (97...122).contains(first) else {
            return false
        }
        return name.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }

    /// Variables in write order, earliest first.
    public var ordered: [(name: String, entry: Entry)] {
        entries.map { ($0.key, $0.value) }.sorted {
            ($0.entry.writtenAt, $0.entry.sequence, $0.name) < ($1.entry.writtenAt, $1.entry.sequence, $1.name)
        }
    }

    /// A copy that also shows a value another owner keeps (such as the active task goal). For rendering and reads only.
    public func showing(_ name: String, value: String?, writtenAt: Date) -> AgentStateVariables {
        var copy = self
        copy.entries[name] = value.map { Entry(value: $0, writtenAt: writtenAt, sequence: 0) }
        return copy
    }

    public func value(_ name: String) -> String? { entries[name]?.value }

    /// Checks a write without storing it: name, writer permission, type and size. Returns the normalized value.
    public static func normalized(
        _ name: String, _ raw: String, source: AgentStateSource, schema: AgentStateSchema
    ) throws -> String {
        try checkWritable(name, source: source, schema: schema)
        let declaration = schema.declarations[name]
        if declaration == nil, source != .model { throw AgentStateError.unknownVariable(name) }
        let value = try declaration?.parse(raw) ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AgentStateError.invalidValue(name) }
        guard value.utf8.count <= maximumValueBytes else { throw AgentStateError.valueTooLong(name) }
        return value
    }

    /// Models cannot write read-only variables; the host and Agent code can.
    public static func checkWritable(_ name: String, source: AgentStateSource, schema: AgentStateSchema) throws {
        guard validName(name) else { throw AgentStateError.invalidName(name) }
        if source == .model, schema.declarations[name]?.access == .readOnly { throw AgentStateError.readOnly(name) }
    }

    @discardableResult
    public mutating func set(
        _ name: String, _ raw: String, source: AgentStateSource, schema: AgentStateSchema, note: String? = nil,
        at date: Date = Date()
    ) throws -> AgentStateChange {
        let value = try Self.normalized(name, raw, source: source, schema: schema)
        let old = entries[name]?.value
        var next = self
        next.sequence += 1
        next.entries[name] = Entry(value: value, writtenAt: date, sequence: next.sequence)
        if schema.declarations[name] == nil { next.evict(keeping: name, schema: schema) }
        self = next
        return AgentStateChange(name: name, old: old, new: value, note: note, source: source, date: date)
    }

    /// Clearing an unset variable is a no-op that reports no change.
    @discardableResult
    public mutating func clear(
        _ name: String, source: AgentStateSource, schema: AgentStateSchema, note: String? = nil, at date: Date = Date()
    ) throws -> AgentStateChange? {
        try Self.checkWritable(name, source: source, schema: schema)
        guard let old = entries.removeValue(forKey: name)?.value else { return nil }
        return AgentStateChange(name: name, old: old, new: nil, note: note, source: source, date: date)
    }

    private mutating func evict(keeping name: String, schema: AgentStateSchema) {
        func free() -> [(name: String, entry: Entry)] {
            entries.filter { schema.declarations[$0.key] == nil }.map { ($0.key, $0.value) }
                .sorted { $0.entry.sequence < $1.entry.sequence }
        }
        while free().count > Self.maximumFreeVariables
            || free().reduce(0, { $0 + $1.name.utf8.count + $1.entry.value.utf8.count }) > Self.maximumFreeBytes,
            let oldest = free().first(where: { $0.name != name })
        {
            entries[oldest.name] = nil
        }
    }

    /// Drops variables that the schema no longer declares only when they were typed; free variables are kept.
    public func validate(schema: AgentStateSchema) throws {
        for (name, entry) in entries {
            guard Self.validName(name), entry.value.utf8.count <= Self.maximumValueBytes else {
                throw AgentStateError.invalidName(name)
            }
            if let declaration = schema.declarations[name] { _ = try declaration.parse(entry.value) }
        }
    }
}

/// Behavior bound to a variable by name. Declared in `Agent.json` as `trigger`; the handler lives in the owning Agent.
public enum AgentStateTrigger: String, Sendable {
    /// A change of `task` opens or closes a goal interval and compresses the history it covered.
    case task
}

/// An Agent's declared variables, built once from `Agent.json` at configuration load.
public struct AgentStateSchema: Sendable, Equatable {
    public static let maximumDeclarations = 16
    public let declarations: [String: AgentStateDeclaration]
    public init(_ declarations: [AgentStateDeclaration] = []) throws {
        guard declarations.count <= Self.maximumDeclarations, Set(declarations.map(\.name)).count == declarations.count,
            declarations.allSatisfy({ $0.trigger.map { AgentStateTrigger(rawValue: $0) != nil } ?? true })
        else { throw AgentStateError.invalidDeclaration }
        self.declarations = Dictionary(uniqueKeysWithValues: declarations.map { ($0.name, $0) })
    }
    public func declaration(boundTo trigger: AgentStateTrigger) -> AgentStateDeclaration? {
        declarations.values.first { $0.trigger == trigger.rawValue }
    }
}

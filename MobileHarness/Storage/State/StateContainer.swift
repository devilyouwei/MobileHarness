import Foundation
import StorageCore
import Synchronization

public enum StateError: Error, Equatable, Sendable {
    case duplicate, typeMismatch, conflict, closed, missing, capacityExceeded, invalidKey, invalidPublication
}
public enum StateScopeKind: String, Codable, Sendable { case application, conversation }
public enum StateDomain: Sendable, Hashable {
    case application
    case conversation(agent: String, session: String)
    public var kind: StateScopeKind {
        switch self {
        case .application: .application
        case .conversation: .conversation
        }
    }
}
public struct StateDeclaration: Sendable {
    public let name: String
    public let scope: StateScopeKind
    public init(_ name: String, scope: StateScopeKind) {
        self.name = name
        self.scope = scope
    }
}
public enum StateAvailability: String, Codable, Sendable { case unknown, available, unavailable }
public struct PublishedState<Value: Encodable & Sendable>: Encodable, Sendable {
    public let availability: StateAvailability
    public let value: Value?
    public init(_ value: Value? = nil, availability: StateAvailability = .available) {
        self.value = value
        self.availability = availability
    }
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(availability, forKey: .availability)
        if let value { try fields.encode(value, forKey: .value) } else { try fields.encodeNil(forKey: .value) }
    }
    private enum CodingKeys: String, CodingKey { case availability, value }
}
public struct StateContextSnapshot: Sendable {
    public let revision: UInt64
    public let json: String
}
public protocol StateContextReading: Sendable {
    func snapshot(names: [String]) throws -> StateContextSnapshot
}
private struct BoundStateContext: StateContextReading {
    let container: StateContainer
    let domain: StateDomain
    let scopeID: UUID?
    func snapshot(names: [String]) throws -> StateContextSnapshot {
        try container.contextSnapshot(names: names, domain: domain, scopeID: scopeID)
    }
}
public struct StateKey<Value: Sendable>: Sendable, Hashable {
    public let name: String
    public init(_ name: String) { self.name = name }
}
public struct StateValue<Value: Sendable>: Sendable {
    public let value: Value
    public let revision: UInt64
    public let generation: UUID
}
public struct StateChange: Sendable { public let revision: UInt64 }

private struct StateToken: Sendable, Hashable {
    let scope: UUID
    let name: String
    let generation: UUID
}
public struct StateSelection: Sendable {
    fileprivate let container: StateContainer
    fileprivate let token: StateToken
}
public struct StateSnapshot: Sendable {
    public let revision: UInt64
    fileprivate let values: [StateToken: StateEntry]
    public func get<Value>(_ reader: StateReader<Value>) throws -> StateValue<Value> {
        guard let entry = values[reader.token], let value = entry.value as? Value else { throw StateError.missing }
        return StateValue(value: value, revision: entry.revision, generation: reader.token.generation)
    }
}
private struct StateEntry: Sendable {
    var value: any Sendable
    var revision: UInt64
    let type: ObjectIdentifier
    let validate: @Sendable (any Sendable) throws -> Void
    let encode: @Sendable (any Sendable) throws -> Data
    var encoded: Data
    var valid = true
}

/// Read capability for exactly one registered generation.
public struct StateReader<Value: Sendable>: Sendable {
    fileprivate let container: StateContainer
    fileprivate let token: StateToken
    public var selection: StateSelection { StateSelection(container: container, token: token) }
    public func get() throws -> StateValue<Value> { try container.get(token) }
    public func observe() throws -> AsyncThrowingStream<StateChange, any Error> {
        try container.observe([selection])
    }
}
/// Exclusive owner capability. Closures must be pure, synchronous and non-reentrant.
public struct StateWriter<Value: Sendable>: Sendable {
    public let reader: StateReader<Value>
    public func get() throws -> StateValue<Value> { try reader.get() }
    public func set(_ value: Value, expecting revision: UInt64) throws {
        try transition(expecting: revision) { $0 = value }
    }
    @discardableResult
    public func transition<Result: Sendable>(
        expecting revision: UInt64, _ mutation: @Sendable (inout Value) throws -> Result
    ) throws -> Result { try reader.container.transition(reader.token, expecting: revision, mutation) }
    public func unregister() { reader.container.unregister(reader.token) }
    public func invalidate() { reader.container.invalidate(reader.token) }
}
public final class StateScope: Sendable {
    public let id: UUID
    fileprivate let container: StateContainer
    fileprivate init(id: UUID, container: StateContainer) {
        self.id = id
        self.container = container
    }
    public func register<Value: Encodable>(
        _ key: StateKey<Value>, initial: Value, validate: @escaping @Sendable (Value) throws -> Void = { _ in }
    ) throws -> StateWriter<Value> {
        try container.register(scope: id, key: key, initial: initial, validate: validate)
    }
    public func close() { container.closeScope(id) }
    deinit { container.closeScope(id) }
}

/// One lock defines atomic value/projection publication. Validators and encoders are synchronous and pure.
public final class StateContainer: Sendable {
    public struct Limits: Sendable {
        public let registrations: Int
        public let scopes: Int
        public let observers: Int
        public init(registrations: Int = 256, scopes: Int = 64, observers: Int = 64) {
            self.registrations = registrations
            self.scopes = scopes
            self.observers = observers
        }
    }
    private struct Observer: Sendable {
        let tokens: Set<StateToken>
        let continuation: AsyncThrowingStream<StateChange, any Error>.Continuation
    }
    private struct State: Sendable {
        var closed = false
        var revision: UInt64 = 0
        var scopes: [UUID: StateDomain] = [:]
        var declarations: [String: StateScopeKind] = [:]
        var entries: [StateToken: StateEntry] = [:]
        var observers: [UUID: Observer] = [:]
    }
    private let state = Mutex(State())
    private let limits: Limits
    public init(limits: Limits = Limits()) { self.limits = limits }
    public func makeScope(domain: StateDomain = .application) throws -> StateScope {
        if case .conversation(let agent, let session) = domain {
            guard !agent.isEmpty, !session.isEmpty, agent.utf8.count <= 256, session.utf8.count <= 256 else {
                throw StateError.invalidKey
            }
        }
        return try state.withLock { state in
            guard !state.closed else { throw StateError.closed }
            guard state.scopes.count < limits.scopes else { throw StateError.capacityExceeded }
            let id = UUID()
            state.scopes[id] = domain
            return StateScope(id: id, container: self)
        }
    }
    fileprivate func register<Value: Encodable>(
        scope: UUID, key: StateKey<Value>, initial: Value,
        validate: @escaping @Sendable (Value) throws -> Void
    ) throws -> StateWriter<Value> {
        guard !key.name.isEmpty, key.name.utf8.count <= 256 else { throw StateError.invalidKey }
        try validate(initial)
        let encoder: @Sendable (any Sendable) throws -> Data = { raw in
            guard let value = raw as? Value else { throw StateError.typeMismatch }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(value)
            guard data.count <= 8192 else { throw StateError.capacityExceeded }
            return data
        }
        let encoded = try encoder(initial)
        return try state.withLock { state in
            guard !state.closed, state.scopes[scope] != nil else { throw StateError.closed }
            guard let domain = state.scopes[scope] else { throw StateError.closed }
            if let declared = state.declarations[key.name], declared != domain.kind { throw StateError.typeMismatch }
            if let existing = state.entries.first(where: {
                state.scopes[$0.key.scope] == domain && $0.key.name == key.name
            }) {
                throw existing.value.type == ObjectIdentifier(Value.self)
                    ? StateError.duplicate : StateError.typeMismatch
            }
            guard state.entries.count < limits.registrations, state.revision < UInt64.max else {
                throw StateError.capacityExceeded
            }
            guard state.declarations[key.name] != nil || state.declarations.count < limits.registrations else {
                throw StateError.capacityExceeded
            }
            state.declarations[key.name] = domain.kind
            state.revision += 1
            let token = StateToken(scope: scope, name: key.name, generation: UUID())
            state.entries[token] = StateEntry(
                value: initial, revision: state.revision, type: ObjectIdentifier(Value.self),
                validate: { raw in
                    guard let value = raw as? Value else { throw StateError.typeMismatch }
                    try validate(value)
                }, encode: encoder, encoded: encoded)
            return StateWriter(reader: StateReader(container: self, token: token))
        }
    }
    fileprivate func get<Value>(_ token: StateToken) throws -> StateValue<Value> {
        try state.withLock { state in
            guard !state.closed, state.scopes[token.scope] != nil else { throw StateError.closed }
            guard let entry = state.entries[token] else { throw StateError.missing }
            guard let value = entry.value as? Value else { throw StateError.typeMismatch }
            return StateValue(value: value, revision: entry.revision, generation: token.generation)
        }
    }
    fileprivate func transition<Value, Result>(
        _ token: StateToken, expecting revision: UInt64, _ mutation: @Sendable (inout Value) throws -> Result
    ) throws -> Result where Value: Sendable, Result: Sendable {
        try state.withLock { state in
            guard !state.closed, state.scopes[token.scope] != nil else { throw StateError.closed }
            guard var entry = state.entries[token] else { throw StateError.missing }
            guard entry.revision == revision else { throw StateError.conflict }
            guard var value = entry.value as? Value else { throw StateError.typeMismatch }
            let result = try mutation(&value)
            try entry.validate(value)
            let encoded = try entry.encode(value)
            guard state.revision < UInt64.max else { throw StateError.capacityExceeded }
            state.revision += 1
            entry.value = value
            entry.encoded = encoded
            entry.valid = true
            entry.revision = state.revision
            state.entries[token] = entry
            for observer in state.observers.values where observer.tokens.contains(token) {
                observer.continuation.yield(StateChange(revision: state.revision))
            }
            return result
        }
    }
    public func snapshot(_ selections: [StateSelection]) throws -> StateSnapshot {
        try state.withLock { state in
            guard !state.closed else { throw StateError.closed }
            var values: [StateToken: StateEntry] = [:]
            for selected in selections {
                guard selected.container === self, let entry = state.entries[selected.token] else {
                    throw StateError.missing
                }
                values[selected.token] = entry
            }
            return StateSnapshot(revision: state.revision, values: values)
        }
    }
    public func observe(_ selections: [StateSelection]) throws -> AsyncThrowingStream<StateChange, any Error> {
        let id = UUID()
        let stream = AsyncThrowingStream<StateChange, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream.continuation.onTermination = { [weak self] _ in
            Task { self?.removeObserver(id) }
        }
        try state.withLock { state in
            guard !state.closed else { throw StateError.closed }
            guard !selections.isEmpty,
                selections.allSatisfy({ $0.container === self && state.entries[$0.token] != nil })
            else { throw StateError.missing }
            guard state.observers.count < limits.observers else { throw StateError.capacityExceeded }
            state.observers[id] = Observer(tokens: Set(selections.map(\.token)), continuation: stream.continuation)
            stream.continuation.yield(StateChange(revision: state.revision))
        }
        return stream.stream
    }
    public func declare(_ declarations: [StateDeclaration]) throws {
        try state.withLock { state in
            guard !state.closed else { throw StateError.closed }
            var next = state.declarations
            for item in declarations {
                guard !item.name.isEmpty, item.name.utf8.count <= 256 else { throw StateError.invalidKey }
                if let existing = next[item.name], existing != item.scope { throw StateError.typeMismatch }
                next[item.name] = item.scope
            }
            guard next.count <= limits.registrations else { throw StateError.capacityExceeded }
            state.declarations = next
        }
    }
    public func contextReader(domain: StateDomain = .application, scope: StateScope? = nil) throws
        -> any StateContextReading
    {
        try state.withLock { state in
            guard !state.closed else { throw StateError.closed }
            if domain.kind == .conversation, scope == nil { throw StateError.missing }
            if let scope {
                guard scope.container === self, state.scopes[scope.id] == domain else { throw StateError.closed }
            }
        }
        return BoundStateContext(container: self, domain: domain, scopeID: scope?.id)
    }
    fileprivate func contextSnapshot(names: [String], domain: StateDomain, scopeID: UUID?) throws
        -> StateContextSnapshot
    {
        guard names.count <= 32, Set(names).count == names.count else { throw StateError.capacityExceeded }
        return try state.withLock { state in
            guard !state.closed else { throw StateError.closed }
            if let scopeID { guard state.scopes[scopeID] == domain else { throw StateError.closed } }
            var fields: [String: Any] = [:]
            for name in names {
                guard let kind = state.declarations[name] else { throw StateError.missing }
                let selected: StateDomain = kind == .application ? .application : domain
                guard selected.kind == kind else { throw StateError.missing }
                guard
                    let entry = state.entries.first(where: {
                        $0.key.name == name && state.scopes[$0.key.scope] == selected
                    })?.value
                else { throw StateError.missing }
                guard entry.valid else { throw StateError.invalidPublication }
                fields[name] = try JSONSerialization.jsonObject(with: entry.encoded, options: [.fragmentsAllowed])
            }
            let data = try JSONSerialization.data(
                withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
            guard data.count <= 16 * 1024 else { throw StateError.capacityExceeded }
            return StateContextSnapshot(revision: state.revision, json: String(decoding: data, as: UTF8.self))
        }
    }
    fileprivate func invalidate(_ token: StateToken) {
        state.withLock { state in
            guard var entry = state.entries[token] else { return }
            guard entry.valid, state.revision < UInt64.max else { return }
            state.revision += 1
            entry.valid = false
            entry.revision = state.revision
            state.entries[token] = entry
            for observer in state.observers.values where observer.tokens.contains(token) {
                observer.continuation.yield(StateChange(revision: state.revision))
            }
        }
    }
    private func removeObserver(_ id: UUID) { state.withLock { $0.observers[id] = nil } }
    fileprivate func unregister(_ token: StateToken) { retire { $0 == token } }
    fileprivate func closeScope(_ scope: UUID) {
        retire({ $0.scope == scope }, closing: scope)
    }
    private func retire(_ matches: (StateToken) -> Bool, closing scope: UUID? = nil) {
        let continuations = state.withLock { state in
            if let scope { state.scopes.removeValue(forKey: scope) }
            let tokens = Set(state.entries.keys.filter(matches))
            if !tokens.isEmpty, state.revision < UInt64.max { state.revision += 1 }
            for token in tokens { state.entries[token] = nil }
            let ids = state.observers.filter { !$0.value.tokens.isDisjoint(with: tokens) }.map(\.key)
            return ids.compactMap { state.observers.removeValue(forKey: $0)?.continuation }
        }
        for continuation in continuations { continuation.finish(throwing: StateError.closed) }
    }
    public func close() {
        let continuations = state.withLock { state in
            state.closed = true
            state.scopes.removeAll()
            state.entries.removeAll()
            let result = state.observers.values.map(\.continuation)
            state.observers.removeAll()
            return result
        }
        for continuation in continuations { continuation.finish(throwing: StateError.closed) }
    }
}

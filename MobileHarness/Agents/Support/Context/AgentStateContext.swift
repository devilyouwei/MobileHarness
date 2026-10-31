import AgentCore
import Foundation
import Synchronization

/// A bounded read-capability registry. It owns no business state or Task projection.
public final class AgentStateContext: Sendable {
    private struct Registry: Sendable {
        var closed = false
        var sessions: [String: UUID] = [:]
        var sources: [String: any ContainerContextProviding] = [:]
    }
    private let registry = Mutex(Registry())
    public init() {}
    public func register(_ name: String, source: any ContainerContextProviding) throws {
        try registry.withLock { value in
            guard !value.closed else { throw ContainerContextError.closed }
            guard !name.isEmpty, name.utf8.count <= 256,
                name.split(separator: ".").count >= 2, !name.hasPrefix("."), !name.hasSuffix("."), !name.contains(".."),
                name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) })
            else { throw ContainerContextError.invalidName }
            guard value.sources[name] == nil else { throw ContainerContextError.duplicate }
            guard value.sources.count < 256 else { throw ContainerContextError.capacityExceeded }
            value.sources[name] = source
        }
    }
    public func open(session: String) throws {
        try registry.withLock { value in
            guard !value.closed else { throw ContainerContextError.closed }
            guard value.sessions[session] != nil || value.sessions.count < 64 else {
                throw ContainerContextError.capacityExceeded
            }
            if value.sessions[session] == nil { value.sessions[session] = UUID() }
        }
    }
    public func snapshot(session: String, names: [String]) async throws -> String {
        guard names.count <= 32, Set(names).count == names.count else {
            throw ContainerContextError.capacityExceeded
        }
        let (generation, sources) = try registry.withLock {
            value -> (UUID, [(String, any ContainerContextProviding)]) in
            guard !value.closed, let generation = value.sessions[session] else { throw ContainerContextError.closed }
            let sources = try names.sorted().map { name -> (String, any ContainerContextProviding) in
                guard let source = value.sources[name] else { throw ContainerContextError.missing }
                return (name, source)
            }
            return (generation, sources)
        }
        var fields: [String: Any] = [:]
        for (name, source) in sources {
            try Task.checkCancellation()
            let data = try await source.contextSnapshot()
            guard data.count <= 8192 else { throw ContainerContextError.capacityExceeded }
            fields[name] = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }
        try Task.checkCancellation()
        try registry.withLock { value in
            guard !value.closed, value.sessions[session] == generation else { throw ContainerContextError.closed }
        }
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        guard data.count <= 16384 else { throw ContainerContextError.capacityExceeded }
        return String(decoding: data, as: UTF8.self)
    }
    public func close(session: String) { _ = registry.withLock { $0.sessions.removeValue(forKey: session) } }
    public func close() {
        registry.withLock { value in
            value.closed = true
            value.sessions.removeAll()
            value.sources.removeAll()
        }
    }
}

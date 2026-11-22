import AgentCore
import Foundation
import Synchronization

/// A bounded read-capability registry. It owns no business state or Task projection.
public final class AgentStateContext: Sendable {
    private struct Registry: Sendable {
        var resolver: (@Sendable (String) async throws -> Data)?
        var media: [String: @Sendable (String) async throws -> MultimodalContextSnapshot] = [:]
        var resets: [String: @Sendable (String) async -> Void] = [:]
        var dialogs: [String: String] = [:]
        var closed = false
        var sessions: [String: UUID] = [:]
        var sources: [String: any ContainerContextProviding] = [:]
    }
    private let registry = Mutex(Registry())
    public init() {}
    public func resolve(using read: @escaping @Sendable (String) async throws -> Data) throws {
        try registry.withLock { value in
            guard !value.closed else { throw ContainerContextError.closed }
            guard value.resolver == nil else { throw ContainerContextError.duplicate }
            value.resolver = read
        }
    }
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
    /// Image sources are read only to build a prompt; passive displays skip them.
    public func isMedia(_ name: String) -> Bool { registry.withLock { $0.media[name] != nil } }
    public func open(session: String) throws {
        try registry.withLock { value in
            guard !value.closed else { throw ContainerContextError.closed }
            guard value.sessions[session] != nil || value.sessions.count < 64 else {
                throw ContainerContextError.capacityExceeded
            }
            if value.sessions[session] == nil { value.sessions[session] = UUID() }
        }
    }
    public func registerMedia(
        _ name: String,
        read: @escaping @Sendable (String) async throws -> MultimodalContextSnapshot,
        reset: @escaping @Sendable (String) async -> Void
    ) throws {
        try registry.withLock { value in
            guard !value.closed else { throw ContainerContextError.closed }
            guard value.media[name] == nil else { throw ContainerContextError.duplicate }
            guard value.media.count < 32 else { throw ContainerContextError.capacityExceeded }
            value.media[name] = read
            value.resets[name] = reset
        }
    }
    public func synchronize(session: String, dialog: String) async {
        let callbacks = registry.withLock { value -> [@Sendable (String) async -> Void] in
            guard !value.closed, value.sessions[session] != nil, value.dialogs[session] != dialog else { return [] }
            value.dialogs[session] = dialog
            return Array(value.resets.values)
        }
        for reset in callbacks { await reset(session) }
    }
    public func resetMedia(session: String) async {
        let callbacks = registry.withLock { value -> [@Sendable (String) async -> Void] in
            value.dialogs[session] = nil
            return Array(value.resets.values)
        }
        for reset in callbacks { await reset(session) }
    }
    /// Drops null recursively. Empty strings and genuinely empty containers are real values and stay; a container
    /// emptied only by dropping nulls carries nothing, so nil means nothing meaningful remains.
    private static func pruned(_ value: Any) -> Any? {
        if value is NSNull { return nil }
        if let object = value as? [String: Any] {
            if object.isEmpty { return object }
            let kept = object.compactMapValues { pruned($0) }
            return kept.isEmpty ? nil : kept
        }
        if let array = value as? [Any] {
            if array.isEmpty { return array }
            let kept = array.compactMap { pruned($0) }
            return kept.isEmpty ? nil : kept
        }
        return value
    }
    public func snapshot(session: String, names: [String]) async throws -> String {
        String(decoding: try await multimodalSnapshot(session: session, names: names).facts, as: UTF8.self)
    }
    public func multimodalSnapshot(session: String, names: [String]) async throws -> MultimodalContextSnapshot {
        guard names.count <= 32, Set(names).count == names.count else { throw ContainerContextError.capacityExceeded }
        let (generation, readers) = try registry.withLock {
            value -> (UUID, [(String, @Sendable (String) async throws -> MultimodalContextSnapshot)]) in
            guard !value.closed, let generation = value.sessions[session] else { throw ContainerContextError.closed }
            let readers = try names.sorted().map {
                name -> (String, @Sendable (String) async throws -> MultimodalContextSnapshot) in
                if let media = value.media[name] { return (name, media) }
                guard
                    let source = value.sources[name]
                        ?? value.resolver.map({ read in ContainerContextSource(encoded: { try await read(name) }) })
                else { throw ContainerContextError.missing }
                return (name, { _ in .init(facts: try await source.contextSnapshot()) })
            }
            return (generation, readers)
        }
        var fields: [String: Any] = [:]
        var images: [ContextImage] = []
        var bindings: [String: String] = [:]
        for (name, read) in readers {
            try Task.checkCancellation()
            let snapshot = try await read(session)
            bindings[name] = snapshot.resourceScope
            guard snapshot.facts.count <= 8192 else { throw ContainerContextError.capacityExceeded }
            let value = try JSONSerialization.jsonObject(with: snapshot.facts, options: [.fragmentsAllowed])
            // A source without a meaningful value is left out of the model context entirely.
            if let meaningful = Self.pruned(value) { fields[name] = meaningful }
            for image in snapshot.images where !images.contains(where: { $0.id == image.id }) {
                guard !image.data.isEmpty, image.data.count <= 4 * 1024 * 1024 else {
                    throw ContainerContextError.capacityExceeded
                }
                images.append(
                    .init(
                        id: image.id, mimeType: image.mimeType, width: image.width, height: image.height,
                        data: image.data, source: name, resourceScope: image.resourceScope))
            }
        }
        try Task.checkCancellation()
        try registry.withLock { value in
            guard !value.closed, value.sessions[session] == generation else { throw ContainerContextError.closed }
        }
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        guard data.count <= 16384, images.count <= 5 else { throw ContainerContextError.capacityExceeded }
        return .init(facts: data, images: images, resourceBindings: bindings)
    }
    public func close(session: String) {
        registry.withLock { value in
            value.sessions[session] = nil
            value.dialogs[session] = nil
        }
    }
    public func close() {
        registry.withLock { value in
            value.closed = true
            value.sessions.removeAll()
            value.sources.removeAll()
            value.media.removeAll()
            value.resets.removeAll()
            value.dialogs.removeAll()
            value.resolver = nil
        }
    }
}

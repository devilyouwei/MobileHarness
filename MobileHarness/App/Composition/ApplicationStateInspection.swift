import Agents
import Foundation

/// Composition-only view. Module owners retain their local types and mutable state.
public struct ApplicationStateSnapshot: Codable, Sendable {
    public struct Reference: Codable, Sendable, Hashable {
        public let path: String
        public init(path: String) { self.path = path }
    }
    public indirect enum Value: Codable, Sendable, Equatable {
        case text(String)
        case flag(Bool)
        case count(Int)
        case unsigned(UInt64)
        case number(Double)
        case integers([Int])
        case texts([String])
        case object([String: Value])
        case array([Value])
        case unknown
        public init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() {
                self = .unknown
            } else if let flag = try? value.decode(Bool.self) {
                self = .flag(flag)
            } else if let count = try? value.decode(Int.self) {
                self = .count(count)
            } else if let unsigned = try? value.decode(UInt64.self) {
                self = .unsigned(unsigned)
            } else if let number = try? value.decode(Double.self) {
                self = .number(number)
            } else if let integers = try? value.decode([Int].self) {
                self = .integers(integers)
            } else if let texts = try? value.decode([String].self) {
                self = .texts(texts)
            } else if let object = try? value.decode([String: Value].self) {
                self = .object(object)
            } else if let array = try? value.decode([Value].self) {
                self = .array(array)
            } else {
                self = .text(try value.decode(String.self))
            }
        }
        public func encode(to encoder: any Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .text(let item): try value.encode(item)
            case .flag(let item): try value.encode(item)
            case .count(let item): try value.encode(item)
            case .unsigned(let item): try value.encode(item)
            case .number(let item): try value.encode(item)
            case .integers(let item): try value.encode(item)
            case .texts(let item): try value.encode(item)
            case .object(let item): try value.encode(item)
            case .array(let item): try value.encode(item)
            case .unknown: try value.encodeNil()
            }
        }
    }
    public enum Health: String, Codable, Sendable { case healthy, limited, fault, unknown }
    public struct Issue: Codable, Sendable {
        public let code: String
        public let impact: String
        public init(code: String, impact: String) {
            self.code = code
            self.impact = impact
        }
    }
    public struct Descriptor: Codable, Sendable {
        public let path: String
        public let business: [String]
        public let runtime: [String]
        public let children: [Reference]
        public let meanings: [String: String]
        public let units: [String: String]
        public let stateValues: [String: [String]]
    }
    public let path: String
    public let business: [String: Value]
    public let runtime: [String: Value]
    public let health: Health
    public let issues: [Issue]
    public let children: [Reference]
    public var meanings: [String: String] = [:]
    public var units: [String: String] = [:]
    public var stateValues: [String: [String]] = [:]
    public let collectedAt: Date
    /// An inspection failure is separate from an owner's actual health.
    public var readFailure: String?
    public var stateDescriptor: Descriptor {
        Descriptor(
            path: path, business: business.keys.sorted(), runtime: runtime.keys.sorted(),
            children: children, meanings: meanings, units: units,
            stateValues: stateValues.merging(["health": ["healthy", "limited", "fault", "unknown"]]) { current, _ in
                current
            })
    }

}

public enum StateInspectionError: Error, Equatable, Sendable {
    case invalidPath, duplicate, missing, capacityExceeded, invalidSnapshot
}

/// Scoped, pull-only inspection. No tasks, subscriptions, devices or Skills are created here.
@MainActor public final class ApplicationStateInspection {
    private var configurationFailure: (any Error)?
    public func rejectConfiguration(_ error: any Error) { configurationFailure = error }
    private typealias Reader = @Sendable () async throws -> Data
    private var catalogs: [String: @MainActor @Sendable () async throws -> [String: Reader]] = [:]
    private let failures: ContainerFailureChannel?
    public init(failures: ContainerFailureChannel? = nil) { self.failures = failures }
    public var rootPaths: [String] { catalogs.keys.sorted() }
    public func registerRoot<Snapshot: Encodable & Sendable>(
        _ path: String,
        readers: @escaping @MainActor @Sendable () async throws -> [String: @Sendable () async throws -> Snapshot]
    ) throws {
        guard Self.isValidPath(path), !path.contains(".") else { throw StateInspectionError.invalidPath }
        guard catalogs[path] == nil else { throw StateInspectionError.duplicate }
        guard catalogs.count < 256 else { throw StateInspectionError.capacityExceeded }
        catalogs[path] = {
            let source = try await readers()
            guard source.count <= 256 else { throw StateInspectionError.capacityExceeded }
            guard source[path] != nil,
                source.keys.allSatisfy({ Self.isValidPath($0) && ($0 == path || $0.hasPrefix(path + ".")) })
            else { throw StateInspectionError.invalidSnapshot }
            var result: [String: Reader] = [:]
            for (name, read) in source { result[name] = { try JSONEncoder().encode(try await read()) } }
            return result
        }
    }
    /// A single-node root is also valid; it does not imply descendant discovery.
    public func registerRoot<Snapshot: Encodable & Sendable>(
        _ path: String, read: @escaping @MainActor @Sendable () async throws -> Snapshot
    ) throws {
        try registerRoot(path, readers: { [path: { @Sendable in try await read() }] })
    }
    private nonisolated static func isValidPath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 256 && !path.hasPrefix(".") && !path.hasSuffix(".") && !path.contains("..")
            && path.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }
    }
    private func catalog(for path: String) async throws -> [String: Reader] {
        if let configurationFailure { throw configurationFailure }
        guard Self.isValidPath(path) else { throw StateInspectionError.invalidPath }
        let root = String(path.prefix { $0 != "." })
        guard let factory = catalogs[root] else { throw StateInspectionError.missing }
        try Task.checkCancellation()
        let readers = try await factory()
        try Task.checkCancellation()
        return readers
    }
    private func read(_ path: String, from readers: [String: Reader]) async throws -> ApplicationStateSnapshot {
        guard let reader = readers[path] else { throw StateInspectionError.missing }
        try Task.checkCancellation()
        let node: ApplicationStateSnapshot
        do {
            let data = try await reader()
            guard data.count <= 256 * 1024 else { throw StateInspectionError.capacityExceeded }
            node = try JSONDecoder().decode(ApplicationStateSnapshot.self, from: data)
        } catch is CancellationError { throw CancellationError() } catch let error as StateInspectionError {
            throw error
        } catch {
            return .init(
                path: path, business: [:], runtime: [:], health: .unknown, issues: [], children: [],
                collectedAt: Date(), readFailure: "ownerReadFailed")
        }
        try Task.checkCancellation()
        guard node.path == path, Set(node.business.keys).isDisjoint(with: node.runtime.keys),
            node.children.count <= 256, Set(node.children.map(\.path)).count == node.children.count,
            node.children.allSatisfy({ Self.isValidPath($0.path) && $0.path.hasPrefix(path + ".") })
        else { throw StateInspectionError.invalidSnapshot }
        func field(_ key: String) -> ApplicationStateSnapshot.Value? {
            if key == "health" { return .text(node.health.rawValue) }
            if key.hasPrefix("business.") { return node.business[String(key.dropFirst(9))] }
            if key.hasPrefix("runtime.") { return node.runtime[String(key.dropFirst(8))] }
            return nil
        }
        for key in Set(node.meanings.keys).union(node.units.keys).union(node.stateValues.keys) {
            guard let value = field(key) else { throw StateInspectionError.invalidSnapshot }
            if let allowed = node.stateValues[key], value != .unknown {
                guard case .text(let text) = value, allowed.contains(text) else {
                    throw StateInspectionError.invalidSnapshot
                }
            }
        }
        return node
    }
    /// Exact selection: resolving a.b.c never samples a or a.b.
    public func snapshot(path: String) async throws -> ApplicationStateSnapshot {
        try await read(path, from: catalog(for: path))
    }
    public func describe(path: String) async throws -> ApplicationStateSnapshot.Descriptor {
        try await snapshot(path: path).stateDescriptor
    }
    /// Explicit caller-owned materialization, separate from a Container's local snapshot.
    public struct Tree: Encodable, Sendable {
        public let state: ApplicationStateSnapshot
        public let children: [Tree]
        public var effectiveHealth: ApplicationStateSnapshot.Health {
            let levels = [state.health] + children.map(\.effectiveHealth)
            if levels.contains(.fault) { return .fault }
            if levels.contains(.limited) { return .limited }
            return levels.allSatisfy { $0 == .healthy } ? .healthy : .unknown
        }
        public var nodeCount: Int { 1 + children.reduce(0) { $0 + $1.nodeCount } }
    }
    public func inspectTree(path: String, depth: Int = 16) async throws -> Tree {
        guard (0...16).contains(depth) else { throw StateInspectionError.capacityExceeded }
        let readers = try await catalog(for: path)
        var seen: Set<String> = []
        func visit(_ path: String, remaining: Int) async throws -> Tree {
            guard seen.count < 256, seen.insert(path).inserted else { throw StateInspectionError.capacityExceeded }
            let node = try await read(path, from: readers)
            var children: [Tree] = []
            if remaining > 0 {
                for child in node.children { children.append(try await visit(child.path, remaining: remaining - 1)) }
            }
            return .init(state: node, children: children)
        }
        let tree = try await visit(path, remaining: depth)
        guard try JSONEncoder().encode(tree).count <= 256 * 1024 else { throw StateInspectionError.capacityExceeded }
        return tree
    }
    private func inspectForest() async throws -> [Tree] {
        var trees: [Tree] = []
        for path in rootPaths {
            trees.append(try await inspectTree(path: path))
            guard trees.reduce(0, { $0 + $1.nodeCount }) <= 256 else { throw StateInspectionError.capacityExceeded }
        }
        guard try JSONEncoder().encode(trees).count <= 256 * 1024 else { throw StateInspectionError.capacityExceeded }
        return trees
    }
    public struct HealthSummary: Encodable, Sendable {
        public struct Entry: Encodable, Sendable {
            public let capability: String
            public let severity: String
            public let impact: String
        }
        public let availability: String
        public let entries: [Entry]
        public let total: Int
        public let omitted: Int
        public let unknown: Bool
    }
    public func healthSummary() async throws -> HealthSummary {
        let trees = try await inspectForest()
        var entries: [HealthSummary.Entry] = []
        var unknown = false
        func collect(_ tree: Tree) {
            let node = tree.state
            if node.health == .unknown || node.readFailure != nil { unknown = true }
            if node.health == .fault || node.health == .limited {
                entries.append(
                    .init(
                        capability: node.path, severity: node.health.rawValue,
                        impact: node.issues.first?.impact ?? "capabilityRequiresValidation"))
            }
            for child in tree.children { collect(child) }
        }
        for tree in trees { collect(tree) }
        entries.sort { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity == "fault" }
            return lhs.capability < rhs.capability
        }
        return HealthSummary(
            availability: "available", entries: Array(entries.prefix(8)), total: entries.count,
            omitted: max(0, entries.count - 8), unknown: unknown)
    }
    public func healthProjection() async throws -> Data {
        struct Envelope: Encodable {
            let availability = "available"
            let value: HealthSummary
        }
        let value = try await healthSummary()
        let data = try JSONEncoder().encode(Envelope(value: value))
        guard data.count <= 8192 else { throw StateInspectionError.capacityExceeded }
        return data
    }
    /// Explicit diagnostic allowlist. No business dictionaries, content or error strings are forwarded.
    public func diagnosticProjection() async throws -> Data {
        struct Diagnostic: Encodable {
            struct Root: Encodable {
                let module: String
                let health: String
                let runtime: [String: ApplicationStateSnapshot.Value]
                let readFailure: String?
            }
            struct HistoricalFailure: Encodable {
                let module: String
                let component: String
                let code: String
                let firstOccurred: Date
                let lastOccurred: Date
                let occurrences: UInt64
                // Journal entries are evidence of past failure, never assertions of active injury.
                let status = "historical"
            }
            let availability = "available"
            let value: [Root]
            let history: [HistoricalFailure]
            let omittedHistory: Int
            let evictedHistory: UInt64
        }
        let allowed: Set<String> = [
            "phase", "available", "started", "stopped", "closed", "ready", "foregroundRequested",
        ]
        let roots = try await inspectForest().map {
            Diagnostic.Root(
                module: $0.state.path, health: $0.effectiveHealth.rawValue,
                runtime: $0.state.runtime.filter { allowed.contains($0.key) }, readFailure: $0.state.readFailure)
        }
        let journal = failures?.snapshot()
        let records = journal?.records.filter { $0.delivery != .suppressed } ?? []
        var history = records.suffix(32).map {
            Diagnostic.HistoricalFailure(
                module: $0.event.module, component: $0.event.component, code: $0.event.code,
                firstOccurred: $0.firstOccurred, lastOccurred: $0.event.lastOccurred, occurrences: $0.event.occurrences)
        }
        while true {
            let data = try JSONEncoder().encode(
                Diagnostic(
                    value: roots, history: history, omittedHistory: records.count - history.count,
                    evictedHistory: journal?.evictedRecords ?? 0))
            if data.count <= 8192 { return data }
            guard !history.isEmpty else { throw StateInspectionError.capacityExceeded }
            history.removeFirst()
        }
    }
}

import AgentCore
import Foundation
import FunctionContracts

/// Adapts the producer-owned Business contract; Skills alone select exact paths.
public enum AssistantStateBindings {
    public typealias ReadState = @Sendable (String) async throws -> any Encodable & Sendable
    public static func register(in context: AgentStateContext, names: [String]? = nil, read: @escaping ReadState) throws
    {
        if let names {
            for name in names {
                try context.register(
                    name, source: ContainerContextSource(encoded: { try await snapshot(name, read: read) }))
            }
        } else {
            try context.resolve { try await snapshot($0, read: read) }
        }
    }
    private struct Node: Decodable {
        let path: String
        let business: [String: AgentStateSnapshot.Value]
        let readFailure: String?
    }
    private struct Unknown: Encodable {
        let availability = "unknown"
        let value: String? = nil
        let diagnostic: Diagnostic
        struct Diagnostic: Encodable {
            let path: String
            let code: String
        }
        enum CodingKeys: String, CodingKey { case availability, value, diagnostic }
        func encode(to encoder: any Encoder) throws {
            var fields = encoder.container(keyedBy: CodingKeys.self)
            try fields.encode(availability, forKey: .availability)
            try fields.encodeNil(forKey: .value)
            try fields.encode(diagnostic, forKey: .diagnostic)
        }
    }
    private static func snapshot(_ name: String, read: ReadState) async throws -> Data {
        guard !name.isEmpty, name.utf8.count <= 256, name.split(separator: ".").count >= 2,
            !name.hasPrefix("."), !name.hasSuffix("."), !name.contains(".."),
            name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) })
        else { throw ContainerContextError.invalidName }
        do {
            try Task.checkCancellation()
            let raw = try await read(name)
            let data = try JSONEncoder().encode(raw)
            guard data.count <= 256 * 1024 else { throw ContainerContextError.capacityExceeded }
            let node = try JSONDecoder().decode(Node.self, from: data)
            try Task.checkCancellation()
            guard node.path == name, node.readFailure == nil else { throw ContainerContextError.invalidSnapshot }
            return try JSONEncoder().encode(
                ContainerContextValue(
                    node.business,
                    availability: node.business.values.contains { $0 != .unknown } ? .available : .unknown))
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            if let failure = error as? ContainerContextError,
                failure == .closed || failure == .capacityExceeded
            {
                throw failure
            }
            return try JSONEncoder().encode(Unknown(diagnostic: .init(path: name, code: "stateUnavailable")))
        }
    }
}

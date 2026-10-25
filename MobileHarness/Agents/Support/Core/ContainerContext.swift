import Foundation

public enum ContainerContextError: Error, Equatable, Sendable {
    case duplicate, invalidName, missing, closed, capacityExceeded, invalidSnapshot
}
public enum ContextAvailability: String, Codable, Sendable { case unknown, available, unavailable }
public struct ContainerContextValue<Value: Encodable & Sendable>: Encodable, Sendable {
    public let availability: ContextAvailability
    public let value: Value?
    public init(_ value: Value? = nil, availability: ContextAvailability = .available) {
        self.availability = availability
        self.value = value
    }
    private enum CodingKeys: String, CodingKey { case availability, value }
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(availability, forKey: .availability)
        try fields.encode(value, forKey: .value)
    }
}
public protocol ContainerContextProviding: Sendable {
    func contextSnapshot() async throws -> Data
}
/// Type erasure only; facts stay in the captured owner, never in this adapter.
public struct ContainerContextSource: ContainerContextProviding {
    private let read: @Sendable () async throws -> Data
    public init<Value: Encodable & Sendable>(_ read: @escaping @Sendable () async throws -> Value) {
        self.read = { try JSONEncoder().encode(try await read()) }
    }
    public func contextSnapshot() async throws -> Data { try await read() }
}

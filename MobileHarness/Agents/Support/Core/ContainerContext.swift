import Foundation
import FunctionContracts

public enum ContainerContextError: Error, Equatable, Sendable {
    case duplicate, invalidName, missing, closed, capacityExceeded, invalidSnapshot
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
    /// Read an already encoded snapshot without applying Data's base64 JSON encoding.
    public init(encoded read: @escaping @Sendable () async throws -> Data) {
        self.read = read
    }
    public func contextSnapshot() async throws -> Data { try await read() }
}

import Foundation

/// FIFO admission owned by a long-lived store. Cancellation before admission executes no body.
public actor StorageOperationGate {
    private let maximumWaiters: Int
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public var waitingCount: Int { waiters.count }
    public init() { maximumWaiters = 16 }
    public init(maximumWaiters: Int) throws {
        guard (0...1024).contains(maximumWaiters) else { throw StorageError.capacityExceeded }
        self.maximumWaiters = maximumWaiters
    }
    private func acquire() async throws {
        if !occupied {
            occupied = true
            return
        }
        guard waiters.count < maximumWaiters else { throw StorageError.busy }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { occupied = false } else { waiters.removeFirst().resume() }
    }
    public func withAccess<Value: Sendable>(
        honorCancellation: Bool = true, _ body: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if honorCancellation { try Task.checkCancellation() }
        try await acquire()
        defer { release() }
        if honorCancellation {
            try Task.checkCancellation()
            return try await body()
        }
        // A captured terminal commit owns its work and is joined before admission is released.
        return try await Task { try await body() }.value
    }
}

import AgentCore
import Foundation

/// Role-owned latest environment facts. One worker, at most one pending fact per category.
@MainActor final class ApplicationEnvironmentInputs {
    private let deliver: @MainActor (AppEnvironmentFact) async throws -> Void
    private let failed: @MainActor (any Error) -> Void
    private var sequence: UInt64 = 0
    private var pending: [AppEnvironmentFact.Category: AppEnvironmentFact] = [:]
    private var worker: Task<Void, Never>?
    private var closed = false
    init(
        deliver: @escaping @MainActor (AppEnvironmentFact) async throws -> Void,
        failed: @escaping @MainActor (any Error) -> Void
    ) {
        self.deliver = deliver
        self.failed = failed
    }
    func report(_ category: AppEnvironmentFact.Category, value: String) {
        guard !closed else { return }
        guard value.utf8.count <= 16_384 else {
            failed(CommunicationError.invalidPayload)
            return
        }
        guard sequence < UInt64.max else {
            failed(CommunicationError.capacityExceeded)
            return
        }
        sequence += 1
        pending[category] = .init(category: category, sequence: sequence, value: value)
        guard worker == nil else { return }
        worker = Task { [self] in
            defer { worker = nil }
            while !closed, !Task.isCancelled,
                let fact = pending.values.min(by: { $0.sequence < $1.sequence })
            {
                pending[fact.category] = nil
                do { try await deliver(fact) } catch {
                    if !Task.isCancelled { failed(error) }
                }
            }
        }
    }
    func shutdown() async {
        closed = true
        pending.removeAll()
        worker?.cancel()
        await worker?.value
        worker = nil
    }
    deinit { worker?.cancel() }
}

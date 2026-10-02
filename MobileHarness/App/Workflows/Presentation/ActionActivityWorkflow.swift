import AgentCore
import Foundation
import UI

/// Root-owned execution-state subscription. The injected stream carries full snapshots, bounded error descriptions without call arguments.
@MainActor
public final class ActionActivityWorkflow {
    public let state: ActionActivityState
    private var observation: Task<Void, Never>?
    public init(state: ActionActivityState) { self.state = state }
    deinit { observation?.cancel() }

    public func start(observe: @escaping @Sendable () async throws -> AsyncStream<ActionExecutionSnapshot>) {
        guard observation == nil else { return }
        let state = state
        observation = Task {
            do {
                let stream = try await observe()
                for await snapshot in stream {
                    guard !Task.isCancelled else { return }
                    state.replace(
                        revision: snapshot.revision, records: snapshot.records.map(ActionActivityItem.init),
                        evictedCount: snapshot.evictedCount)
                }
            } catch {
                if !Task.isCancelled { state.observationUnavailable = true }
            }
        }
    }
}

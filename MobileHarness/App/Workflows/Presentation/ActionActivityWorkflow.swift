import AgentCore
import Foundation
import UI

/// Root-owned execution-state subscription. The injected stream carries full snapshots, bounded error descriptions without call arguments.
@MainActor
public final class ActionActivityWorkflow {
    public let state: ActionActivityState
    private var observation: Task<Void, Never>?
    private var failureObservation: Task<Void, Never>?
    public init(state: ActionActivityState) { self.state = state }
    deinit {
        observation?.cancel()
        failureObservation?.cancel()
    }
    public func recordFailure(
        title: String, source: String, message: String, failureCode: String? = nil,
        context: ExecutionIssue.Context? = nil
    ) {
        state.recordIssue(
            .init(title: title, source: source, message: message, failureCode: failureCode, context: context))
    }
    public func startFailures(observe: @escaping @Sendable () async throws -> AsyncStream<OutputFailureSnapshot>) {
        guard failureObservation == nil else { return }
        let state = state
        failureObservation = Task {
            do {
                let stream = try await observe()
                for await snapshot in stream {
                    guard !Task.isCancelled else { return }
                    state.replaceIssues(
                        revision: snapshot.revision,
                        records: snapshot.records.map {
                            .init(
                                id: $0.id, title: $0.title, source: $0.source.rawValue, message: $0.message,
                                time: $0.time, failureCode: $0.failureCode)
                        }, evictedCount: snapshot.evictedCount)
                }
            } catch {
                if !Task.isCancelled { state.observationUnavailable = true }
            }
        }
    }

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

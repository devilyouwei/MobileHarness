import ActionBindings
import AgentCore
import Foundation
import PlatformKit
import Storage
import UI

/// Root-owned execution-state subscription. The injected stream carries full snapshots, bounded error descriptions without call arguments.
@MainActor
public final class ActionActivityWorkflow: ExecutionFailureReporting {
    public let state: ActionActivityState
    private var taskObservation: Task<Void, Never>?
    private var agentObservation: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private var failureObservation: Task<Void, Never>?
    public init(state: ActionActivityState) { self.state = state }
    deinit {
        taskObservation?.cancel()
        agentObservation?.cancel()
        observation?.cancel()
        failureObservation?.cancel()
    }
    public func recordFailure(
        title: String, source: String, message: String, failureCode: String? = nil,
        context: ExecutionIssue.Context? = nil
    ) {
        state.recordIssue(
            .init(
                title: title, source: source, message: message, failureCode: failureCode, context: context,
                userMessage: Self.userMessage(source: source, message: message)))
    }
    private static func userMessage(source: String, message: String) -> String? {
        source == "speechPerception" && message.hasPrefix("agent.error: speech perception:") ? "我没听清" : nil
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
                                time: $0.time, failureCode: $0.failureCode, inputID: $0.inputID,
                                userMessage: Self.userMessage(source: $0.source.rawValue, message: $0.message))
                        }, evictedCount: snapshot.evictedCount)
                }
            } catch {
                if !Task.isCancelled { state.observationUnavailable = true }
            }
        }
    }

    public func startTasks(
        observe: @escaping @Sendable () async throws -> AsyncStream<SignalTraceSnapshot>,
        taskContent: @escaping @Sendable (AgentTaskSignal) -> (String, Bool) = { _ in ("", false) }
    ) {
        guard taskObservation == nil else { return }
        let state = state
        taskObservation = Task {
            do {
                let stream = try await observe()
                var previousRevision: UInt64?
                var projected: [String: String] = [:]
                for await snapshot in stream {
                    guard !Task.isCancelled else { return }
                    guard previousRevision == nil || snapshot.revision > previousRevision! else { continue }
                    previousRevision = snapshot.revision
                    let retained = Set(snapshot.records.map(\.id))
                    projected = projected.filter { retained.contains($0.key) }
                    for record in snapshot.records {
                        guard let signal = record.task, signal.businessContract != "runtime.replyFinished" else {
                            continue
                        }
                        let key = record.phase.rawValue
                        guard projected[record.id] != key else { continue }
                        projected[record.id] = key
                        let (text, waiting) = taskContent(signal)
                        let phase: TaskLogItem.Phase
                        if record.phase == .rejected || record.phase == .dropped {
                            // A rejected progress/input/result is not proof the underlying task failed.
                            guard signal.kind == .request else { continue }
                            phase = .failed
                        } else if record.phase != .accepted {
                            phase = .requested
                        } else {
                            switch signal.kind {
                            case .request: phase = .accepted
                            case .input: phase = .running
                            case .progress: phase = waiting ? .waitingUser : .running
                            case .cancel: phase = .cancelling
                            case .result:
                                switch signal.status {
                                case .succeeded: phase = .succeeded
                                case .cancelled: phase = .cancelled
                                default: phase = .failed
                                }
                            }
                        }
                        // Unaccepted non-request reports cannot change task progress.
                        guard signal.kind == .request || record.phase == .accepted else { continue }
                        var value = TaskLogItem(
                            id: signal.scope.id, parentID: signal.scope.parentID,
                            requester: signal.scope.requester.rawValue, executor: signal.scope.executor.rawValue,
                            title: signal.kind == .request ? (signal.goal ?? text) : "", phase: phase)
                        value.execution = signal.scope.execution.rawValue
                        value.skills = signal.requestedSkills ?? []
                        state.updateTask(
                            value,
                            event: .init(
                                id: record.id, time: record.time,
                                title: signal.kind.logTitle + " · " + record.phase.displayTitle, detail: text))
                    }
                }
            } catch {
                if !Task.isCancelled {
                    state.recordIssue(
                        .init(title: "Task 记录不可用", source: "runtime", message: String(describing: error)))
                }
            }
        }
    }
    public func startAgents(statuses: @escaping @Sendable () async -> [(String, AgentLifecycle)]) {
        guard agentObservation == nil else { return }
        let state = state
        agentObservation = Task {
            var previous: [String: AgentLifecycle] = [:]
            while !Task.isCancelled {
                let values = await statuses()
                guard !Task.isCancelled else { return }
                let current = Dictionary(uniqueKeysWithValues: values)
                for (source, lifecycle) in values where previous[source] != lifecycle {
                    state.recordAgentEvent(
                        .init(source: source, status: lifecycle.logTitle, isFailure: lifecycle == .failed))
                }
                for source in previous.keys where current[source] == nil {
                    state.recordAgentEvent(.init(source: source, status: "已移除", isFailure: false))
                }
                previous = current
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
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

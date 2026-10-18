import ActionBindings
import AgentCore
import Foundation
import Gateway
import PlatformKit
import StorageCore
import UI

/// Root-owned execution-state subscription. The injected stream carries full snapshots, bounded error descriptions without call arguments.
@MainActor
public final class ActionActivityWorkflow: ExecutionFailureReporting {
    public let state: any ActivityPresenting
    private var taskObservation: Task<Void, Never>?
    private var agentObservation: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private var failureObservation: Task<Void, Never>?
    private let failureEvents = AsyncStream<RuntimeFailureEvent>.makeStream(bufferingPolicy: .bufferingOldest(100))
    private var failureSignalObservation: Task<Void, Never>?
    public private(set) var rejectedFailureSignals: UInt64 = 0
    public private(set) var lastFailureSignalError: String?
    public init(state: any ActivityPresenting) { self.state = state }
    deinit {
        taskObservation?.cancel()
        agentObservation?.cancel()
        observation?.cancel()
        failureObservation?.cancel()
        failureEvents.continuation.finish()
        failureSignalObservation?.cancel()
    }
    public func connectFailureSignals(input: InputGateway, sessionID: String) {
        guard failureSignalObservation == nil else { return }
        let stream = failureEvents.stream
        failureSignalObservation = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                do { try await input.publishRuntimeFailure(event, sessionID: sessionID) } catch {
                    guard !Task.isCancelled else { return }
                    self?.lastFailureSignalError = String(String(describing: error).prefix(512))
                    self?.state.present(.observationUnavailable(true))
                }
            }
        }
    }
    public func stopFailureSignals() async {
        failureEvents.continuation.finish()
        failureObservation?.cancel()
        failureSignalObservation?.cancel()
        await failureObservation?.value
        await failureSignalObservation?.value
    }
    public func shutdown() async {
        await stopFailureSignals()
        let tasks = [taskObservation, agentObservation, observation]
        for task in tasks { task?.cancel() }
        for task in tasks { await task?.value }
        taskObservation = nil
        agentObservation = nil
        observation = nil
    }
    private func forwardFailure(_ event: RuntimeFailureEvent) {
        switch failureEvents.continuation.yield(event) {
        case .enqueued: break
        case .dropped, .terminated:
            rejectedFailureSignals &+= 1
            lastFailureSignalError = "Runtime failure Signal forwarding unavailable or full"
            state.present(.observationUnavailable(true))
        @unknown default:
            state.present(.observationUnavailable(true))
        }
    }
    public func recordFailure(
        title: String, source: String, message: String, failureCode: String? = nil,
        context: ExecutionIssue.Context? = nil
    ) {
        recordFailure(
            title: title, source: source, message: message, failureCode: failureCode,
            context: context, diagnostic: nil)
    }
    public func recordFailure(
        title: String, source: String, message: String, failureCode: String? = nil,
        context: ExecutionIssue.Context? = nil, diagnostic: AgentFailureDiagnostic?
    ) {
        forwardFailure(
            .init(
                source: source, title: title, message: message, failureCode: failureCode,
                sessionID: context?.sessionID, inputID: context?.inputID, roundID: context?.roundID,
                category: diagnostic?.category.rawValue, workerID: context?.workerID, callID: context?.callID))
    }

    public func startFailures(observe: @escaping @Sendable () async throws -> AsyncStream<OutputFailureSnapshot>) {
        guard failureObservation == nil else { return }
        let state = state
        failureObservation = Task { [weak self] in
            do {
                let stream = try await observe()
                var seen: Set<String> = []
                var revision: UInt64?
                for await snapshot in stream {
                    guard !Task.isCancelled else { return }
                    guard revision == nil || snapshot.revision > revision! else { continue }
                    revision = snapshot.revision
                    let retained = Set(snapshot.records.map(\.id))
                    seen = seen.intersection(retained)
                    for record in snapshot.records where !seen.contains(record.id) {
                        seen.insert(record.id)
                        // A failed diagnostic presentation is already evidence; never recursively present it.
                        guard
                            !(record.source == .applicationControl
                                && record.title == "UI.RuntimeDiagnostics.recordFailure")
                        else { continue }
                        self?.forwardFailure(RuntimeFailureEvent(record))
                    }
                }
            } catch {
                if !Task.isCancelled { state.present(.observationUnavailable(true)) }
            }
        }
    }

    public func startTasks(
        observe: @escaping @Sendable () async throws -> AsyncStream<SignalTraceSnapshot>,
        taskContent: @escaping @Sendable (AgentTaskSignal) -> (String, Bool) = { _ in ("", false) }
    ) {
        guard taskObservation == nil else { return }
        let state = state
        taskObservation = Task { [weak self] in
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
                    self?.recordFailure(title: "Task 记录不可用", source: "runtime", message: String(describing: error))
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
                if !Task.isCancelled { state.present(.observationUnavailable(true)) }
            }
        }
    }
}

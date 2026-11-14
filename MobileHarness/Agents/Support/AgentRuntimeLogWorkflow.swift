import AgentCore
import Foundation
import UI

/// Root-owned projections of Agent and Task state and delivery of failure evidence.
@MainActor
public final class AgentRuntimeLogWorkflow: ExecutionFailureReporting {
    private let log: (any RuntimeLogWriting)?
    private var taskObservation: Task<Void, Never>?
    private var agentObservation: Task<Void, Never>?
    private var failureObservation: Task<Void, Never>?
    private let failureEvents = AsyncStream<RuntimeFailureEvent>.makeStream(bufferingPolicy: .bufferingOldest(100))
    private var failureDelivery: Task<Void, Never>?
    public private(set) var rejectedFailureEvents: UInt64 = 0
    public init(log: (any RuntimeLogWriting)? = nil) { self.log = log }
    deinit {
        taskObservation?.cancel()
        agentObservation?.cancel()
        failureObservation?.cancel()
        failureEvents.continuation.finish()
        failureDelivery?.cancel()
    }
    public func connectFailures(deliver: @escaping @Sendable (RuntimeFailureEvent) async throws -> Void) {
        guard failureDelivery == nil else { return }
        let stream = failureEvents.stream
        failureDelivery = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                do { try await deliver(event) } catch {
                    guard !Task.isCancelled else { return }
                    self?.log?.record(.observationUnavailable)
                }
            }
        }
    }
    public func stopFailureObservations() async {
        failureEvents.continuation.finish()
        failureObservation?.cancel()
        failureDelivery?.cancel()
        await failureObservation?.value
        await failureDelivery?.value
    }
    public func shutdown() async {
        await stopFailureObservations()
        let tasks = [taskObservation, agentObservation]
        for task in tasks { task?.cancel() }
        for task in tasks { await task?.value }
        taskObservation = nil
        agentObservation = nil
    }
    private func forwardFailure(_ event: RuntimeFailureEvent) {
        switch failureEvents.continuation.yield(event) {
        case .enqueued: break
        case .dropped, .terminated:
            rejectedFailureEvents &+= 1
            log?.record(.observationUnavailable)
        @unknown default:
            log?.record(.observationUnavailable)
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

    public func updateTask(_ item: TaskLogItem, event: TaskLogEvent) { log?.record(.task(item, event)) }
    public func startFailures(observe: @escaping @Sendable () async throws -> AsyncStream<OutputFailureSnapshot>) {
        guard failureObservation == nil else { return }
        let log = log
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
                        self?.forwardFailure(RuntimeFailureEvent(record))
                    }
                }
            } catch {
                if !Task.isCancelled { log?.record(.observationUnavailable) }
            }
        }
    }

    public func startTasks(
        observe: @escaping @Sendable () async throws -> AsyncStream<SignalTraceSnapshot>,
        taskContent: @escaping @Sendable (AgentTaskSignal) -> (String, Bool) = { _ in ("", false) }
    ) {
        guard taskObservation == nil, let log else { return }
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
                        guard let signal = record.task else {
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
                        log.record(
                            .task(
                                value,
                                .init(
                                    id: record.id, time: record.time,
                                    title: signal.kind.logTitle + " · " + record.phase.displayTitle, detail: text)))
                    }
                }
            } catch {
                if !Task.isCancelled {
                    self?.recordFailure(
                        title: "Task records unavailable", source: "runtime", message: String(describing: error))
                }
            }
        }
    }
    public func startAgents(statuses: @escaping @Sendable () async -> [(String, AgentLifecycle)]) {
        guard agentObservation == nil, let log else { return }
        agentObservation = Task {
            var previous: [String: AgentLifecycle] = [:]
            while !Task.isCancelled {
                let values = await statuses()
                guard !Task.isCancelled else { return }
                let current = Dictionary(uniqueKeysWithValues: values)
                for (source, lifecycle) in values where previous[source] != lifecycle {
                    log.record(
                        .agent(
                            .init(source: source, status: lifecycle.logTitle, isFailure: lifecycle == .failed)))
                }
                for source in previous.keys where current[source] == nil {
                    log.record(.agent(.init(source: source, status: "Removed", isFailure: false)))
                }
                previous = current
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
}

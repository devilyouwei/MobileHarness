import AgentCore
import Foundation
import UI

/// Root-owned projections of Agent and Task state and delivery of failure evidence.
@MainActor
public final class AgentRuntimeLogWorkflow: ExecutionFailureReporting {
    private let language: @Sendable () -> AppLanguage
    private let log: (any RuntimeLogWriting)?
    private var agentObservation: Task<Void, Never>?
    private var failureObservation: Task<Void, Never>?
    private let failureEvents = AsyncStream<RuntimeFailureEvent>.makeStream(bufferingPolicy: .bufferingOldest(100))
    private var failureDelivery: Task<Void, Never>?
    public private(set) var rejectedFailureEvents: UInt64 = 0
    public init(
        log: (any RuntimeLogWriting)? = nil, language: @escaping @Sendable () -> AppLanguage = { .english }
    ) {
        self.log = log
        self.language = language
    }
    deinit {
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
        let tasks = [agentObservation]
        for task in tasks { task?.cancel() }
        for task in tasks { await task?.value }
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

    public func startAgents(statuses: @escaping @Sendable () async -> [(String, AgentLifecycle)]) {
        guard agentObservation == nil, let log else { return }
        let language = language
        agentObservation = Task {
            var previous: [String: AgentLifecycle] = [:]
            while !Task.isCancelled {
                let values = await statuses()
                guard !Task.isCancelled else { return }
                let current = Dictionary(uniqueKeysWithValues: values)
                for (source, lifecycle) in values where previous[source] != lifecycle {
                    log.record(
                        .agent(
                            .init(
                                source: source, status: lifecycle.logTitle(language: language()),
                                isFailure: lifecycle == .failed)))
                }
                for source in previous.keys where current[source] == nil {
                    log.record(.agent(.init(source: source, status: language().text("Removed"), isFailure: false)))
                }
                previous = current
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
}

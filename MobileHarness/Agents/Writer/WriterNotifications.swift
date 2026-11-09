import AgentCore
import Foundation
import StorageCore
import StorageTasks

/// Durable completion facts have a lifetime independent of creative work and execution grants.
actor WriterNotifications {
    typealias Sender = @Sendable (WriterDelegationCompletion) async throws -> DeliveryReport
    typealias Retirement = @Sendable (AgentTaskSignal) async throws -> Void
    private let communications: any AgentMessageRepository
    private let executions: any WriterExecutionRepository
    private var sender: Sender?
    private var retire: Retirement?
    private var running = false
    private var workers: [Bool: Task<Void, Never>] = [:]
    private var revision: UInt64 = 0
    private var failures: [Bool: String] = [:]
    var lastFailure: String? { failures.values.sorted().last }
    init(executions: any WriterExecutionRepository, communications: any AgentMessageRepository) {
        self.executions = executions
        self.communications = communications
    }
    func bind(sender: @escaping Sender, retire: @escaping Retirement) {
        self.sender = sender
        self.retire = retire
    }
    func resume() {
        running = true
        wake()
    }
    func pause() async {
        running = false
        for worker in workers.values { worker.cancel() }
        for worker in Array(workers.values) { await worker.value }
    }
    func stop() async {
        await pause()
        sender = nil
        retire = nil
    }
    func wake() {
        revision &+= 1
        guard running, sender != nil, retire != nil else { return }
        for retirement in [true, false] where workers[retirement] == nil {
            workers[retirement] = Task { await drain(retirement: retirement) }
        }
    }
    private func drain(retirement: Bool) async {
        defer { workers[retirement] = nil }
        var cursor: Int64?
        while running, !Task.isCancelled {
            let observed = revision
            do {
                let page = try await executions.pendingDelegationNotifications(
                    agent: "writer", retirement: retirement, after: cursor, limit: retirement ? 32 : 1)
                if page.isEmpty {
                    if cursor != nil {
                        cursor = nil
                        try await Task.sleep(for: .milliseconds(500))
                        continue
                    }
                    if revision != observed { continue }
                    if !retirement,
                        let next = try await communications.nextAgentDelivery(
                            sender: "writer", contract: "writer.completion")
                    {
                        try await Task.sleep(for: .seconds(max(0.05, min(1, next.timeIntervalSinceNow))))
                        continue
                    }
                    failures.removeValue(forKey: retirement)
                    return
                }
                for row in page {
                    cursor = row.position
                    do {
                        try Task.checkCancellation()
                        let completion = try JSONDecoder().decode(WriterDelegationCompletion.self, from: row.data)
                        try completion.validate()
                        guard completion.signal.scope.id == row.delegateID,
                            try AgentTaskContent.decode(completion.signal).writerEvent?.eventID == row.eventID,
                            let sender, let retire
                        else { throw CommunicationError.invalidPayload }
                        let failure: String?
                        if retirement {
                            try await retire(completion.signal)
                            failure = nil
                        } else {
                            let report = try await sender(completion)
                            failure =
                                report.failure ?? report.rejected[.assistant]
                                ?? (report.delivered.contains(.assistant) ? nil : "Assistant unavailable")
                        }
                        try await executions.finishDelegationNotification(
                            row.delegateID, agent: "writer", retirement: retirement,
                            completed: failure == nil, failure: failure, claimToken: row.claimToken)
                        if let failure { failures[retirement] = failure }
                    } catch {
                        if Task.isCancelled {
                            do {
                                try await executions.finishDelegationNotification(
                                    row.delegateID, agent: "writer", retirement: retirement,
                                    completed: false, failure: "Delivery interrupted", claimToken: row.claimToken)
                            } catch { failures[retirement] = String(describing: error) }
                            return
                        }
                        let message = String(String(describing: error).prefix(1024))
                        failures[retirement] = message
                        try await executions.finishDelegationNotification(
                            row.delegateID, agent: "writer", retirement: retirement,
                            completed: false, failure: message, claimToken: row.claimToken)
                    }
                }
            } catch is CancellationError { return } catch {
                failures[retirement] = String(String(describing: error).prefix(1024))
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }
}

import AgentCore
import Foundation
import StorageCore
import StorageTasks

/// Durable completion facts have a lifetime independent of creative work and execution grants.
actor WriterNotifications {
    typealias Sender = @Sendable (AgentMessage, AgentTaskScope, Bool) async throws -> DeliveryReport
    private let communications: any AgentMessageRepository
    private let tasks: any WriterExecutionRepository
    private var sender: Sender?
    private var running = false
    private var workers: [Bool: Task<Void, Never>] = [:]
    private var revision: UInt64 = 0
    private var failures: [Bool: String] = [:]
    var lastFailure: String? { failures.values.sorted().last }
    init(tasks: any WriterExecutionRepository, communications: any AgentMessageRepository) {
        self.tasks = tasks
        self.communications = communications
    }
    func bind(_ sender: @escaping Sender) { self.sender = sender }
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
    }
    func wake() {
        revision &+= 1
        guard running, sender != nil else { return }
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
                let page = try await tasks.pendingTaskNotifications(
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
                        let completion = try JSONDecoder().decode(WriterTaskCompletion.self, from: row.data)
                        try completion.validate()
                        guard completion.signal.scope.id == row.delegateID,
                            try AgentTaskContent.decode(completion.signal).writerEvent?.eventID == row.eventID,
                            let sender
                        else { throw CommunicationError.invalidPayload }
                        let report = try await sender(
                            retirement ? completion.signal.message() : completion.message,
                            completion.signal.scope, retirement)
                        // Gateway retires a result even if the target rejects it. The plain user
                        // notification stays pending independently until its own admission succeeds.
                        let rejected = report.failure ?? report.rejected[.assistant]
                        let accepted = rejected == nil && report.delivered.contains(.assistant)
                        try await tasks.finishTaskNotification(
                            row.delegateID, agent: "writer", retirement: retirement,
                            completed: retirement || accepted,
                            failure: accepted ? nil : rejected ?? "Assistant unavailable", claimToken: row.claimToken)
                        if !accepted { failures[retirement] = rejected ?? "Assistant unavailable" }
                    } catch {
                        if Task.isCancelled {
                            do {
                                try await tasks.finishTaskNotification(
                                    row.delegateID, agent: "writer", retirement: retirement,
                                    completed: false, failure: "Delivery interrupted", claimToken: row.claimToken)
                            } catch { failures[retirement] = String(describing: error) }
                            return
                        }
                        let message = String(String(describing: error).prefix(1024))
                        failures[retirement] = message
                        // A previous process's grant cannot be reopened. Retain the closed-grant
                        // evidence and continue delivering the independently authenticated fact.
                        try await tasks.finishTaskNotification(
                            row.delegateID, agent: "writer", retirement: retirement,
                            completed: retirement && message.contains("scopeClosed"), failure: message,
                            claimToken: row.claimToken)
                    }
                }
            } catch is CancellationError { return } catch {
                failures[retirement] = String(String(describing: error).prefix(1024))
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }
}

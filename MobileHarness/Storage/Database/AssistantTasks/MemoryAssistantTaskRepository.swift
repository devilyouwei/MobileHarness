import Foundation
import StorageCore
import Synchronization

/// Ephemeral business records, local to this repository; restart does not preserve them.
public final class MemoryAssistantTaskRepository: AssistantTaskRepository {
    public let storageScope = UUID()
    private struct Record {
        let dialog: String?
        let agent: String
        let goal: String
        let createdAt: Date
        var status: String
        var failure: String?
        var finishedAt: Date?
    }
    private struct State {
        var next: Int64 = 0
        var records: [String: Record] = [:]
    }
    private let state = Mutex(State())
    private let capacity: Int
    public init() { capacity = 8192 }
    public init(capacity: Int) throws {
        guard (1...8192).contains(capacity) else { throw RecordStorageError.invalidRecord }
        self.capacity = capacity
    }
    public func createTask(
        dialog id: String?, agent: String, goal: String
    ) throws -> String {
        try state.withLock { state in
            guard state.records.count < capacity, state.next < Int64.max else { throw RecordStorageError.busy }
            if let id { _ = try BusinessRecordID.number(id, kind: .dialog) }
            guard agent == "assistant", !state.records.values.contains(where: { $0.finishedAt == nil }) else {
                throw RecordStorageError.conflict
            }
            state.next += 1
            let key = "task_\(state.next)"
            state.records[key] = Record(
                dialog: id, agent: agent, goal: goal,
                createdAt: Date(), status: "running", failure: nil, finishedAt: nil)
            return key
        }
    }
    public func endTask(_ id: String, status: String, failure: String?, finishedAt: Date) throws {
        _ = try BusinessRecordID.number(id, kind: .task)
        state.withLock { state in
            guard var record = state.records[id], ["running", "finishing"].contains(record.status) else { return }
            record.status = status
            record.failure = failure
            record.finishedAt = finishedAt
            state.records[id] = record
        }
    }
}

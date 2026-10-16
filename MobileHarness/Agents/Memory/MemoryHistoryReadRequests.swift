import AgentCore
import Foundation
import StorageChat

public enum MemoryHistoryRead: Sendable {
    case conversation(String)
    case message(String)
    case page(id: String, after: UInt64, taskID: String?)
    case archives(before: Int64)
    case photo(id: String, inputID: String)

    fileprivate func validate() throws {
        let ids: [String]
        switch self {
        case .conversation(let id), .message(let id): ids = [id]
        case .page(let id, _, let taskID): ids = [id] + (taskID.map { [$0] } ?? [])
        case .archives: ids = []
        case .photo(let id, let inputID): ids = [id, inputID]
        }
        guard ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else { throw CommunicationError.invalidPayload }
    }
}

public enum MemoryHistoryReadResult: Sendable {
    case conversation(StoredConversation)
    case archives([StoredConversation])
    case photo(Data?)

    fileprivate func validate() throws {
        switch self {
        case .conversation(let value):
            guard try JSONEncoder().encode(value).count <= ConversationHistoryStore.maximumBytes else {
                throw CommunicationError.capacityExceeded
            }
        case .archives(let values):
            guard values.count <= 20, try JSONEncoder().encode(values).count <= ConversationHistoryStore.maximumBytes
            else { throw CommunicationError.capacityExceeded }
        case .photo(let data):
            guard (data?.count ?? 0) <= 4 * 1024 * 1024 else { throw CommunicationError.capacityExceeded }
        }
    }
}

/// Private typed request/result staging; only the actual Memory Agent admits the read worker.
public actor MemoryHistoryReadRequests {
    private final class Entry {
        let sessionID: String
        let query: MemoryHistoryRead
        var worker: Task<MemoryHistoryReadResult, Error>?
        var startWaiter: CheckedContinuation<Void, Never>?
        var waiting = false
        var closed = false
        var failure: (any Error)?
        init(sessionID: String, query: MemoryHistoryRead) {
            self.sessionID = sessionID
            self.query = query
        }
    }
    private let read: @Sendable (MemoryHistoryRead) async throws -> MemoryHistoryReadResult
    private var entries: [String: Entry] = [:]
    private var closed = false
    public init(read: @escaping @Sendable (MemoryHistoryRead) async throws -> MemoryHistoryReadResult) {
        self.read = read
    }
    public func stage(_ query: MemoryHistoryRead, sessionID: String) throws -> String {
        guard !closed else { throw CommunicationError.scopeClosed }
        guard entries.count < 4 else { throw CommunicationError.capacityExceeded }
        try query.validate()
        let id = UUID().uuidString
        entries[id] = Entry(sessionID: sessionID, query: query)
        return id
    }
    public func execute(_ id: String, sessionID: String) throws {
        guard !closed, let entry = entries[id], entry.sessionID == sessionID, !entry.closed else {
            throw CommunicationError.scopeClosed
        }
        guard entry.worker == nil else { throw CommunicationError.capacityExceeded }
        let query = entry.query
        let read = self.read
        entry.worker = Task {
            try Task.checkCancellation()
            let result = try await read(query)
            try Task.checkCancellation()
            try result.validate()
            return result
        }
        entry.startWaiter?.resume()
        entry.startWaiter = nil
    }
    public func value(_ id: String) async throws -> MemoryHistoryReadResult {
        guard let entry = entries[id], !entry.waiting else { throw CommunicationError.scopeClosed }
        entry.waiting = true
        defer { entries[id] = nil }
        do {
            return try await withTaskCancellationHandler {
                if entry.worker == nil, !entry.closed {
                    await withCheckedContinuation { entry.startWaiter = $0 }
                }
                try Task.checkCancellation()
                if let failure = entry.failure { throw failure }
                guard !entry.closed, let worker = entry.worker else { throw CommunicationError.scopeClosed }
                let result = try await worker.value
                try Task.checkCancellation()
                guard !entry.closed else { throw entry.failure ?? CommunicationError.scopeClosed }
                return result
            } onCancel: {
                Task { await self.cancel(id) }
            }
        } catch {
            await cancelEntry(entry)
            throw entry.failure ?? error
        }
    }
    public func reject(_ id: String, sessionID: String, error: any Error) async {
        guard let entry = entries[id], entry.sessionID == sessionID else { return }
        entry.failure = error
        await cancelEntry(entry)
    }
    public func cancel(_ id: String, failure: (any Error)? = nil) async {
        guard let entry = entries[id] else { return }
        if let failure { entry.failure = failure }
        await cancelEntry(entry)
    }
    public func discard(_ id: String) async {
        guard let entry = entries[id] else { return }
        await cancelEntry(entry)
        entries[id] = nil
    }
    private func cancelEntry(_ entry: Entry) async {
        entry.closed = true
        entry.worker?.cancel()
        entry.startWaiter?.resume()
        entry.startWaiter = nil
        _ = await entry.worker?.result
    }
    public func shutdown() async {
        closed = true
        let retiring = Array(entries.values)
        for entry in retiring {
            entry.closed = true
            entry.worker?.cancel()
            entry.startWaiter?.resume()
            entry.startWaiter = nil
        }
        for entry in retiring { _ = await entry.worker?.result }
        entries.removeAll()
    }
}

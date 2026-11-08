import AgentCore
import Foundation
import GRDB
import StorageChat
import StorageCore
import StorageFiles
import StorageMedia
import StorageTasks

@testable import Agents
@testable import StorageSQLite

func testSQLiteRepositories(_ directory: URL) throws -> SQLiteRepositories {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return try SQLiteRepositories(url: directory.appendingPathComponent("records.sqlite"))
}
func testConversationRecords(directory: URL) throws -> AssistantRecordStore {
    let records = try testSQLiteRepositories(directory)
    return try AssistantRecordStore(
        repository: records.assistantMessages, tasks: records.assistantTasks,
        conversations: records.assistantConversations, logs: records.logs)
}
private let fixtureTaskCounter = NSLock()
nonisolated(unsafe) private var fixtureTaskNumber: Int64 = 0
func fixtureTaskID() throws -> String {
    fixtureTaskCounter.lock()
    defer { fixtureTaskCounter.unlock() }
    fixtureTaskNumber += 1
    return "task_\(fixtureTaskNumber)"
}

func fixtureMediaStore(root: URL, repositories: SQLiteRepositories? = nil, limits: MediaStore.Limits = .init())
    throws -> MediaStore
{
    let records = try repositories ?? testSQLiteRepositories(root)
    return MediaStore(
        repository: records.media, files: try DiskFileStore(root: root, protection: .afterFirstUnlock), limits: limits)
}
func fixtureAssistantStore(repository: AgentContextRepository<AssistantContextState>, directory: URL) throws
    -> AssistantHistoryStore
{
    let records = try testSQLiteRepositories(directory)
    return try AssistantConversationStorage.store(
        repository: repository, messages: records.assistantMessages, tasks: records.assistantTasks,
        conversations: records.assistantConversations, logs: records.logs)
}

extension SQLiteRepositories {
    public func storageStatistics() throws -> (messages: Int, requests: Int, requestLogBytes: Int) {
        try database.read { db in
            var count = 0
            var responses = 0
            for table in ["assistant_messages", "writer_messages"] {
                count += try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
                responses +=
                    try Int.fetchOne(
                        db,
                        sql:
                            "SELECT COUNT(*) FROM \(table) WHERE json_extract(assistant_response_json,'$.id') IS NOT NULL"
                    ) ?? 0
            }
            return (
                count, responses,
                try Int.fetchOne(
                    db, sql: "SELECT COALESCE(SUM(length(request_body)+length(response_body)),0) FROM model_request_log"
                ) ?? 0
            )
        }
    }
}

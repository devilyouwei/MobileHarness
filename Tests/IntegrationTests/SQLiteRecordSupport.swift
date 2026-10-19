import AgentCore
import Agents
import Foundation
import StorageChat
import StorageCore
import StorageFiles
import StorageMedia
import StorageSQLite
import StorageTasks

func testSQLiteRepositories(_ directory: URL) throws -> SQLiteRepositories {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return try SQLiteRepositories(url: directory.appendingPathComponent("records.sqlite"))
}
func testConversationRecords(directory: URL) throws -> ConversationRecordStore {
    let records = try testSQLiteRepositories(directory)
    return try ConversationRecordStore(repository: records.chat, tasks: records.tasks)
}
private let fixtureTaskDatabase = Result { try SQLiteRepositories.temporary() }
func fixtureTaskID() throws -> String {
    try fixtureTaskDatabase.get().tasks.createTask(
        dialog: nil, agent: "fixture", goal: "fixture", executor: nil, execution: "foreground", parent: nil)
}

func fixtureMediaStore(root: URL, repositories: SQLiteRepositories? = nil, limits: CapturedPhotoStore.Limits = .init())
    throws -> CapturedPhotoStore
{
    let records = try repositories ?? testSQLiteRepositories(root)
    return CapturedPhotoStore(
        repository: records.media, files: try DiskFileStore(root: root, protection: .afterFirstUnlock), limits: limits)
}
func fixtureAssistantStore(repository: AgentContextRepository<AssistantContextState>, directory: URL) throws
    -> ConversationHistoryStore
{
    let records = try testSQLiteRepositories(directory)
    return try AssistantConversationStorage.store(repository: repository, chat: records.chat, tasks: records.tasks)
}

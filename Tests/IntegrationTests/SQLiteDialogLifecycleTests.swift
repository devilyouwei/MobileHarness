import Foundation
import SQLite3
import StorageChat
import Testing

@testable import StorageCore
@testable import StorageSQLite

private func dialogFixtureSQL(_ url: URL, _ sql: String) throws {
    var connection: OpaquePointer?
    let opened = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE, nil)
    defer { if let connection { sqlite3_close(connection) } }
    guard opened == SQLITE_OK else { throw NSError(domain: "SQLiteFixture", code: Int(opened)) }
    sqlite3_busy_timeout(connection, 2000)
    let result = sqlite3_exec(connection, sql, nil, nil, nil)
    guard result == SQLITE_OK else { throw NSError(domain: "SQLiteFixture", code: Int(result)) }
}

private actor DialogPublicationFixture {
    private var value: ConversationArchive
    private var rejectRotation = false
    init(_ value: ConversationArchive) { self.value = value }
    func reject(_ value: Bool) { rejectRotation = value }
    func load() -> ConversationArchive { value }
    func commit(_ candidate: ConversationArchive) throws {
        if rejectRotation, candidate.current.id != value.current.id { throw ConversationHistoryError.conflict }
        value = candidate
    }
}

@Test func sqliteDialogConcurrentCurrentCreationReturnsOneIdentity() async throws {
    let db = try SQLiteRepositories.temporary()
    let ids = try await withThrowingTaskGroup(of: String.self) { group in
        for _ in 0..<8 { group.addTask { try await db.chat.current(agent: "fixture").id } }
        var ids: [String] = []
        for try await id in group { ids.append(id) }
        return ids
    }
    #expect(Set(ids).count == 1)
    #expect(try await db.chat.listDialogs(agent: "fixture").isEmpty)
}

@Test func sqliteDialogFailedNewCurrentInsertionRollsBackArchival() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("records.sqlite")
    let db = try SQLiteRepositories(url: url)
    let old = try await db.chat.current(agent: "fixture")
    try dialogFixtureSQL(
        url, "CREATE TRIGGER reject_new_dialog BEFORE INSERT ON dialogs BEGIN SELECT RAISE(ABORT,'fixture'); END")
    #expect(throws: (any Error).self) { _ = try db.chat.rotate(old.id, agent: "fixture") }
    #expect(try await db.chat.dialog(old.id).archivedAt == nil)
    #expect(try await db.chat.current(agent: "fixture").id == old.id)
    #expect(try await db.chat.listDialogs(agent: "fixture").isEmpty)
    try dialogFixtureSQL(url, "DROP TRIGGER reject_new_dialog")
    #expect(throws: RecordStorageError.missingRecord) { _ = try db.chat.rotate(old.id, agent: "other") }
    #expect(try await db.chat.dialog(old.id).archivedAt == nil)
    let next = try db.chat.rotate(old.id, agent: "fixture")
    #expect(next.id != old.id && next.archivedAt == nil)
    #expect(try await db.chat.listDialogs(agent: "fixture").map(\.id) == [old.id])
}

@Test func sqliteDialogCommittedRotationFencesFailedMemoryPublicationAndRecovers() async throws {
    let db = try SQLiteRepositories.temporary()
    let store = ConversationHistoryStore(records: try ConversationRecordStore(repository: db.chat, tasks: db.tasks))
    let initial = try await store.readCurrent()
    _ = try await store.begin(id: "old-input", user: "old", request: [], expecting: initial.token, model: "fixture")
    try await store.finish("old-input", state: .completed)
    let memory = DialogPublicationFixture(try await store.snapshot())
    try await store.attachContext(
        identity: "fixture", load: { await memory.load() }, commit: { try await memory.commit($0) })
    let oldRead = try await store.readCurrent()
    await memory.reject(true)
    await #expect(throws: ConversationHistoryError.conflict) { _ = try await store.startNew() }
    let durable = try await db.chat.current(agent: "assistant")
    #expect(durable.id != initial.current.id)
    #expect(try await db.chat.dialog(initial.current.id).archivedAt != nil)
    #expect(await memory.load().current.id == initial.current.id)
    await #expect(throws: ConversationHistoryError.conflict) { _ = try await store.readCurrent() }
    await #expect(throws: ConversationHistoryError.conflict) { _ = try await store.page(initial.current.id) }
    await #expect(throws: ConversationHistoryError.conflict) {
        _ = try await store.begin(id: "rejected", user: "no", request: [], expecting: oldRead.token, model: "fixture")
    }
    #expect(try db.chat.messages(dialog: durable.id).isEmpty)
    await memory.reject(false)
    // Recovery invalidates an old read token even if it happens inside begin itself.
    await #expect(throws: ConversationHistoryError.conflict) {
        _ = try await store.begin(id: "stale", user: "no", request: [], expecting: oldRead.token, model: "fixture")
    }
    let recovered = try await store.readCurrent()
    #expect(recovered.current.id == durable.id && recovered.current.turns.isEmpty)
    #expect(try await store.startNew() == nil)
    #expect(try await db.chat.listDialogs(agent: "assistant").count == 1)
    _ = try await store.begin(
        id: "new-input", user: "new", request: [], expecting: recovered.token, model: "fixture")
    #expect(try db.chat.messages(dialog: durable.id).first?.body == "new")
    #expect(try db.chat.messages(dialog: initial.current.id).first?.body == "old")
}

@Test func sqliteDialogMissingCurrentIsRecreatedBeforeAdmission() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("records.sqlite")
    let db = try SQLiteRepositories(url: url)
    let store = ConversationHistoryStore(records: try ConversationRecordStore(repository: db.chat, tasks: db.tasks))
    let initial = try await store.readCurrent()
    // Simulate a missing current after memory has already loaded, without deleting user data.
    try dialogFixtureSQL(url, "UPDATE dialogs SET archived_at=1 WHERE archived_at IS NULL")
    try dialogFixtureSQL(
        url, "CREATE TRIGGER reject_missing_current BEFORE INSERT ON dialogs BEGIN SELECT RAISE(ABORT,'fixture'); END")
    await #expect(throws: (any Error).self) { _ = try await store.readCurrent() }
    #expect(try await store.snapshot().current.id == initial.current.id)
    try dialogFixtureSQL(url, "DROP TRIGGER reject_missing_current")
    await #expect(throws: ConversationHistoryError.conflict) {
        _ = try await store.begin(
            id: "stale", user: "stale", request: [], expecting: initial.token, model: "fixture")
    }
    let fresh = try await store.readCurrent()
    #expect(fresh.current.id != initial.current.id)
    let writes = db.committedWriteCount
    _ = try await store.begin(id: "fresh", user: "hello", request: [], expecting: fresh.token, model: "fixture")
    #expect(db.committedWriteCount == writes + 1)
    #expect(try db.chat.messages(dialog: fresh.current.id).first?.body == "hello")
}

@Test func sqliteDialogArchivedInsertIsRejectedButLateExistingUpdateRemainsValid() async throws {
    let db = try SQLiteRepositories.temporary()
    let old = try await db.chat.current(agent: "fixture")
    let response = try db.chat.beginMessage(
        dialog: old.id,
        identity: .init(
            clientID: "response", inputID: "input", role: "assistant", kind: "response", order: 1, date: Date()))
    let current = try db.chat.rotate(old.id, agent: "fixture")
    #expect(throws: RecordStorageError.conflict) {
        _ = try db.chat.beginMessage(
            dialog: old.id,
            identity: .init(clientID: "new", inputID: "new", role: "user", kind: "input", order: 2, date: Date()))
    }
    let existing = MessageRecord(
        clientID: "response", inputID: "input", role: "assistant", kind: "response", order: 1, date: Date(),
        body: "late result", state: "completed", detail: Data("{}".utf8), id: response)
    let new = MessageRecord(
        clientID: "new", inputID: "new", role: "user", kind: "input", order: 2, date: Date(),
        body: "must not insert", state: "completed", detail: Data("{}".utf8))
    #expect(throws: RecordStorageError.conflict) {
        try db.chat.save(dialog: old.id, revision: 2, recovery: nil, messages: [existing, new], summaries: [])
    }
    #expect(try db.chat.messages(dialog: old.id).first?.body == "")
    try db.chat.save(dialog: old.id, revision: 3, recovery: nil, messages: [existing], summaries: [])
    #expect(try db.chat.messages(dialog: old.id).map(\.id) == [response])
    #expect(try db.chat.messages(dialog: old.id).first?.body == "late result")
    #expect(try await db.chat.current(agent: "fixture").id == current.id)
}

@Test func sqliteDialogMismatchRetainsActiveInputUntilItsTerminalCheckpoint() async throws {
    let db = try SQLiteRepositories.temporary()
    let store = ConversationHistoryStore(records: try ConversationRecordStore(repository: db.chat, tasks: db.tasks))
    let read = try await store.readCurrent()
    _ = try await store.begin(id: "active", user: "keep me", request: [], expecting: read.token, model: "fixture")
    let current = try db.chat.rotate(read.current.id, agent: "assistant")
    await #expect(throws: ConversationHistoryError.conflict) { _ = try await store.readCurrent() }
    await #expect(throws: ConversationHistoryError.conflict) {
        try await store.beginModelRequest(.init(id: "request", input: "keep me", requestJSON: "[]"), for: "active")
    }
    let retained = try await store.snapshot().current
    #expect(retained.id == read.current.id && retained.turns.first?.user == "keep me")
    #expect(try db.chat.messages(dialog: current.id).isEmpty)
    try await store.finish("active", state: .failed, error: "current changed")
    #expect(try await store.readCurrent().current.id == current.id)
    #expect(try db.chat.messages(dialog: read.current.id).first?.body == "keep me")
}

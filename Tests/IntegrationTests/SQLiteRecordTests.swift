import Actions
import Foundation
import Gateway
import PlatformKit
import StorageFiles
import StorageMedia
import StorageTasks
import Testing

@testable import Agents
@testable import StorageChat
@testable import StorageCore
@testable import StorageSQLite
@testable import UI

#if os(macOS)
    import Darwin
#endif

@Test func sqliteBusinessIDsAreCommittedIndependentAndNeverReused() async throws {
    let db = try SQLiteRepositories.temporary()
    let dialog = try await db.assistantConversations.current()
    #expect(dialog.id == "dialog_1")
    let device = try db.devices.device(nativeID: UUID().uuidString, name: "fixture")
    #expect(device == "device_1")
    let ids = await withTaskGroup(of: String?.self) { group in
        for _ in 0..<64 {
            group.addTask {
                try? await db.assistantTasks.createTask(dialog: dialog.id, agent: "assistant", goal: "goal")
            }
        }
        var result: [String] = []
        for await id in group { if let id { result.append(id) } }
        return result
    }
    #expect(ids.count == 1)
    try await db.assistantTasks.endTask(try #require(ids.first), status: "cancelled")
    let nextDialog = try db.assistantConversations.rotate(dialog.id)
    try db.assistantConversations.deleteDialog(dialog.id)
    #expect(nextDialog.id == "dialog_2")
    let next = try await db.assistantTasks.createTask(dialog: nextDialog.id, agent: "assistant", goal: "new")
    #expect(BusinessRecordID(rawValue: next)?.number == 2)
}

@Test func sqliteArchivedDialogsUseTwentyItemPages() async throws {
    let db = try SQLiteRepositories.temporary()
    let records = try AssistantRecordStore(
        repository: db.assistantMessages, tasks: db.assistantTasks, conversations: db.assistantConversations,
        logs: db.logs)
    var current = try await db.assistantConversations.current()
    for _ in 0..<21 { current = try db.assistantConversations.rotate(current.id) }
    let first = try await records.list()
    #expect(first.count == 20 && first.first?.id == "dialog_21" && first.last?.id == "dialog_2")
    let second = try await records.list(before: 2)
    #expect(second.count == 1 && second.first?.id == "dialog_1")
    #expect(try db.assistantConversations.listDialogs().count == 20)
}

@Test func sqliteRollbackDoesNotPublishMessagesOrAdvanceRevision() async throws {
    let db = try SQLiteRepositories.temporary()
    let dialog = try await db.assistantConversations.current()
    let message = AssistantMessageRecord(
        clientID: UUID().uuidString, inputID: UUID().uuidString, role: "assistant", kind: "response",
        order: 1, date: Date(), body: "must roll back", state: "completed", taskID: "task_999999",
        detail: Data("{}".utf8))
    #expect(throws: (any Error).self) {
        try db.assistantMessages.save(dialog: dialog.id, revision: 7, messages: [message], summaries: [])
    }
    #expect(try db.assistantMessages.previews(dialog: dialog.id).isEmpty)
    #expect(try await db.assistantConversations.dialog(dialog.id).revision == 0)
}

@Test func sqliteReACTCommitsEachMessageAndDeltaDoesNotWrite() async throws {
    let db = try SQLiteRepositories.temporary()
    let adapter = try AssistantRecordStore(
        repository: db.assistantMessages, tasks: db.assistantTasks, conversations: db.assistantConversations,
        logs: db.logs)
    let store = AssistantHistoryStore(records: adapter)
    let input = UUID().uuidString
    let snapshot = try await store.readCurrent()
    _ = try await store.begin(id: input, user: "hello", request: [], expecting: snapshot.token, model: "fixture")
    #expect(await adapter.checkpointCount == 1)
    let first = UUID().uuidString
    try await store.beginModelRequest(.init(id: first, input: "hello", requestJSON: "[]"), for: input)
    for _ in 0..<10 { try await store.append("a", to: input) }
    #expect(await adapter.checkpointCount == 1)
    try await store.finishModelRequest(input, reason: "stop")
    #expect(await adapter.checkpointCount == 2)
    let second = UUID().uuidString
    try await store.beginModelRequest(
        .init(id: second, input: "Execution observations: result", requestJSON: "[]"), for: input)
    #expect(await adapter.checkpointCount == 3)
    let committed = try await db.assistantMessages.messages(dialog: snapshot.current.id)
    #expect(committed.map(\.kind) == ["input", "response", "observation", "response"])
    #expect(committed.last?.state == "generating" && committed.last?.body.isEmpty == true)
    #expect(committed.first { $0.role == "assistant" }?.body == "aaaaaaaaaa")
    // A fresh reader sees finished ReACT output despite the overall decision still running.
    let reopened = AssistantHistoryStore(
        records: try AssistantRecordStore(
            repository: db.assistantMessages, tasks: db.assistantTasks, conversations: db.assistantConversations,
            logs: db.logs))
    let history = try await reopened.snapshot()
    #expect(history.current.turns.first?.modelRequests?.first?.response == "aaaaaaaaaa")
    try await store.append("partial", to: input)
    try await store.finish(input, state: .cancelled)
    let final = try await db.assistantMessages.messages(dialog: snapshot.current.id)
    #expect(final.count == 4 && final.last?.state == "cancelled")
    let count = final.count
    try await store.checkpoint()
    #expect(try await db.assistantMessages.messages(dialog: snapshot.current.id).count == count)
}

@Test func sqliteMediaUsesShortNamesAndRecoversPendingFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try testSQLiteRepositories(root)
    let owner = StorageOwner(
        namespace: "photos", source: "fixture", session: UUID().uuidString, input: UUID().uuidString)
    let bytes = Data([0xff, 0xd8, 0xff, 0xd9])
    let store = try fixtureMediaStore(root: root, repositories: db)
    let first = try await store.save(bytes, owner: owner)
    let record = try #require(try db.media.media(first))
    #expect(first == "media_1")
    #expect(record.path.range(of: "^[0-9]{8}_[0-9]{6}_1\\.jpg$", options: .regularExpression) != nil)
    let pending = try db.media.reserveMedia(
        bytes: bytes.count, source: owner.source, session: owner.session, input: owner.input, date: Date())
    try bytes.write(to: root.appendingPathComponent(pending.path), options: .atomic)
    let reopened = try fixtureMediaStore(root: root, repositories: db)
    #expect(try await reopened.read(pending.id, owner: owner) == bytes)
    #expect(try db.media.media(pending.id)?.state == "ready")
    let missing = try db.media.reserveMedia(
        bytes: bytes.count, source: owner.source, session: owner.session, input: owner.input, date: Date())
    let again = try fixtureMediaStore(root: root, repositories: db)
    await #expect(throws: FileStorageError.invalidFile) { try await again.read(missing.id, owner: owner) }
    #expect(try db.media.media(missing.id)?.state == "failed")
}

@Test func sqliteMediaPublicationFailureRetainsUnavailableReference() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try testSQLiteRepositories(root)
    let owner = StorageOwner(
        namespace: "photos", source: "fixture", session: UUID().uuidString, input: UUID().uuidString)
    // A non-overwritable destination forces failure after pending metadata has committed.
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = TimeZone(secondsFromGMT: 0)
    format.dateFormat = "yyyyMMdd_HHmmss"
    let capturedAt = Date()
    let occupied = root.appendingPathComponent(format.string(from: capturedAt) + "_1.jpg")
    try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
    let store = try fixtureMediaStore(root: root, repositories: db)
    await #expect(throws: (any Error).self) {
        _ = try await store.save(Data([1, 2]), owner: owner, capturedAt: capturedAt)
    }
    #expect(try db.media.media("media_1")?.state == "failed")
    #expect(FileManager.default.fileExists(atPath: occupied.path))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MH_STORAGE_BENCHMARK"] == "1"), .timeLimit(.minutes(3)))
func sqliteHundredThousandMessagesHaveBoundedIndexedPages() async throws {
    let db = try SQLiteRepositories.temporary()
    let dialog = try await db.assistantConversations.current()
    let task = try await db.assistantTasks.createTask(dialog: dialog.id, agent: "assistant", goal: "benchmark")
    let start = ContinuousClock.now
    for batch in 0..<100 {
        let messages = (0..<1000).map { offset in
            let position = batch * 1000 + offset + 1
            return AssistantMessageRecord(
                clientID: "fixture-\(position)",
                inputID: "fixture-\(position.isMultiple(of: 2) ? position-1 : position)",
                role: position.isMultiple(of: 2) ? "assistant" : "user",
                kind: position.isMultiple(of: 2) ? "response" : "input",
                order: UInt64(position), date: Date(), body: "response \(position)", state: "completed",
                taskID: position.isMultiple(of: 2) ? task : nil, detail: Data("{}".utf8))
        }
        try db.assistantMessages.save(
            dialog: dialog.id, revision: UInt64(batch + 1), messages: messages, summaries: [])
    }
    let seeded = ContinuousClock.now
    #if os(macOS)
        var initialUsage = rusage()
        #expect(getrusage(RUSAGE_SELF, &initialUsage) == 0)
    #endif
    let page = try db.assistantMessages.previews(dialog: dialog.id, after: 99_800)
    #expect(page.count == 20 && page.first?.position == 99_802 && page.last?.position == 99_840)
    let next = try db.assistantMessages.previews(dialog: dialog.id, after: try #require(page.last).position)
    #expect(next.count == 20 && next.last?.position == 99_880)
    #expect(Set(page.map(\.id)).isDisjoint(with: Set(next.map(\.id))))
    let pageTime = ContinuousClock.now - seeded
    let plan = try db.assistantMessages.previewQueryPlan(dialog: dialog.id, after: 99_900)
    let taskPlan = try db.assistantMessages.previewQueryPlan(dialog: dialog.id, after: 99_900, taskID: task)
    #expect(plan.contains { $0.contains("request_order") && $0.contains("position>?") })
    #expect(taskPlan.contains { $0.contains("request_order") && $0.contains("position>?") })
    #expect(!plan.contains { $0.contains("TEMP B-TREE") || $0.contains("SCAN m") })
    #expect(!taskPlan.contains { $0.contains("TEMP B-TREE") || $0.contains("SCAN m") })
    var maxPayloadBytes = 0
    for position in stride(from: 0, to: 100_000, by: 1000) {
        let values = try db.assistantMessages.previews(dialog: dialog.id, after: UInt64(position))
        #expect(values.count == 20)
        let bytes = values.reduce(0) {
            $0 + $1.input.utf8.count + $1.response.utf8.count + $1.clientID.utf8.count + $1.id.utf8.count
        }
        maxPayloadBytes = max(maxPayloadBytes, bytes)
    }
    #expect(maxPayloadBytes < 64 * 1024)
    let added = AssistantMessageRecord(
        clientID: UUID().uuidString, inputID: UUID().uuidString, role: "assistant", kind: "response",
        order: 100_001, date: Date(), body: "one new message", state: "completed", detail: Data("{}".utf8))
    try db.assistantMessages.save(dialog: dialog.id, revision: 101, messages: [added], summaries: [])
    let changedRows = db.lastWriteChanges
    #expect(changedRows <= 8)
    #expect(try db.storageStatistics().messages == 50_001)
    try db.assistantMessages.save(dialog: dialog.id, revision: 101, messages: [added], summaries: [])
    #expect(try db.storageStatistics().messages == 50_001)
    #expect(db.lastWriteChanges <= 8)
    #if os(macOS)
        var usage = rusage()
        #expect(getrusage(RUSAGE_SELF, &usage) == 0)
        let growth = usage.ru_maxrss - initialUsage.ru_maxrss
        #expect(growth < 32 * 1024 * 1024)
        print("SQLITE_100K peak_process_bytes=\(usage.ru_maxrss), post_seed_pagination_peak_growth_bytes=\(growth)")
    #endif
    print(
        "SQLITE_100K seed=\(seeded-start), two_pages=\(pageTime), max_preview_bytes=\(maxPayloadBytes), new_message_changed_rows=\(changedRows)"
    )
    print("SQLITE_100K dialog_plan=\(plan), task_plan=\(taskPlan)")
}

@Test func sqliteContextWindowDoesNotTruncatePersistedDialogOrTaskSources() async throws {
    let db = try SQLiteRepositories.temporary()
    let adapter = try AssistantRecordStore(
        repository: db.assistantMessages, tasks: db.assistantTasks, conversations: db.assistantConversations,
        logs: db.logs)
    let store = AssistantHistoryStore(records: adapter)
    let dialog = try await store.readCurrent().current.id
    let task = try await db.assistantTasks.createTask(dialog: dialog, agent: "assistant", goal: "long task")
    for number in 0..<32 {
        let input = UUID().uuidString
        let token = try await store.readCurrent().token
        _ = try await store.begin(id: input, user: "input \(number)", request: [], expecting: token, model: "fixture")
        try await store.beginModelRequest(
            .init(id: UUID().uuidString, input: "input \(number)", requestJSON: "[]", historyTaskID: task), for: input)
        try await store.append("response \(number)", to: input)
        try await store.finishModelRequest(input, reason: "stop")
        try await store.finish(input, state: .completed)
    }
    let window = try await store.readCurrent().current
    #expect(window.turns.count == 10)
    #expect(await adapter.cachedFingerprintCount <= 24)
    #expect(try await db.assistantConversations.dialog(dialog).count == 32)
    #expect(try db.assistantMessages.timelineCount(dialog: dialog) == 32)
    let sources = window.turns.flatMap { turn in
        (turn.modelRequests ?? []).map { AssistantHistoryReference(inputID: turn.id, requestID: $0.id) }
    }
    var compressed = window
    compressed.taskCompressions = [
        .init(
            taskID: task, goal: "long task", status: .completed, reportedSummary: "done", failure: nil,
            completedAt: Date(), sources: sources)
    ]
    try await adapter.saveCurrent(.init(conversation: compressed))
    let summaries = try await db.assistantTasks.compressionData(dialog: dialog)
    #expect(
        try JSONDecoder().decode(AssistantTaskCompression.self, from: try #require(summaries.first)).sources.count
            == 32)
    #expect(try db.assistantMessages.timelineCount(dialog: dialog) == 1)
    let taskPage = try await adapter.page(dialog, taskID: task)
    #expect(taskPage.turns.count == 20)
    let taskRemainder = try await adapter.page(dialog, after: try #require(taskPage.nextPosition), taskID: task)
    #expect(taskRemainder.turns.count == 12 && taskRemainder.nextPosition == nil)
    #expect(try await adapter.read(dialog).turns.count == 32)
    let collapsed = try await adapter.page(dialog)
    let displayed = try await HistoryPresentationAdapter.conversation(collapsed)
    let items = ConversationHistoryPresentation.timeline(displayed)
    #expect(items.count == 1)
    guard case .task(let compression, let visible) = try #require(items.first) else {
        Issue.record("Committed multi-message Task must render as an expandable Task card")
        return
    }
    #expect(compression.taskID == task && compression.sources.count == 32 && visible.count == 1)
    var expanded = try await HistoryPresentationAdapter.conversation(taskPage)
    let remainingDisplay = try await HistoryPresentationAdapter.conversation(taskRemainder)
    try expanded.appendPage(remainingDisplay)
    #expect(ConversationHistoryPresentation.turns(expanded).count == 32)
    let reopened = try AssistantRecordStore(
        repository: db.assistantMessages, tasks: db.assistantTasks, conversations: db.assistantConversations,
        logs: db.logs)
    let reopenedPage = try await reopened.page(dialog)
    let reopenedDisplay = try await HistoryPresentationAdapter.conversation(reopenedPage)
    guard case .task(let saved, _) = try #require(ConversationHistoryPresentation.timeline(reopenedDisplay).first)
    else {
        Issue.record("Task card must survive reopening without live Task state")
        return
    }
    #expect(saved.sources.count == 32)
}

@Test func sqliteCompletedUserWithoutResponseRemainsReadableWithoutFabricatingResponse() async throws {
    let db = try SQLiteRepositories.temporary()
    let store = AssistantHistoryStore(
        records: try AssistantRecordStore(
            repository: db.assistantMessages, tasks: db.assistantTasks, conversations: db.assistantConversations,
            logs: db.logs))
    let snapshot = try await store.readCurrent()
    _ = try await store.begin(
        id: UUID().uuidString, user: "unfinished request", request: [], expecting: snapshot.token, model: "fixture")
    try db.recoverInFlight()
    let page = try await store.page(snapshot.current.id)
    #expect(page.turns.count == 1)
    let id = try #require(page.turns.first?.modelRequests?.first?.messageID)
    let detail = try await store.message(id)
    #expect(detail.turns.first?.modelRequests?.first?.input == "unfinished request")
    #expect(detail.turns.first?.modelRequests?.first?.response == "")
    #expect(detail.turns.first?.modelRequests?.first?.state == .completed)
}

@Test func sqliteTaskOnLaterHistoryPageFoldsExpandsAndSurvivesArchival() async throws {
    let db = try SQLiteRepositories.temporary()
    let records = try AssistantRecordStore(
        repository: db.assistantMessages, tasks: db.assistantTasks, conversations: db.assistantConversations,
        logs: db.logs)
    let store = AssistantHistoryStore(records: records)
    let dialog = try await store.readCurrent().current.id
    let task = try await db.assistantTasks.createTask(dialog: dialog, agent: "assistant", goal: "later Task")
    for number in 0..<24 {
        let input = UUID().uuidString
        let read = try await store.readCurrent()
        _ = try await store.begin(
            id: input, user: "input \(number)", request: [], expecting: read.token, model: "fixture")
        try await store.beginModelRequest(
            .init(
                id: UUID().uuidString, input: "input \(number)", requestJSON: "[]",
                historyTaskID: number >= 21 ? task : nil), for: input)
        try await store.append("response \(number)", to: input)
        try await store.finishModelRequest(input, reason: "stop")
        try await store.finish(input, state: .completed)
    }
    var window = try await store.readCurrent().current
    let sources = window.turns.flatMap { turn in
        (turn.modelRequests ?? []).filter { $0.historyTaskID == task }.map {
            AssistantHistoryReference(inputID: turn.id, requestID: $0.id)
        }
    }
    window.taskCompressions = [
        .init(
            taskID: task, goal: "later Task", status: .completed, reportedSummary: "done", failure: nil,
            completedAt: Date(), sources: sources)
    ]
    try await records.saveCurrent(.init(conversation: window))
    #expect(try db.storageStatistics().messages == 24)
    #expect(try db.assistantTasks.taskSources(task).count == 3)
    let first = try await records.page(dialog)
    var display = try await HistoryPresentationAdapter.conversation(first)
    #expect(display.turns.count == 20 && display.taskCompressions.isEmpty)
    let next = try await records.page(dialog, after: try #require(first.nextPosition))
    let nextDisplay = try await HistoryPresentationAdapter.conversation(next)
    try display.appendPage(nextDisplay)
    let items = ConversationHistoryPresentation.timeline(display)
    guard case .task(let compression, _) = try #require(items.last) else {
        Issue.record("A committed Task after twenty ordinary records must remain visible")
        return
    }
    #expect(items.count == 22 && compression.sources.count == 3 && display.nextPosition == nil)
    let expanded = try await records.page(dialog, taskID: task)
    let expandedDisplay = try await HistoryPresentationAdapter.conversation(expanded)
    let turns = ConversationHistoryPresentation.turns(expandedDisplay)
    #expect(turns.map(\.response) == ["response 21", "response 22", "response 23"])
    let detail = try await records.message(try #require(turns[1].messageID))
    #expect(detail.turns.first?.modelRequests?.first?.response == "response 22")
    _ = try await store.startNew()
    let reopened = try AssistantRecordStore(
        repository: db.assistantMessages, tasks: db.assistantTasks, conversations: db.assistantConversations,
        logs: db.logs)
    let archived = try await reopened.page(dialog, after: try #require(first.nextPosition))
    let archivedDisplay = try await HistoryPresentationAdapter.conversation(archived)
    guard case .task(let saved, _) = try #require(ConversationHistoryPresentation.timeline(archivedDisplay).last) else {
        Issue.record("Archived Task cards must load from SQL without live Task state")
        return
    }
    #expect(saved.taskID == task && saved.reportedSummary == "done")
    #expect(try db.storageStatistics().messages == 24)
}

@Test func sqliteLargeSnapshotsKeepFullIndependentJSONAndExactUnicodeStrings() async throws {
    let db = try SQLiteRepositories.temporary()
    let dialog = try await db.assistantConversations.current()
    let prompt = String(repeating: "提示词🙂 with spaces\n", count: 2000)
    let catalog = String(repeating: "registered action / tool\n", count: 1000)
    var original: [String: String] = [:]
    for index in 0..<3 {
        let client = UUID().uuidString
        let detail = try JSONSerialization.data(withJSONObject: [
            "requestJSON": prompt + " user=\(index)", "catalogJSON": catalog,
        ])
        try db.assistantMessages.save(
            dialog: dialog.id, revision: UInt64(index),
            messages: [
                .init(
                    clientID: client, inputID: client, role: "assistant", kind: "response", order: UInt64(index + 1),
                    date: Date(), body: "answer", state: "completed", detail: detail)
            ], summaries: [])
        let payload = String(
            decoding: try JSONSerialization.data(withJSONObject: [
                "prompt": prompt + " user=\(index)", "catalog": catalog,
            ]), as: UTF8.self)
        try await db.logs.writeRequestPayload(client, agent: "assistant", json: payload, response: "[]", initial: true)
        let id = try #require(try db.assistantMessages.previews(dialog: dialog.id).last?.id)
        original[id] = prompt + " user=\(index)"
    }
    for (id, text) in original {
        let detail = try #require(try db.assistantMessages.messageEvidence(id).first?.detail)
        let json = try #require(try JSONSerialization.jsonObject(with: detail) as? [String: Any])
        #expect(json["requestJSON"] as? String == "[]")
        let log = try #require(try await db.logs.requestPayload(id, agent: "assistant"))
        let payload = try #require(JSONSerialization.jsonObject(with: Data(log.requestJSON.utf8)) as? [String: String])
        #expect(payload["prompt"] == text && payload["catalog"] == catalog)
    }
    let statistics = try db.storageStatistics()
    #expect(statistics.requests == 3)
    #expect(statistics.requestLogBytes > (prompt.utf8.count + catalog.utf8.count) * 3)
}

@Test func sqliteAgentPartitionAndSharedEvidenceSurviveDeletion() async throws {
    let db = try SQLiteRepositories.temporary()
    let first = try await db.assistantConversations.current()
    _ = try await db.seedDelegation(
        workspaceID: nil, goal: "independent", input: "work", sourceDialog: first.id, agent: "writer")
    let second = try await db.writerMessages.current()
    let text = String(repeating: "shared Unicode🙂\n", count: 1000)
    let detail = try JSONSerialization.data(withJSONObject: ["requestJSON": text])
    do {
        let client = UUID().uuidString
        try db.assistantMessages.save(
            dialog: first.id, revision: 1,
            messages: [
                .init(
                    clientID: client, inputID: client, role: "assistant", kind: "response", order: 1,
                    date: Date(), body: "response", state: "completed", detail: detail)
            ], summaries: [])
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: ["prompt": text]), as: UTF8.self)
        try await db.logs.writeRequestPayload(client, agent: "assistant", json: payload, response: "[]", initial: true)
    }
    do {
        let client = UUID().uuidString
        try db.writerMessages.save(
            ownerID: second.id, revision: 1,
            messages: [
                .init(
                    clientID: client, inputID: client, role: "assistant", kind: "response", order: 1,
                    date: Date(), body: "response", state: "completed", detail: detail)
            ])
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: ["prompt": text]), as: UTF8.self)
        try await db.logs.writeRequestPayload(client, agent: "writer", json: payload, response: "[]", initial: true)
    }
    let id = try #require(try db.writerMessages.previews(ownerID: second.id).first?.id)
    let adapter = try AssistantRecordStore(
        repository: db.assistantMessages, tasks: db.assistantTasks, conversations: db.assistantConversations,
        logs: db.logs)
    await #expect(throws: RecordStorageError.missingRecord) { _ = try await adapter.message(id) }
    _ = try db.assistantConversations.rotate(first.id)
    try db.assistantConversations.deleteDialog(first.id)
    let data = try #require(try db.writerMessages.messageEvidence(id).first?.detail)
    let restored = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(restored["requestJSON"] as? String == "[]")
    let log = try #require(try await db.logs.requestPayload(id, agent: "writer"))
    let payload = try #require(JSONSerialization.jsonObject(with: Data(log.requestJSON.utf8)) as? [String: Any])
    #expect(payload["prompt"] as? String == text)
}

@Test func sqliteRawPagesUseHistoryPositionAndKeepTiedRows() async throws {
    let db = try SQLiteRepositories.temporary()
    let dialog = try await db.assistantConversations.current()
    let values = (1...6).reversed().map { number in
        AssistantMessageRecord(
            clientID: "order-\(number)", inputID: "order-\(number)", role: "assistant", kind: "response",
            order: UInt64((number + 1) / 2), date: Date(), body: "body \(number)", state: "completed",
            detail: Data("{}".utf8))
    }
    try db.assistantMessages.save(dialog: dialog.id, revision: 1, messages: values, summaries: [])
    var cursor: Int64?
    var orders: [UInt64] = []
    var identifiers: Set<String> = []
    while true {
        let page = try db.assistantMessages.messagePage(dialog: dialog.id, after: cursor, limit: 1)
        for item in page.records where item.role == "assistant" {
            orders.append(item.order)
            #expect(identifiers.insert(try #require(item.id)).inserted)
        }
        guard let next = page.next else { break }
        cursor = next
    }
    #expect(orders == [1, 1, 2, 2, 3, 3])
    #expect(identifiers.count == 6)
}

@Test func sqlitePreviewsRemainSmallAndDetailKeepsFullBody() async throws {
    let db = try SQLiteRepositories.temporary()
    let dialog = try await db.assistantConversations.current()
    let body = String(repeating: "大正文🙂", count: 20_000)
    let input = UUID().uuidString
    try db.assistantMessages.save(
        dialog: dialog.id, revision: 1,
        messages: [
            .init(
                clientID: input, inputID: input, role: "assistant", kind: "response", order: 1, date: Date(),
                body: body, state: "completed", detail: Data("{}".utf8))
        ], summaries: [])
    let preview = try #require(try db.assistantMessages.previews(dialog: dialog.id).first)
    #expect(preview.response == String(body.prefix(240)))
    #expect(try db.assistantMessages.messageEvidence(preview.id).first?.body == body)
}

@Test func sqliteMessageIdentityExistsBeforeGenerationAndDeltasNeverWrite() async throws {
    let db = try SQLiteRepositories.temporary()
    let records = try AssistantRecordStore(
        repository: db.assistantMessages, tasks: db.assistantTasks, conversations: db.assistantConversations,
        logs: db.logs)
    let store = AssistantHistoryStore(records: records)
    let read = try await store.readCurrent()
    let input = UUID().uuidString
    let writesBeforeAdmission = db.committedWriteCount
    let user = try await store.begin(id: input, user: "hello", request: [], expecting: read.token, model: "fixture")
    let userID = try #require(user.messageID)
    #expect(db.committedWriteCount == writesBeforeAdmission + 1)
    let accepted = try await db.assistantMessages.messages(dialog: read.current.id)
    #expect(accepted.count == 1)
    #expect(accepted.first?.id == userID && accepted.first?.body == "hello")
    #expect(accepted.first?.state == "completed" && accepted.first?.detail.isEmpty == false)
    #expect(try await store.readCurrent().current.turns.first?.messageID == userID)
    #expect(try await db.assistantConversations.dialog(read.current.id).count == 1)
    try await store.checkpoint(inputID: input)
    #expect(try await db.assistantMessages.messages(dialog: read.current.id).map(\.id) == [userID])
    #expect(try await db.assistantConversations.dialog(read.current.id).count == 1)
    let requestID = UUID().uuidString
    try await store.beginModelRequest(.init(id: requestID, input: "hello", requestJSON: "[]"), for: input)
    let request = try #require(try await store.snapshot().current.turns.first?.modelRequests?.first)
    let responseID = try #require(request.messageID)
    #expect(request.inputMessageID == userID && responseID != userID)
    let identities = try await db.assistantMessages.messages(dialog: read.current.id)
    #expect(identities.count == 2)
    #expect(identities.first?.state == "completed")
    #expect(identities.last?.id == responseID && identities.last?.state == "generating")
    #expect(identities.last?.body.isEmpty == true)
    let header = try JSONDecoder().decode(AssistantModelRequest.self, from: #require(identities.last?.detail))
    #expect(header.id == requestID && header.requestJSON == "[]" && header.response.isEmpty)
    let writes = db.committedWriteCount
    for _ in 0..<100 { try await store.append("chunk", to: input) }
    #expect(db.committedWriteCount == writes)
    #expect(try await db.assistantMessages.messages(dialog: read.current.id).last?.body == "")
    try await store.finishModelRequest(input, reason: "stop")
    let completed = try await db.assistantMessages.messages(dialog: read.current.id)
    #expect(completed.last?.id == responseID && completed.last?.state == "completed")
    #expect(completed.last?.body == String(repeating: "chunk", count: 100))
    try await store.checkpoint()
    #expect(try await db.assistantMessages.messages(dialog: read.current.id).map(\.id) == completed.map(\.id))
}

private actor UserIdentityPublicationFixture {
    private var value: AssistantArchive
    private var rejectIdentity = true
    init(_ value: AssistantArchive) { self.value = value }
    func load() -> AssistantArchive { value }
    func commit(_ candidate: AssistantArchive) throws {
        if rejectIdentity, candidate.current.turns.contains(where: { $0.messageID != nil }) {
            rejectIdentity = false
            throw AssistantHistoryError.conflict
        }
        value = candidate
    }
}

@Test func sqliteCompletedUserInsertRetriesFailedIdentityPublicationWithoutDuplicates() async throws {
    let db = try SQLiteRepositories.temporary()
    let records = try AssistantRecordStore(
        repository: db.assistantMessages, tasks: db.assistantTasks, conversations: db.assistantConversations,
        logs: db.logs)
    let store = AssistantHistoryStore(records: records)
    let memory = UserIdentityPublicationFixture(try await store.snapshot())
    try await store.attachContext(
        identity: "fixture", load: { await memory.load() }, commit: { try await memory.commit($0) })
    let read = try await store.readCurrent()
    let input = UUID().uuidString
    await #expect(throws: AssistantHistoryError.conflict) {
        _ = try await store.begin(
            id: input, user: "final transcript", request: [], expecting: read.token, model: "fixture")
    }
    let committed = try #require(try await db.assistantMessages.messages(dialog: read.current.id).first)
    #expect(committed.body == "final transcript" && committed.state == "completed")
    #expect(try await store.readCurrent().current.turns.first?.messageID == nil)
    #expect(await store.lastCheckpointError != nil)
    try await store.checkpoint()
    #expect(try await store.readCurrent().current.turns.first?.messageID == committed.id)
    #expect(try await db.assistantMessages.messages(dialog: read.current.id).map(\.id) == [committed.id])
    #expect(try await db.assistantConversations.dialog(read.current.id).count == 1)
    #expect(await store.lastCheckpointError == nil)
}

@Test func sqliteReservedIdentityRetryAndCrashRecoveryKeepTheSameID() async throws {
    let db = try SQLiteRepositories.temporary()
    let dialog = try await db.assistantConversations.current()
    let identity = AssistantMessageIdentity(
        clientID: "response", inputID: "input", role: "assistant", kind: "response", order: 1, date: Date())
    let id = try await db.assistantMessages.beginMessage(dialog: dialog.id, identity: identity)
    #expect(try await db.assistantMessages.beginMessage(dialog: dialog.id, identity: identity) == id)
    #expect(try await db.assistantMessages.messages(dialog: dialog.id).count == 1)
    try db.recoverInFlight()
    let interrupted = try #require(try await db.assistantMessages.messages(dialog: dialog.id).first)
    #expect(interrupted.id == id && interrupted.state == "interrupted")
    #expect(interrupted.body.isEmpty && !interrupted.detail.isEmpty)
}

@Test func sqliteCrashClosesTaskAndRetainsSourcesWithoutInventingSummary() async throws {
    let db = try SQLiteRepositories.temporary()
    let dialog = try await db.assistantConversations.current()
    let task = try await db.assistantTasks.createTask(dialog: dialog.id, agent: "assistant", goal: "unfinished goal")
    let identity = AssistantMessageIdentity(
        clientID: "response", inputID: "input", role: "assistant", kind: "response", order: 1, date: Date(),
        taskID: task)
    let id = try await db.assistantMessages.beginMessage(dialog: dialog.id, identity: identity)
    try db.recoverInFlight()
    #expect(try await db.assistantTasks.compressionData(dialog: dialog.id).isEmpty)
    #expect(try await db.assistantTasks.taskSources(task).map(\.requestID) == ["response"])
    #expect(try await db.assistantMessages.messages(dialog: dialog.id).first?.id == id)
    try db.recoverInFlight()
    #expect(try await db.assistantTasks.compressionData(dialog: dialog.id).isEmpty)
}

@Test func sqliteORMCompletionPreservesIdentityOrderAndDate() async throws {
    let db = try SQLiteRepositories.temporary()
    let dialog = try await db.assistantConversations.current()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let id = try db.assistantMessages.beginMessage(
        dialog: dialog.id,
        identity: .init(
            clientID: "response", inputID: "input", role: "assistant", kind: "response", order: 7, date: date))
    let final = AssistantMessageRecord(
        clientID: "response", inputID: "input", role: "assistant", kind: "response",
        order: 999, date: date.addingTimeInterval(99), body: "finished", state: "completed", detail: Data("{}".utf8),
        id: id)
    try db.assistantMessages.save(dialog: dialog.id, revision: 1, messages: [final], summaries: [])
    let row = try #require(try await db.assistantMessages.messages(dialog: dialog.id).first)
    #expect(row.id == id && row.order == 7 && row.date == date)
    #expect(row.body == "finished" && row.state == "completed")
}

@Test func sqliteEmptyUserIdentityDoesNotPoisonContextAndSourcelessTaskHasNoCompression() async throws {
    let db = try SQLiteRepositories.temporary()
    let dialog = try await db.assistantConversations.current()
    _ = try await db.assistantTasks.createTask(dialog: dialog.id, agent: "assistant", goal: "never activated")
    let id = try db.assistantMessages.beginMessage(
        dialog: dialog.id,
        identity: .init(
            clientID: "lost-input", inputID: "lost-input", role: "user", kind: "input", order: 1, date: Date()))
    try db.recoverInFlight()
    let records = try AssistantRecordStore(
        repository: db.assistantMessages, tasks: db.assistantTasks, conversations: db.assistantConversations,
        logs: db.logs)
    #expect(try await records.window(dialog.id).turns.isEmpty)
    let page = try await records.page(dialog.id)
    #expect(page.turns.count == 1 && page.turns.first?.modelRequests?.first?.messageID == id)
    #expect(page.turns.first?.state == .interrupted)
    #expect(try await db.assistantTasks.compressionData(dialog: dialog.id).isEmpty)
}

import Actions
import Foundation
import StorageCore
import StorageDatabase
import StorageFiles
import StorageSQLite
import StorageTasks
import Testing

/// Real task identities are required before a workspace can be written.
func workspaceFixtureRepositories(url: URL? = nil, count: Int = 1) async throws -> SQLiteRepositories {
    let records = try url.map { try SQLiteRepositories(url: $0) } ?? SQLiteRepositories.temporary()
    for number in 1...count {
        if (try? await records.writerExecutions.task("task_\(number)", agent: "writer")) != nil { continue }
        let task = try await records.seedDelegation(
            taskID: nil, goal: "Fixture \(number)", input: "Create", sourceDialog: nil, agent: "writer")
        try await records.endSeedDelegation(task.delegateID, status: "completed")
    }
    return records
}

@Test func workspaceSearchFiltersAndPagesMetadataInSQLite() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let records = try await workspaceFixtureRepositories(count: 16)
    let workspace = ArtifactWorkspace(disk: try DiskFileStore(root: root), catalog: records.workspaces)
    let draft = try ArtifactDraft(files: ["index.html": "private source"])
    for number in 1...15 {
        let id = try #require(WorkspaceID(agent: "writer", taskID: "task_\(number)"))
        let title = number == 14 ? "Unrelated" : "神经流程图 \(number)"
        _ = try await workspace.publish(id: id, expecting: nil, title: title, draft: draft)
    }
    let first = try await records.workspaces.search("流程图", before: nil)
    #expect(first.matches.count == 12 && first.matches.allSatisfy { $0.title.contains("流程图") && $0.files.isEmpty })
    let cursor = try #require(first.nextBefore)
    let next = try await records.workspaces.search("流程图", before: cursor)
    #expect(next.matches.map(\.id.taskID) == ["task_2", "task_1"] && next.nextBefore == nil)
    let exact = try await records.workspaces.search("writer/task_14", before: nil)
    #expect(exact.matches.map(\.title) == ["Unrelated"])
    #expect(try await records.workspaces.search("Fixture 14", before: nil).matches.map(\.title) == ["Unrelated"])
    #expect(try await records.workspaces.search("private source", before: nil).matches.isEmpty)
    #expect(try await records.workspaces.search("%", before: nil).matches.isEmpty)
    #expect(try await records.workspaces.search("", before: nil).matches.count == 12)
    try await records.shutdown()
}

@Test func workspaceUsesCurrentFilesWithoutVersionHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let records = try await workspaceFixtureRepositories()
    let workspace = ArtifactWorkspace(disk: try DiskFileStore(root: root), catalog: records.workspaces)
    let id = try #require(WorkspaceID(agent: "writer", taskID: "task_1"))

    let first = try await workspace.publish(
        id: id, expecting: nil, title: "Graph",
        draft: ArtifactDraft(files: ["index.html": "<h1>First</h1>", "empty.css": ""]))

    let url = try await workspace.entry(first)
    #expect(url.path.hasSuffix("writer/task_1/index.html"))
    let next = try ArtifactDraft(files: ["index.html": "<h1>Second</h1>", "assets/style.css": "h1{color:red}"])
    try await workspace.checkpoint(
        .init(
            workspaceID: id, baseRevision: first.revision, title: "Graph", entry: "index.html", draft: next,
            interrupted: true))
    #expect(try String(contentsOf: url, encoding: .utf8) == "<h1>Second</h1>")
    #expect(try await workspace.project(id).files == next.files)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("writer/task_1/empty.css").path))
    let second = try await workspace.publish(id: id, expecting: first.revision, title: "Graph", draft: next)
    await #expect(throws: ArtifactWorkspaceError.conflict) {
        try await workspace.publish(id: id, expecting: first.revision, title: "Stale", draft: next)
    }
    let reopened = ArtifactWorkspace(disk: try DiskFileStore(root: root), catalog: records.workspaces)
    #expect(try await reopened.project(id).revision == second.revision)
    #expect(try await reopened.checkpoint(for: id) == nil)
    try await reopened.delete(id)
    #expect(try await reopened.list().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    try await records.shutdown()
}

@Test func workspaceRetainsDeletionIdentityWhenConfinedCleanupFails() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    defer { try? files.removeItem(at: root) }
    let records = try await workspaceFixtureRepositories()
    let workspace = ArtifactWorkspace(disk: try DiskFileStore(root: root), catalog: records.workspaces)
    let id = try #require(WorkspaceID(agent: "writer", taskID: "task_1"))
    _ = try await workspace.publish(
        id: id, expecting: nil, title: "Delete", draft: ArtifactDraft(files: ["index.html": "safe"]))
    let original = root.appendingPathComponent(id.rawValue)
    let held = root.appendingPathComponent("held")
    try files.moveItem(at: original, to: held)
    try files.createSymbolicLink(at: original, withDestinationURL: held)
    await #expect(throws: FileStorageError.invalidPath) { try await workspace.delete(id) }
    #expect(try await records.workspaces.directory().filter(\.deleting).map(\.id) == [id])
    try files.removeItem(at: original)
    try files.moveItem(at: held, to: original)
    try await workspace.delete(id)
    #expect(try await records.workspaces.directory().isEmpty)
    try await records.shutdown()
}

@Test func workspaceLargeFilesAndDraftsSurviveReopenOnDisk() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("records.sqlite")
    let records = try await workspaceFixtureRepositories(url: url, count: 3)
    let disk = try DiskFileStore(root: root.appendingPathComponent("files"))
    let workspace = ArtifactWorkspace(disk: disk, catalog: records.workspaces)
    let source = String(repeating: "<p>中文🙂</p>", count: 240000)
    for number in 1...3 {
        let id = try #require(WorkspaceID(agent: "writer", taskID: "task_\(number)"))
        _ = try await workspace.publish(
            id: id, expecting: nil, title: "Large", draft: ArtifactDraft(files: ["index.html": source, "empty.js": ""]))
    }
    let id = try #require(WorkspaceID(agent: "writer", taskID: "task_1"))
    let base = try await workspace.project(id)
    try await workspace.checkpoint(
        .init(
            workspaceID: id, baseRevision: base.revision, title: "Draft", entry: "index.html",
            draft: ArtifactDraft(files: ["index.html": source + "changed"]), interrupted: true))
    try await records.shutdown()
    let reopened = try SQLiteRepositories(url: url)
    let restored = ArtifactWorkspace(disk: disk, catalog: reopened.workspaces)
    #expect(try await restored.project(id).files["index.html"] == source + "changed")
    #expect(try await restored.checkpoint(for: id)?.interrupted == true)
    #expect(try await restored.list().count == 3)
    try await reopened.shutdown()
}

@Test func workspaceConcurrentWritersUseLeaseAndCurrentToken() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let records = try await workspaceFixtureRepositories()
    let disk = try DiskFileStore(root: root)
    let first = ArtifactWorkspace(disk: disk, catalog: records.workspaces)
    let second = ArtifactWorkspace(disk: disk, catalog: records.workspaces)
    let id = try #require(WorkspaceID(agent: "writer", taskID: "task_1"))
    let base = try await first.publish(
        id: id, expecting: nil, title: "Base", draft: ArtifactDraft(files: ["index.html": "base"]))
    let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        for workspace in [first, second] {
            group.addTask {
                do {
                    _ = try await workspace.publish(
                        id: id, expecting: base.revision, title: "Next",
                        draft: ArtifactDraft(files: ["index.html": "next"]))
                    return true
                } catch { return false }
            }
        }
        var count = 0
        for await success in group { if success { count += 1 } }
        return count
    }
    #expect(successes == 1)
    #expect(try await first.project(id).files["index.html"] == "next")
    try await records.shutdown()
}

extension AgentMessageRepository {
    func seedAgentRequest(
        id: String, requester: String, executor: String, goal: String, input: String, sourceDialog: String?
    ) async throws {
        try await enqueueAgentMessage(
            .init(
                id: id, sender: requester, receiver: executor, contract: "task.request",
                payload: JSONSerialization.data(withJSONObject: ["description": goal, "input": input]),
                correlationID: id, senderContext: sourceDialog, dedupeKey: id))
    }

}

extension SQLiteRepositories {
    func seedDelegation(taskID: String?, goal: String, input: String, sourceDialog: String?, agent: String) async throws
        -> SeededWriterWorkspace
    {
        let delegate = UUID().uuidString
        try await agentMessages.seedAgentRequest(
            id: delegate, requester: "assistant", executor: agent, goal: goal, input: input, sourceDialog: sourceDialog)
        _ = try await writerExecutions.beginRequest(
            delegateID: delegate, taskID: nil, goal: goal, input: input, sourceDialog: sourceDialog, agent: agent)
        let workspace: WriterWorkspaceRecord
        if let taskID {
            workspace = try await writerExecutions.selectWorkspace(requestID: delegate, taskID: taskID)
        } else {
            workspace = try await writerExecutions.createWorkspace(requestID: delegate, title: goal)
            try await writerExecutions.prepareWorkspace(
                workspace.workspaceID, taskID: workspace.id, delegateID: delegate, agent: agent, ready: false)
        }
        return SeededWriterWorkspace(workspace: workspace, delegateID: delegate)
    }
    func endSeedDelegation(_ id: String, status: String, failure: String? = nil) async throws {
        let row = try await writerExecutions.request(id, agent: "writer")

        try await writerExecutions.completeRequest(
            .init(delegateID: id, agent: "writer", eventID: UUID().uuidString, data: Data("{}".utf8)), status: status,
            failure: failure)

        try await writerExecutions.finishTaskNotification(
            id, agent: "writer", retirement: true, completed: true, failure: nil)

        _ = row
    }
}

@Test func agentOwnedTaskNumbersAndDelegationUUIDsAreIndependentAndDurable() async throws {
    let records = try SQLiteRepositories.temporary()
    let source = try await records.assistantConversations.current()
    let foreground = try await records.assistantTasks.createTask(dialog: source.id, agent: "assistant", goal: "Talk")
    #expect(foreground == "task_1")
    let id = UUID().uuidString
    try await records.agentMessages.seedAgentRequest(
        id: id, requester: "assistant", executor: "writer", goal: "Diagram", input: "Draw", sourceDialog: source.id)
    let first = try await records.writerExecutions.beginRequest(
        delegateID: id, taskID: nil, goal: "Diagram", input: "Draw", sourceDialog: nil, agent: "writer")
    let repeated = try await records.writerExecutions.beginRequest(
        delegateID: id, taskID: nil, goal: "Diagram", input: "Draw", sourceDialog: nil, agent: "writer")
    #expect(first.id == id && first.messageID == repeated.messageID && first.taskID.isEmpty)
    #expect(try await records.writerExecutions.tasks(agent: "writer", before: nil, limit: 20).isEmpty)
    let workspace = try await records.writerExecutions.createWorkspace(requestID: id, title: "Diagram")
    try await records.writerExecutions.prepareWorkspace(
        workspace.workspaceID, taskID: workspace.id, delegateID: id, agent: "writer")
    #expect(workspace.id == "task_1")
    try await records.endSeedDelegation(id, status: "completed")
    let next = UUID().uuidString
    try await records.agentMessages.seedAgentRequest(
        id: next, requester: "assistant", executor: "writer", goal: "Edit", input: "Blue", sourceDialog: nil)
    let second = try await records.writerExecutions.beginRequest(
        delegateID: next, taskID: nil, goal: "Edit", input: "Blue", sourceDialog: nil, agent: "writer")
    #expect(second.messageID > first.messageID && second.taskID.isEmpty)
    _ = try await records.writerExecutions.selectWorkspace(requestID: next, taskID: workspace.id)
    #expect(try await records.writerExecutions.request(next, agent: "writer").taskID == workspace.id)
    await #expect(throws: RecordStorageError.conflict) {
        try await records.writerExecutions.updateRequestPhase(requestID: id, phase: "running")
    }
    try await records.endSeedDelegation(next, status: "completed")
    #expect(try await records.writerExecutions.delegationCount() == 2)
    try await records.shutdown()
}

@Test func workspaceIdentityRejectsTraversalAndMaterializesAgentTaskDirectory() async throws {
    for raw in [
        "../task_1", "writer/../task_1", "writer/task_01", "writer/task_0", "/writer/task_1", "writer/task_1/extra",
    ] {
        #expect(WorkspaceID(rawValue: raw) == nil)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let catalog = try await workspaceFixtureRepositories()
    let workspace = ArtifactWorkspace(disk: try DiskFileStore(root: root), catalog: catalog.workspaces)
    let identity = try #require(WorkspaceID(agent: "writer", taskID: "task_1"))
    let published = try await workspace.publish(
        id: identity, expecting: nil, title: "Demo", draft: ArtifactDraft(files: ["index.html": "<h1>Demo</h1>"]))
    let url = try await workspace.entry(published)
    #expect(url.path.contains("/writer/task_1/"))
    #expect(try String(contentsOf: url, encoding: .utf8).contains("Demo"))
    try await catalog.shutdown()
}

@Test func writerWorkspaceSelectionRejectsInvalidTargetAndCancelledRequestAtomically() async throws {
    let records = try SQLiteRepositories.temporary()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = ArtifactWorkspace(disk: try DiskFileStore(root: root), catalog: records.workspaces)
    let old = try await records.seedDelegation(
        taskID: nil, goal: "Existing", input: "seed", sourceDialog: nil, agent: "writer")
    let target = try #require(WorkspaceID(rawValue: old.workspaceID))
    let project = try await workspace.publish(
        id: target, expecting: nil, title: "Existing", draft: ArtifactDraft(files: ["index.html": "KEEP"]))
    try await records.endSeedDelegation(old.delegateID, status: "completed")
    let current = try await records.seedDelegation(
        taskID: nil, goal: "Locate", input: "query", sourceDialog: nil, agent: "writer")
    await #expect(throws: (any Error).self) {
        try await records.writerExecutions.selectWorkspace(requestID: current.delegateID, taskID: "task_999999")
    }
    #expect(try await records.writerExecutions.request(current.delegateID, agent: "writer").taskID == current.id)
    let lease = UUID()
    try await records.workspaces.claim(target, expecting: project.revision, lease: lease)
    await #expect(throws: (any Error).self) {
        try await records.writerExecutions.selectWorkspace(requestID: current.delegateID, taskID: old.id)
    }
    #expect(try await records.writerExecutions.request(current.delegateID, agent: "writer").taskID == current.id)
    try await records.workspaces.release(target, lease: lease)
    try await records.writerExecutions.updateRequestPhase(requestID: current.delegateID, phase: "cancelling")
    await #expect(throws: (any Error).self) {
        try await records.writerExecutions.selectWorkspace(requestID: current.delegateID, taskID: old.id)
    }
    #expect(try await records.writerExecutions.request(current.delegateID, agent: "writer").taskID == current.id)
    #expect(try await records.writerExecutions.request(old.delegateID, agent: "writer").taskID == old.id)
    #expect(try await workspace.project(target).files == ["index.html": "KEEP"])
    try await records.shutdown()
}

/// Test setup explicitly creates both independent entities; production admission creates only a message.
struct SeededWriterWorkspace {
    let workspace: WriterWorkspaceRecord
    let delegateID: String
    var id: String { workspace.id }
    var dialogID: String { workspace.dialogID }
    var workspaceID: String { workspace.workspaceID }
    var workspaceReady: Bool { workspace.workspaceReady }
    var goal: String { workspace.goal }
    var updatedAt: Date { workspace.updatedAt }
}

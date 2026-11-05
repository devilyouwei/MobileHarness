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
        if (try? await records.tasks.delegatedTask("task_\(number)", agent: "writer")) != nil { continue }
        let task = try await records.tasks.seedDelegation(
            taskID: nil, goal: "Fixture \(number)", input: "Create", sourceDialog: nil, agent: "writer")
        try await records.tasks.endSeedDelegation(task.delegateID, status: "completed")
    }
    return records
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

extension TaskRepository {
    func seedDelegation(taskID: String?, goal: String, input: String, sourceDialog: String?, agent: String) async throws
        -> DelegatedTaskRecord
    {
        let delegate = UUID().uuidString
        try await createDelegation(
            id: delegate, requester: "assistant", executor: agent, goal: goal, input: input, sourceDialog: sourceDialog)
        return try await beginDelegation(
            delegateID: delegate, taskID: taskID, goal: goal, input: input, sourceDialog: sourceDialog, agent: agent)
    }
    func endSeedDelegation(_ id: String, status: String, failure: String? = nil) async throws {
        let row = try await delegation(id, agent: "writer")
        try await completeDelegation(
            .init(delegateID: id, agent: "writer", eventID: UUID().uuidString, data: Data()), status: status,
            failure: failure)
        _ = row
    }
}

@Test func agentOwnedTaskNumbersAndDelegationUUIDsAreIndependentAndDurable() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("records.sqlite")
    let records = try SQLiteRepositories(url: url)
    let source = try await records.chat.current(agent: "assistant")
    let foreground = try await records.tasks.createTask(dialog: source.id, agent: "assistant", goal: "Talk")
    #expect(foreground == "task_1")
    let id = UUID().uuidString
    try await records.tasks.createDelegation(
        id: id, requester: "assistant", executor: "writer", goal: "Diagram", input: "Draw", sourceDialog: source.id)
    #expect(try await records.tasks.delegatedTasks(agent: "writer", before: nil, limit: 20).isEmpty)
    await #expect(throws: RecordStorageError.missingRecord) {
        try await records.tasks.beginDelegation(
            delegateID: id, taskID: nil, goal: "Diagram", input: "Draw", sourceDialog: nil, agent: "other")
    }
    let task = try await records.tasks.beginDelegation(
        delegateID: id, taskID: nil, goal: "Diagram", input: "Draw", sourceDialog: nil, agent: "writer")
    #expect(task.id == "task_1" && task.delegateID == id && task.workspaceID == "writer/task_1")
    let again = try await records.tasks.beginDelegation(
        delegateID: id, taskID: nil, goal: "Diagram", input: "Draw", sourceDialog: nil, agent: "writer")
    #expect(again.id == task.id && again.dialogID == task.dialogID)
    await #expect(throws: RecordStorageError.conflict) {
        try await records.tasks.createDelegation(
            id: id, requester: "assistant", executor: "writer", goal: "Changed", input: "Draw", sourceDialog: source.id)
    }
    let secondDelegate = UUID().uuidString
    try await records.tasks.createDelegation(
        id: secondDelegate, requester: "assistant", executor: "writer", goal: "Edit", input: "Blue",
        sourceDialog: source.id)
    await #expect(throws: RecordStorageError.conflict) {
        try await records.tasks.beginDelegation(
            delegateID: secondDelegate, taskID: task.id, goal: "Edit", input: "Blue", sourceDialog: nil, agent: "writer"
        )
    }
    try await records.tasks.endSeedDelegation(id, status: "completed")
    let resumed = try await records.tasks.beginDelegation(
        delegateID: secondDelegate, taskID: task.id, goal: "Edit", input: "Blue", sourceDialog: nil, agent: "writer")
    #expect(
        resumed.id == task.id && resumed.workspaceID == task.workspaceID && resumed.dialogID == task.dialogID
            && resumed.delegateID != id)
    await #expect(throws: RecordStorageError.conflict) {
        try await records.tasks.setDelegationPhase(taskID: task.id, delegateID: id, phase: "running", agent: "writer")
    }
    try await records.tasks.endSeedDelegation(secondDelegate, status: "completed")
    let other = try await records.tasks.seedDelegation(
        taskID: nil, goal: "Other", input: "Other", sourceDialog: nil, agent: "other")
    #expect(other.id == "task_1" && other.workspaceID == "other/task_1")
    let trace = try await records.chat.dialog(task.dialogID).traceID
    try await records.shutdown()
    let reopened = try SQLiteRepositories(url: url)
    #expect(try await reopened.chat.dialog(task.dialogID).traceID == trace)
    let next = try await reopened.tasks.seedDelegation(
        taskID: nil, goal: "New", input: "New", sourceDialog: nil, agent: "writer")
    #expect(next.id == "task_2" && UUID(uuidString: next.delegateID) != nil)
    try await reopened.shutdown()
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

import AgentCore
import CallRuntime
import Foundation
import FunctionContracts
import Gateway
@_spi(ModelManagement) import ModelKit
import ModelKitOpenAI
import StorageChat
import StorageCore
import StorageFiles
import StorageSQLite
import StorageTasks
import Testing
import UI
import WebKit

@testable import Actions
@testable import Agents

@Test(.enabled(if: ProcessInfo.processInfo.environment["MH_WRITER_RENDER_EVAL"] == "1"))
func writerEvaluationWebKitReloadsLocalResourcesAndChecksClick() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let renderer = await WriterEvaluationRenderer(root: root)
    let id = try #require(WorkspaceID(rawValue: "workspace_1"))
    let html =
        "<!doctype html><meta charset='utf-8'><button id='increment'>+</button><span id='count'>0</span><script src='app.js'></script>"
    _ = try await renderer.show(
        id, entry: "index.html", files: ["index.html": html, "app.js": "throw new Error('WRITER_TEST')"], preview: false
    )
    _ = try await renderer.show(
        id, entry: "index.html",
        files: [
            "index.html": html,
            "app.js":
                "document.getElementById('increment').onclick=()=>document.getElementById('count').textContent='1';",
        ], preview: false)
    let values = await renderer.renders
    let beforeJSON = try #require(values.first?["diagnostics"])
    let afterJSON = try #require(values.last?["diagnostics"])
    let before = try #require(JSONSerialization.jsonObject(with: Data(beforeJSON.utf8)) as? [String: Any])
    let after = try #require(JSONSerialization.jsonObject(with: Data(afterJSON.utf8)) as? [String: Any])
    #expect(!(before["errors"] as? [String] ?? []).isEmpty)
    #expect((after["errors"] as? [String] ?? []).isEmpty)
    #expect(after["counterBefore"] as? String == "0")
    #expect(after["counterAfter"] as? String == "1")
    await renderer.stop()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MH_WRITER_RENDER_EVAL"] == "1"))
func writerPromptHostUsesProductionWindowAndRenderingOwners() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let host = try await WriterPromptHost(root: root, event: nil)
    let id = try #require(WorkspaceID(rawValue: "workspace_1"))
    _ = try await host.present(
        id, title: "Synthetic preflight", entry: "index.html",
        files: ["index.html": "<!doctype html><meta charset=utf-8><h1>Production renderer</h1>"], preview: false)
    #expect(await host.windows.windows.count == 1)
    let first = try await #require(host.windows.windows.first?.id)
    try await host.close(first)
    #expect(await host.windows.windows.isEmpty)
    let blocked = try await host.present(
        id, title: "closed", entry: "index.html", files: ["index.html": "<h1>Do not reopen</h1>"], preview: true)
    #expect(blocked.contains("unavailable") && blocked.contains("closed"))
    try await host.presentation.prepare(id: id, deleting: false)
    _ = try await host.present(
        id, title: "reopened", entry: "index.html", files: ["index.html": "<h1>Reopened</h1>"], preview: false)
    #expect(await host.windows.windows.count == 1)
    await host.stop()
    try? FileManager.default.removeItem(at: root)
}

/// A single delegate verifies admission, real model communication, publication and completion.
@Test(.actionCatalog, .enabled(if: ProcessInfo.processInfo.environment["MH_WRITER_SMOKE"] == "1"))
func writerSingleDelegatePublishesAndCompletes() async throws {
    let env = ProcessInfo.processInfo.environment
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var configuration = [
        "MH_WRITER_EVAL_API_URL": try #require(env["MH_SMOKE_API_URL"]),
        "MH_WRITER_EVAL_API_KEY": try #require(env["MH_SMOKE_API_KEY"]),
        "MH_WRITER_EVAL_MODEL": try #require(env["MH_SMOKE_MODEL"]),
        "MH_WRITER_EVAL_SECONDS": "90", "MH_WRITER_EVAL_THINKING": "minimum",
    ]
    configuration["MH_WRITER_EVAL_ROOT"] = root.path
    let scenario = WriterPromptCase(
        id: "writer-smoke", goal: "Create a short greeting in note.txt, render it and finish the assignment.",
        entry: "note.txt")
    let result = try await writerPromptCase(scenario, env: configuration, root: root, requestLimit: 8)
    #expect(result["status"] as? String == "completed")
    #expect(result["passed"] as? Bool == true)
}

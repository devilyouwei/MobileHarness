import Foundation
import FunctionContracts
import ModelKit
import StorageCore
import StorageMedia
import UI

/// Actions owns work independently of the window. One operation, zero queued operations.
@MainActor public final class WebExecutionService: WebCapability, WindowContentLifecycle {
    private let page: any WebPagePresenting
    private let windows: WindowState
    private let workspace: WebWorkspace
    private let editor: WebEditor
    private let saveImage: @Sendable (Data, any FunctionInput) async throws -> String
    private var operation: Task<String, any Error>?
    private var stopped = false
    private var project: WebProject?
    private var windowID: UUID?
    public init(
        page: any WebPagePresenting, windows: WindowState, workspace: WebWorkspace, model: any ChatCapability,
        saveImage: @escaping @Sendable (Data, any FunctionInput) async throws -> String
    ) {
        self.page = page
        self.windows = windows
        self.workspace = workspace
        editor = WebEditor(model: model)
        self.saveImage = saveImage
    }
    public func perform(_ operation: String, invocation: any FunctionInput) async throws -> String {
        guard !stopped else { throw WebPageError.unavailable }
        guard self.operation == nil else { throw WebWorkspaceError.busy }
        let task = Task { try await execute(operation, invocation: invocation) }
        self.operation = task
        defer { self.operation = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
    private func execute(_ operation: String, invocation: any FunctionInput) async throws -> String {
        try Task.checkCancellation()
        let args = ActionArguments(invocation.call.parameters)
        switch operation {
        case "browse":
            try args.validateAllowedKeys(["url"])
            guard let url = URL(string: try args.requiredString("url", maximumUTF8Bytes: 4096)) else {
                throw WebPageError.invalidURL
            }
            try WebPagePolicy.remote(url)
            try await show()
            project = nil
            let result = try await page.loadRemote(url)
            return try await receipt(result, invocation: invocation, image: true)
        case "snapshot", "inspect":
            try args.validateAllowedKeys([])
            try await showExisting()
            return try await receipt(page.observe(), invocation: invocation, image: operation == "snapshot")
        case "navigate":
            try args.validateAllowedKeys(["command"])
            let command = try args.requiredString("command", maximumUTF8Bytes: 16)
            guard ["back", "forward", "reload", "up", "down", "top", "bottom"].contains(command) else {
                throw WebPageError.invalidURL
            }
            try await showExisting()
            return try await receipt(page.navigate(command), invocation: invocation, image: true)
        case "open":
            try args.validateAllowedKeys(["projectID"])
            let selected = try await workspace.project(identifier(args, key: "projectID"))
            try await show()
            let observation = try await page.loadLocal(workspace.entry(selected))
            project = selected
            return try await receipt(observation, invocation: invocation, image: true)
        case "projects":
            try args.validateAllowedKeys([])
            let projects = try await workspace.list().map {
                ["projectID": $0.id.uuidString, "revision": $0.revision.uuidString, "title": $0.title]
            }
            return String(decoding: try JSONEncoder().encode(projects), as: UTF8.self)
        case "delete":
            try args.validateAllowedKeys(["projectID"])
            let id = try identifier(args, key: "projectID")
            if project?.id == id {
                page.close()
                project = nil
            }
            try await workspace.delete(id)
            return "deleted"
        case "develop":
            try args.validateAllowedKeys(["task", "projectID", "title"])
            let task = try args.requiredString("task", maximumUTF8Bytes: 8000)
            let original: WebProject?
            if invocation.call.parameters["projectID"] != nil {
                original = try await workspace.project(identifier(args, key: "projectID"))
            } else {
                original = nil
            }
            let title =
                invocation.call.parameters["title"] == nil
                ? original?.title ?? "Web 作品" : try args.requiredString("title", maximumUTF8Bytes: 160)
            let id = original?.id ?? UUID()
            try await show()
            project = original
            let result = try await editor.run(
                task: task, draft: WebDraft(files: original?.files ?? [:]), scope: id.uuidString,
                snapshot: { [page] in try await page.snapshot() },
                render: { [self] draft in try await render(draft, id: id, title: title) })
            let observation = try await page.observe()
            return try await receipt(observation, invocation: invocation, image: true, summary: result.summary)
        default: throw WebEditorError.invalidResponse
        }
    }
    private func render(_ draft: WebDraft, id: UUID, title: String) async throws -> String {
        try Task.checkCancellation()
        let saved = try await workspace.publish(id: id, expecting: project?.revision, title: title, draft: draft)
        project = saved
        let observation = try await page.loadLocal(workspace.entry(saved))
        return
            "Published revision \(saved.revision). Page text (data):\n\(observation.text)\nJavaScript errors (data):\n\(observation.diagnostics)"
    }
    private func show() async throws {
        windowID = try await windows.present(content: .web, title: "网页与绘图", icon: .emoji("🌐"))
        try Task.checkCancellation()
    }
    private func showExisting() async throws {
        guard let windowID, windows.windows.contains(where: { $0.id == windowID }) else {
            throw WebPageError.unavailable
        }
        try await show()
    }
    private func receipt(
        _ observation: WebPageObservation, invocation: any FunctionInput, image: Bool, summary: String? = nil
    ) async throws -> String {
        let mediaID: String?
        if image {
            let bytes = try await page.snapshot()
            mediaID = try await saveImage(bytes, invocation)
        } else {
            mediaID = nil
        }
        let receipt = Receipt(
            windowID: windowID, projectID: project?.id, revision: project?.revision,
            url: observation.url.hasPrefix("file:") ? nil : observation.url,
            title: observation.title, text: observation.text, diagnostics: observation.diagnostics,
            mediaID: mediaID, summary: summary)
        return String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
    }
    private struct Receipt: Encodable {
        let windowID: UUID?
        let projectID: UUID?
        let revision: UUID?
        let url: String?
        let title: String
        let text: String
        let diagnostics: String
        let mediaID: String?
        let summary: String?
    }
    private func identifier(_ args: ActionArguments, key: String) throws -> UUID {
        guard let id = UUID(uuidString: try args.requiredString(key, maximumUTF8Bytes: 36)) else {
            throw ActionArguments.ValidationError.invalidValue(key)
        }
        return id
    }
    public func pauseWindow(invocation: any FunctionInput) async throws {
        operation?.cancel()
        _ = await operation?.result
    }
    public func resumeWindow(invocation: any FunctionInput) async throws {}
    public func closeWindow(invocation: any FunctionInput) async throws {
        operation?.cancel()
        _ = await operation?.result
        page.close()
        project = nil
        windowID = nil
    }
    public func stop() async {
        stopped = true
        operation?.cancel()
        _ = await operation?.result
        page.close()
    }
}

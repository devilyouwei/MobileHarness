import Foundation
import FunctionContracts
import StorageCore
import StorageMedia
import UI

/// Actions owns work independently of the window. One operation, zero queued operations.
@MainActor public final class WebExecutionService: WebCapability, WindowContentLifecycle {
    private let windows: WindowState
    private let createPage: @MainActor @Sendable (UUID, String?) throws -> any WebPagePresenting
    private let removePage: @MainActor @Sendable (UUID) -> Void
    private let pageForWindow: @MainActor @Sendable (UUID) -> (any WebPagePresenting)?
    private var operationWindowID: UUID?
    private let saveImage: @Sendable (Data, any FunctionInput) async throws -> String
    private var operation: Task<String, any Error>?
    private var stopped = false
    public init(
        windows: WindowState,
        pageForWindow: @escaping @MainActor @Sendable (UUID) -> (any WebPagePresenting)?,
        createPage: @escaping @MainActor @Sendable (UUID, String?) throws -> any WebPagePresenting,
        removePage: @escaping @MainActor @Sendable (UUID) -> Void,
        saveImage: @escaping @Sendable (Data, any FunctionInput) async throws -> String
    ) {
        self.windows = windows
        self.pageForWindow = pageForWindow
        self.createPage = createPage
        self.removePage = removePage
        self.saveImage = saveImage
    }
    public func perform(_ operation: String, invocation: any FunctionInput) async throws -> String {
        guard !stopped else { throw WebPageError.unavailable }
        guard self.operation == nil else { throw WebPageError.busy }
        let task = Task { try await execute(operation, invocation: invocation) }
        self.operation = task
        defer {
            self.operation = nil
            operationWindowID = nil
        }
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
            try args.validateAllowedKeys(["url", "windowID"])
            guard let url = URL(string: try args.requiredString("url", maximumUTF8Bytes: 4096)) else {
                throw WebPageError.invalidURL
            }
            try WebPagePolicy.remote(url)
            let id = try await browseWindow(invocation.call.parameters["windowID"])
            let page = try createPage(id, windows.reference(for: id))
            let result = try await page.loadRemote(url)
            let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
            windows.setPresentation(id, title: title.isEmpty ? (url.host ?? "网页") : String(title.prefix(80)))
            return try await receipt(
                result, page: page, window: id, invocation: invocation, image: true, allowsHiddenImage: true)

        case "snapshot", "inspect":
            try args.validateAllowedKeys(["windowID"])
            let (selected, id) = try await target(invocation.call.parameters["windowID"])
            if operation == "snapshot", try windows.find(id).mode == .minimized { throw WebPageError.notVisible }
            let observation = try await selected.observe()
            return try await receipt(
                observation, page: selected, window: id, invocation: invocation, image: operation == "snapshot")
        case "navigate":
            try args.validateAllowedKeys(["command", "windowID"])
            let command = try args.requiredString("command", maximumUTF8Bytes: 16)
            guard ["back", "forward", "reload", "up", "down", "top", "bottom"].contains(command) else {
                throw WebPageError.invalidURL
            }
            let (selected, id) = try await target(invocation.call.parameters["windowID"])
            guard try windows.find(id).mode != .minimized else { throw WebPageError.notVisible }
            let observation = try await selected.navigate(command)
            return try await receipt(observation, page: selected, window: id, invocation: invocation, image: true)
        default: throw ActionExecutionError.invalidInvocation
        }
    }
    private func target(_ reference: String?) async throws -> (any WebPagePresenting, UUID) {
        let id: UUID
        if let reference {
            id = try windows.resolve(reference: reference)
        } else {
            guard
                let recent = windows.windows.last(where: {
                    $0.content == WindowContent.web.rawValue && $0.phase == .settled
                })
            else { throw WebPageError.unavailable }
            id = recent.id
            operationWindowID = id
            if recent.mode == .minimized { try await windows.change(id, command: .restore) }
            try windows.focus(id)
        }
        let item = try windows.find(id)
        guard item.phase == .settled,
            [WindowContent.web.rawValue, WindowContent.artifact.rawValue].contains(item.content),
            let page = pageForWindow(id)
        else { throw WebPageError.unavailable }
        operationWindowID = id
        return (page, id)
    }
    private func browseWindow(_ reference: String?) async throws -> UUID {
        if let reference {
            let id = try windows.resolve(reference: reference)
            let item = try windows.find(id)
            guard item.content == WindowContent.web.rawValue, item.phase == .settled else {
                throw WebPageError.unavailable
            }
            operationWindowID = id
            if item.mode == .minimized { try await windows.change(id, command: .restore) }
            try windows.focus(id)
            return id
        }
        let id = UUID()
        operationWindowID = id
        _ = try await windows.present(content: .web, title: "网页", icon: .emoji("🌐"), windowID: id)
        try Task.checkCancellation()
        return id
    }
    private func receipt(
        _ observation: WebPageObservation, page: any WebPagePresenting, window: UUID?,
        invocation: any FunctionInput, image: Bool, allowsHiddenImage: Bool = false
    ) async throws -> String {
        let mediaID: String?
        if image {
            do {
                let bytes = try await page.snapshot()
                mediaID = try await saveImage(bytes, invocation)
            } catch WebPageError.notVisible where allowsHiddenImage {
                mediaID = nil
            }
        } else {
            mediaID = nil
        }
        let receipt = Receipt(
            windowID: window.flatMap { windows.reference(for: $0) },
            url: observation.url.hasPrefix("file:") ? nil : observation.url,
            title: observation.title, text: observation.text, diagnostics: observation.diagnostics,
            mediaID: mediaID)
        return String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
    }
    private struct Receipt: Encodable {
        let windowID: String?
        let url: String?
        let title: String
        let text: String
        let diagnostics: String
        let mediaID: String?
    }
    public func pauseWindow(invocation: any FunctionInput) async throws {
        let id = try lifecycleWindow(invocation)
        await cancelOperation(in: id)
    }
    public func resumeWindow(invocation: any FunctionInput) async throws {}
    public func closeWindow(invocation: any FunctionInput) async throws {
        let id = try lifecycleWindow(invocation)
        await cancelOperation(in: id)
        try Task.checkCancellation()
        removePage(id)
    }
    private func lifecycleWindow(_ invocation: any FunctionInput) throws -> UUID {
        guard let reference = invocation.call.parameters["windowID"] else { throw WindowError.missing }
        return try windows.resolve(reference: reference)
    }
    private func cancelOperation(in id: UUID) async {
        guard operationWindowID == id else { return }
        operation?.cancel()
        _ = await operation?.result
    }
    public func stop() async {
        stopped = true
        operation?.cancel()
        _ = await operation?.result
        for window in windows.windows where window.content == WindowContent.web.rawValue {
            removePage(window.id)
        }
    }
}

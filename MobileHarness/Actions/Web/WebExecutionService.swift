import Foundation
import FunctionContracts
import StorageCore
import StorageMedia
import UI

/// Actions owns work independently of the window. One operation, zero queued operations.
@MainActor public final class WebExecutionService: WebCapability, WindowContentLifecycle {
    private let page: any WebPagePresenting
    private let windows: WindowState
    private let pageForWindow: @MainActor @Sendable (UUID) -> (any WebPagePresenting)?
    private var operationWindowID: UUID?
    private let saveImage: @Sendable (Data, any FunctionInput) async throws -> String
    private var operation: Task<String, any Error>?
    private var stopped = false
    private var windowID: UUID?
    public init(
        page: any WebPagePresenting, windows: WindowState,
        pageForWindow: @escaping @MainActor @Sendable (UUID) -> (any WebPagePresenting)? = { _ in nil },
        saveImage: @escaping @Sendable (Data, any FunctionInput) async throws -> String
    ) {
        self.page = page
        self.pageForWindow = pageForWindow
        self.windows = windows
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
            try args.validateAllowedKeys(["url"])
            guard let url = URL(string: try args.requiredString("url", maximumUTF8Bytes: 4096)) else {
                throw WebPageError.invalidURL
            }
            try WebPagePolicy.remote(url)
            try await show()
            operationWindowID = windowID
            let result = try await page.loadRemote(url)
            return try await receipt(result, page: page, window: windowID, invocation: invocation, image: true)
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
    private func target(_ raw: String?) async throws -> (any WebPagePresenting, UUID) {
        if let raw {
            guard let id = UUID(uuidString: raw) else { throw ActionExecutionError.invalidInvocation }
            let window = try windows.find(id)
            guard window.phase != .closing else { throw WebPageError.unavailable }
            let selected: any WebPagePresenting
            if window.content == WindowContent.web.rawValue {
                selected = page
            } else {
                guard let existing = pageForWindow(id) else { throw WebPageError.unavailable }
                selected = existing
            }
            operationWindowID = id
            return (selected, id)
        }
        try await showExisting()
        guard let id = windowID else { throw WebPageError.unavailable }
        operationWindowID = id
        return (page, id)
    }
    private func show() async throws {
        windowID = try await windows.present(content: .web, title: "网页", icon: .emoji("🌐"))
        try Task.checkCancellation()
    }
    private func showExisting() async throws {
        guard let windowID, windows.windows.contains(where: { $0.id == windowID }) else {
            throw WebPageError.unavailable
        }
        try await show()
    }
    private func receipt(
        _ observation: WebPageObservation, page: any WebPagePresenting, window: UUID?,
        invocation: any FunctionInput, image: Bool
    ) async throws -> String {
        let mediaID: String?
        if image {
            let bytes = try await page.snapshot()
            mediaID = try await saveImage(bytes, invocation)
        } else {
            mediaID = nil
        }
        let receipt = Receipt(
            windowID: window,
            url: observation.url.hasPrefix("file:") ? nil : observation.url,
            title: observation.title, text: observation.text, diagnostics: observation.diagnostics,
            mediaID: mediaID)
        return String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
    }
    private struct Receipt: Encodable {
        let windowID: UUID?
        let url: String?
        let title: String
        let text: String
        let diagnostics: String
        let mediaID: String?
    }
    public func pauseWindow(invocation: any FunctionInput) async throws {
        if operationWindowID == windowID {
            operation?.cancel()
            _ = await operation?.result
        }
    }
    public func resumeWindow(invocation: any FunctionInput) async throws {}
    public func closeWindow(invocation: any FunctionInput) async throws {
        if operationWindowID == windowID {
            operation?.cancel()
            _ = await operation?.result
        }
        page.close()
        windowID = nil
    }
    public func stop() async {
        stopped = true
        operation?.cancel()
        _ = await operation?.result
        page.close()
    }
}

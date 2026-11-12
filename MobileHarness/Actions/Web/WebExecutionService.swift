import Foundation
import FunctionContracts
import PlatformKit
import UI

public struct WebScreenshotImage: Sendable {
    public let data: Data
    public let width: Int
    public let height: Int
    public init(data: Data, width: Int, height: Int) {
        self.data = data
        self.width = width
        self.height = height
    }
    public static func prepare(_ data: Data) async throws -> Self {
        let jpeg = try await NativeImageCompression.jpeg(
            from: data,
            limits: .init(maximumDimension: 1568, maximumPixels: 1_048_576, maximumBytes: 1_048_576, quality: 0.82))
        let info = try await NativeAlbumImage.inspect(jpeg)
        return .init(data: jpeg, width: info.width, height: info.height)
    }
}

/// Actions owns work independently of the window. One operation, zero queued operations.
@MainActor public final class WebExecutionService: WebCapability, WindowContentLifecycle {
    private let windows: WindowState
    private let createPage: @MainActor @Sendable (UUID, String?) throws -> any WebPagePresenting
    private let removePage: @MainActor @Sendable (UUID) -> Void
    private let pageForWindow: @MainActor @Sendable (UUID) -> (any WebPagePresenting)?
    private var operationWindowID: UUID?
    private let prepareImage: @Sendable (Data) async throws -> WebScreenshotImage
    private struct Screenshot {
        let window: UUID
        let page: ObjectIdentifier
        let identity: String
        let scope: String
        let capturedAt: Date
        let image: ContextImage
    }
    private var current: Screenshot?
    private var revision: UInt64 = 0
    private var operation: Task<String, any Error>?
    private var stopped = false
    public init(
        windows: WindowState,
        pageForWindow: @escaping @MainActor @Sendable (UUID) -> (any WebPagePresenting)?,
        createPage: @escaping @MainActor @Sendable (UUID, String?) throws -> any WebPagePresenting,
        removePage: @escaping @MainActor @Sendable (UUID) -> Void,
        prepareImage: @escaping @Sendable (Data) async throws -> WebScreenshotImage
    ) {
        self.windows = windows
        self.pageForWindow = pageForWindow
        self.createPage = createPage
        self.removePage = removePage
        self.prepareImage = prepareImage
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
            invalidateScreenshot()
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
            if operation == "snapshot" { invalidateScreenshot() }
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
            invalidateScreenshot()
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
        let screenshotID: String?
        if image {
            do {
                guard let window, let identity = page.snapshotIdentity else { throw WebPageError.notVisible }
                let bytes = try await page.snapshot()
                let prepared = try await prepareImage(bytes)
                try Task.checkCancellation()
                guard !stopped, page.snapshotIdentity == identity,
                    pageForWindow(window) === page,
                    let item = try? windows.find(window), item.phase == .settled, item.mode != .minimized
                else { throw WebPageError.unavailable }
                guard !prepared.data.isEmpty, prepared.data.count <= 1_048_576,
                    (1...1568).contains(prepared.width), (1...1568).contains(prepared.height),
                    prepared.width * prepared.height <= 1_048_576
                else { throw WebPageError.snapshotFailed }
                let id = "web_snapshot_" + UUID().uuidString
                let attachment = ContextImage(
                    id: id, width: prepared.width, height: prepared.height, data: prepared.data,
                    resourceScope: invocation.context.sessionID)
                current = Screenshot(
                    window: window, page: ObjectIdentifier(page), identity: identity,
                    scope: invocation.context.sessionID, capturedAt: Date(), image: attachment)
                revision += 1
                screenshotID = id
            } catch WebPageError.notVisible where allowsHiddenImage {
                screenshotID = nil
            }
        } else {
            screenshotID = nil
        }
        let receipt = Receipt(
            windowID: window.flatMap { windows.reference(for: $0) },
            url: observation.url.hasPrefix("file:") ? nil : observation.url,
            title: observation.title, text: observation.text, diagnostics: observation.diagnostics,
            screenshotID: screenshotID)
        return String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
    }
    private struct Receipt: Encodable {
        let windowID: String?
        let url: String?
        let title: String
        let text: String
        let diagnostics: String
        let screenshotID: String?
    }
    private func invalidateScreenshot() {
        current = nil
        revision += 1
    }
    /// Passive, single-image projection. No capture, disk read, selection or history.
    public func screenshotSnapshot(scope: String) throws -> MultimodalContextSnapshot {
        if let saved = current {
            guard !stopped, let item = try? windows.find(saved.window), item.phase == .settled,
                item.mode != .minimized, let page = pageForWindow(saved.window),
                ObjectIdentifier(page) == saved.page, page.snapshotIdentity == saved.identity
            else {
                invalidateScreenshot()
                return try screenshotSnapshot(scope: scope)
            }
        }
        struct Facts: Encodable {
            let revision: UInt64
            let active: Bool
            let windowID: String?
            let screenshotID: String?
            let capturedAt: Date?
        }
        let saved = current.flatMap { $0.scope == scope ? $0 : nil }
        let facts = Facts(
            revision: revision, active: saved != nil,
            windowID: saved.flatMap { windows.reference(for: $0.window) },
            screenshotID: saved?.image.id, capturedAt: saved?.capturedAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return .init(
            facts: try encoder.encode(facts), revision: revision,
            images: saved.map { [$0.image] } ?? [], resourceScope: saved?.scope)
    }
    public func stateSnapshot() throws -> ActionsStateSnapshot {
        let snapshot = try screenshotSnapshot(scope: current?.scope ?? "")
        return .init(
            path: "actions.web.screenshot",
            business: try JSONDecoder().decode([String: ActionsStateSnapshot.Value].self, from: snapshot.facts))
    }
    public func pauseWindow(invocation: any FunctionInput) async throws {
        let id = try lifecycleWindow(invocation)
        if current?.window == id { invalidateScreenshot() }
        await cancelOperation(in: id)
    }
    public func resumeWindow(invocation: any FunctionInput) async throws {}
    public func closeWindow(invocation: any FunctionInput) async throws {
        let id = try lifecycleWindow(invocation)
        if current?.window == id { invalidateScreenshot() }
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
        invalidateScreenshot()
        operation?.cancel()
        _ = await operation?.result
        for window in windows.windows where window.content == WindowContent.web.rawValue {
            removePage(window.id)
        }
    }
}

import Foundation
import Observation

public enum WebPageError: String, Error, Sendable {
    case unavailable, invalidURL, busy, timedOut, navigationFailed, notVisible, snapshotFailed, processTerminated
}

public struct WebPageObservation: Sendable {
    public let url: String
    public let title: String
    public let text: String
    public let diagnostics: String
    public init(url: String, title: String, text: String, diagnostics: String) {
        self.url = url
        self.title = title
        self.text = text
        self.diagnostics = diagnostics
    }
}

@MainActor public protocol WebPagePresenting: AnyObject, Sendable {
    func loadRemote(_ url: URL) async throws -> WebPageObservation
    func loadLocal(_ entry: URL) async throws -> WebPageObservation
    func observe() async throws -> WebPageObservation
    func snapshot() async throws -> Data
    func navigate(_ command: String) async throws -> WebPageObservation
    func close()
}

/// URL policy is independent of WebKit so confinement can be tested without native rendering.
public enum WebPagePolicy {
    public static func remote(_ url: URL) throws {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
            let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
            url.absoluteString.utf8.count <= 4096
        else { throw WebPageError.invalidURL }
    }
    public static func local(_ url: URL, root: URL) throws {
        guard url.isFileURL, root.isFileURL,
            url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path,
            root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
            url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
        else {
            throw WebPageError.invalidURL
        }
    }
}

#if canImport(WebKit)
    import WebKit
    #if os(iOS)
        import UIKit
    #else
        import AppKit
    #endif

    /// Root-owned native renderer. One active load; conflicting work is rejected, never queued.
    @Observable @MainActor
    public final class WebPageContainer: NSObject, WebPagePresenting, WKNavigationDelegate,
        WKUIDelegate
    {
        public private(set) var sessions: [UUID: WebPageContainer] = [:]
        public var isAvailable: Bool { available }
        private var sessionReferences: [UUID: String] = [:]
        public func createSession(windowID: UUID, reference: String? = nil) throws -> WebPageContainer {
            sessionReferences[windowID] = reference
            if let page = sessions[windowID] { return page }
            guard sessions.count < 4 else { throw WebPageError.busy }
            let page = WebPageContainer()
            page.setAvailable(available)
            sessions[windowID] = page
            return page
        }
        public func removeSession(windowID: UUID) {
            sessions.removeValue(forKey: windowID)?.close()
            sessionReferences.removeValue(forKey: windowID)
        }
        public func closeSessions() {
            for page in sessions.values { page.close() }
            sessions.removeAll()
            sessionReferences.removeAll()
        }
        private var documentUpdating = false
        private var localEntry: URL?
        private var localExecutesScripts: Bool?
        private var previewRevision: UInt64 = 0
        public func loadLocal(
            _ entry: URL, executesScripts: Bool, readAccessRoot: URL? = nil, preservingViewport: Bool = false
        ) async throws -> WebPageObservation {
            let root = readAccessRoot ?? entry.deletingLastPathComponent()
            try WebPagePolicy.local(entry, root: root)
            let retainsView = preservingViewport && localRoot == root && nativeView != nil && !address.isEmpty
            try await prepare(local: root)
            documentUpdating = true
            defer { documentUpdating = false }
            let view = webView
            let viewport = retainsView ? try await captureViewport() : nil
            #if os(iOS)
                let cover = retainsView && view.window != nil ? view.snapshotView(afterScreenUpdates: false) : nil
                if let cover {
                    cover.frame = view.bounds
                    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    cover.isUserInteractionEnabled = false
                    view.addSubview(cover)
                }
                defer { cover?.removeFromSuperview() }
            #endif
            view.configuration.defaultWebpagePreferences.allowsContentJavaScript = executesScripts
            localExecutesScripts = nil
            try await waitForNavigation { view.loadFileURL(entry, allowingReadAccessTo: root) }
            localExecutesScripts = executesScripts
            localEntry = entry
            if let viewport { try await restoreViewport(viewport) }
            return try await readObservation()
        }
        /// Same-document, script-disabled preview. No navigation and no replacement of its scroll view.
        public func updateLocalPreview(
            _ html: String, entry: URL, readAccessRoot: URL, documentEntry: URL? = nil
        ) async throws
            -> WebPageObservation
        {
            try WebPagePolicy.local(entry, root: readAccessRoot)
            let needsNavigation =
                localRoot != readAccessRoot || localExecutesScripts != false || address.isEmpty || failure != nil
                || (documentEntry != nil && nativeView?.url != documentEntry)
            #if os(iOS)
                // Keep a scripted page visible through both the safe-host navigation and its first DOM patch.
                let cover =
                    needsNavigation && documentEntry != nil && localRoot == readAccessRoot
                        && nativeView?.window != nil ? nativeView?.snapshotView(afterScreenUpdates: false) : nil
                if let cover, let view = nativeView {
                    cover.frame = view.bounds
                    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    cover.isUserInteractionEnabled = false
                    view.addSubview(cover)
                }
                defer { cover?.removeFromSuperview() }
            #endif
            guard !documentUpdating, !loading, !preparing else { throw WebPageError.busy }
            let transitionViewport =
                needsNavigation && documentEntry != nil && localRoot == readAccessRoot && nativeView != nil
                    && !address.isEmpty ? try await captureViewport() : nil
            if needsNavigation {
                let observation = try await loadLocal(
                    documentEntry ?? entry, executesScripts: false, readAccessRoot: readAccessRoot,
                    preservingViewport: true)
                if documentEntry == nil { return observation }
            }
            try await prepare(local: readAccessRoot)
            documentUpdating = true
            defer { documentUpdating = false }
            let view = webView
            let token = generation
            previewRevision += 1
            let revision = previewRevision
            #if os(iOS)
                let interacting =
                    view.scrollView.isTracking || view.scrollView.isDragging || view.scrollView.isDecelerating
            #else
                let interacting = false
            #endif
            do {
                _ = try await clientScript(
                    WebDocumentUpdate.patch,
                    arguments: [
                        "html": html, "baseURL": entry.absoluteString, "revision": String(revision),
                        "nativeInteracting": interacting,
                    ])
                try Task.checkCancellation()
                localEntry = entry
                if let transitionViewport { try await restoreViewport(transitionViewport) }
                return try await readObservation()
            } catch {
                // A cancelled RPC can still be preparing styles in WebKit. Abort and join its client-world cleanup.
                if available, nativeView === view, generation == token {
                    let cleanup = Task { @MainActor in
                        try await self.clientScript(WebDocumentUpdate.cancel, arguments: ["revision": String(revision)])
                    }
                    do { _ = try await cleanup.value } catch {
                        failure = "Preview cleanup failed: " + String(String(describing: error).prefix(256))
                    }
                }
                throw error
            }
        }
        private func clientScript(_ script: String, arguments: [String: Any] = [:]) async throws -> String {
            let view = webView
            let token = generation
            if documentUpdating { nativeCancel?() }
            let result: String = try await native { finish in
                view.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .defaultClient) {
                    result in
                    switch result {
                    case .success(let value):
                        if let value = value as? String {
                            finish(.success(value))
                        } else {
                            finish(.failure(WebPageError.navigationFailed))
                        }
                    case .failure(let error): finish(.failure(error))
                    }
                }
            }
            guard available, nativeView === view, generation == token else { throw WebPageError.unavailable }
            return result
        }
        private struct Viewport {
            let offset: CGPoint
            let scale: CGFloat
            let pageZoom: CGFloat
        }
        private func captureViewport() async throws -> Viewport {
            #if os(iOS)
                let scroll = webView.scrollView
                return Viewport(
                    offset: CGPoint(
                        x: (scroll.contentOffset.x + scroll.adjustedContentInset.left) / scroll.zoomScale,
                        y: (scroll.contentOffset.y + scroll.adjustedContentInset.top) / scroll.zoomScale),
                    scale: scroll.zoomScale / max(scroll.minimumZoomScale, .leastNonzeroMagnitude),
                    pageZoom: webView.pageZoom)
            #else
                let json = try await clientScript("return JSON.stringify({x:scrollX,y:scrollY});")
                guard let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Double],
                    let x = value["x"], let y = value["y"]
                else { throw WebPageError.navigationFailed }
                return Viewport(offset: CGPoint(x: x, y: y), scale: webView.magnification, pageZoom: webView.pageZoom)
            #endif
        }
        private func restoreViewport(_ viewport: Viewport) async throws {
            _ = try await clientScript(
                """
                await Promise.race([new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))),
                  new Promise(r=>setTimeout(r,120))]); return 'ready';
                """)
            if webView.pageZoom != viewport.pageZoom { webView.pageZoom = viewport.pageZoom }
            #if os(iOS)
                let view = webView
                let scroll = view.scrollView
                if view.window != nil {
                    // Flush the new content-process frame before restoring UIKit's scroll/zoom state.
                    let configuration = WKSnapshotConfiguration()
                    configuration.afterScreenUpdates = true
                    let _: Bool = try await native { finish in
                        view.takeSnapshot(with: configuration) { _, error in
                            if let error { finish(.failure(error)) } else { finish(.success(true)) }
                        }
                    }
                    guard available, nativeView === view else { throw WebPageError.unavailable }
                }
                // didFinish can precede UIKit's viewport/zoom-range update from the content process.
                let deadline = ContinuousClock.now + .milliseconds(500)
                while viewport.scale * scroll.minimumZoomScale > scroll.maximumZoomScale + 0.01,
                    view.window != nil, ContinuousClock.now < deadline
                {
                    try await Task.sleep(for: .milliseconds(16))
                    guard available, nativeView === view else { throw WebPageError.unavailable }
                }
                let zoom = min(
                    scroll.maximumZoomScale, max(scroll.minimumZoomScale, viewport.scale * scroll.minimumZoomScale))
                scroll.setZoomScale(zoom, animated: false)
                let inset = scroll.adjustedContentInset
                let x = viewport.offset.x * zoom - inset.left
                let y = viewport.offset.y * zoom - inset.top
                scroll.setContentOffset(
                    CGPoint(
                        x: min(
                            max(-inset.left, x),
                            max(-inset.left, scroll.contentSize.width - scroll.bounds.width + inset.right)),
                        y: min(
                            max(-inset.top, y),
                            max(-inset.top, scroll.contentSize.height - scroll.bounds.height + inset.bottom))),
                    animated: false)
            #else
                webView.setMagnification(viewport.scale, centeredAt: .zero)
                _ = try await clientScript(
                    "window.scrollTo(x,y); return 'restored';",
                    arguments: ["x": viewport.offset.x, "y": viewport.offset.y])
            #endif
        }
        private var nativeView: WKWebView?
        public var webView: WKWebView {
            if let nativeView { return nativeView }
            let view = WKWebView(frame: .zero, configuration: Self.configuration())
            view.navigationDelegate = self
            view.uiDelegate = self
            nativeView = view
            return view
        }
        public private(set) var address = ""
        public private(set) var failure: String?
        public private(set) var loading = false
        private var available = false
        private var localRoot: URL?
        private var pending: CheckedContinuation<Void, any Error>?
        private var deadline: Task<Void, Never>?
        private var navigation: WKNavigation?
        private var generation = UUID()
        private var localRules: WKContentRuleList?
        private var preparing = false
        private var nativeToken: UUID?
        private var nativeCancel: (() -> Void)?
        private var nativeDeadline: Task<Void, Never>?
        public override init() {
            super.init()
        }
        private static func configuration() -> WKWebViewConfiguration {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: """
                        window.__mobileHarnessErrors = [];
                        const record = e => { if(window.__mobileHarnessErrors.length < 8)
                          window.__mobileHarnessErrors.push(String(e.message || e.reason || e).slice(0,512)); };
                        window.addEventListener('error',record);
                        window.addEventListener('unhandledrejection',record);
                        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            return configuration
        }
        private func bind() {
            webView.navigationDelegate = self
            webView.uiDelegate = self
        }
        private func cancelDocumentPreview() {
            nativeView?.callAsyncJavaScript(
                WebDocumentUpdate.cancel, arguments: ["revision": ""], in: nil,
                in: .defaultClient, completionHandler: nil)
        }
        public func setAvailable(_ value: Bool) {
            if !value { cancelDocumentPreview() }
            available = value
            for page in sessions.values { page.setAvailable(value) }
            if !value {
                nativeCancel?()
                nativeView?.stopLoading()
                complete(.failure(WebPageError.unavailable))
                nativeView?.isHidden = true
            } else {
                nativeView?.isHidden = false
            }
        }
        private var pageBusiness: [String: UIStateSnapshot.Value] {
            [
                "content": .text(address.isEmpty ? "empty" : localRoot == nil ? "remote" : "local"),
                "url": !address.isEmpty && localRoot == nil && address.utf8.count <= 256 ? .text(address) : .unknown,
                "title": nativeView?.title.flatMap { $0.utf8.count <= 128 ? .text($0) : nil } ?? .unknown,
            ]
        }
        public func stateSnapshot() async throws -> UIStateSnapshot {
            try Task.checkCancellation()
            var business = pageBusiness
            business["sessions"] = .array(
                sessions.keys.sorted { $0.uuidString < $1.uuidString }.map { id in
                    guard let page = sessions[id] else { return .unknown }
                    return .object([
                        "windowID": sessionReferences[id].map { .text($0) } ?? .unknown,
                        "page": .object(page.pageBusiness),
                        "loading": .flag(page.loading), "available": .flag(page.available),
                    ])
                })
            return .init(
                path: "ui.web", business: business,
                runtime: ["available": .flag(available), "loading": .flag(loading)])
        }
        private func prepare(local root: URL?) async throws {
            guard available else { throw WebPageError.unavailable }
            guard pending == nil, !loading, !preparing, !documentUpdating else { throw WebPageError.busy }
            nativeCancel?()
            preparing = true
            defer { preparing = false }
            if root != localRoot || (root == nil && webView.url?.isFileURL == true) {
                close()
                let configuration = Self.configuration()
                if root != nil {
                    if localRules == nil {
                        localRules = try await WKContentRuleListStore.default().compileContentRuleList(
                            forIdentifier: "MobileHarnessLocalWeb",
                            encodedContentRuleList: """
                                [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
                                 {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]
                                """)
                    }
                    guard available else { throw WebPageError.unavailable }
                    if let localRules { configuration.userContentController.add(localRules) }
                }
                nativeView = WKWebView(frame: .zero, configuration: configuration)
                localRoot = root
                bind()
            }
        }
        public func loadRemote(_ url: URL) async throws -> WebPageObservation {
            try WebPagePolicy.remote(url)
            try await prepare(local: nil)
            try await waitForNavigation { webView.load(URLRequest(url: url)) }
            return try await observe()
        }
        public func loadLocal(_ entry: URL) async throws -> WebPageObservation {
            try await loadLocal(entry, executesScripts: true)
        }
        #if os(iOS)
            /// Dedicated export owners call this on an independent page, never the live editor page.
            public func exportLocalPDF(_ entry: URL, readAccessRoot: URL) async throws -> Data {
                try WebPagePolicy.local(entry, root: readAccessRoot)
                try await prepare(local: readAccessRoot)
                webView.frame = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
                _ = try await loadLocal(entry, executesScripts: true, readAccessRoot: readAccessRoot)
                try Task.checkCancellation()
                let renderer = WebPDFPageRenderer()
                renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
                let count = renderer.numberOfPages
                guard (1...100).contains(count) else { throw WebPageError.snapshotFailed }
                renderer.prepare(forDrawingPages: NSRange(location: 0, length: count))
                let data = UIGraphicsPDFRenderer(bounds: renderer.paperRect).pdfData { context in
                    for index in 0..<count {
                        if Task.isCancelled { break }
                        context.beginPage()
                        renderer.drawPage(at: index, in: renderer.paperRect)
                    }
                }
                try Task.checkCancellation()
                guard !data.isEmpty, data.count <= 16 * 1024 * 1024 else { throw WebPageError.snapshotFailed }
                return data
            }
        #endif
        private func waitForNavigation(_ begin: () -> WKNavigation?) async throws {
            guard available else { throw WebPageError.unavailable }
            guard pending == nil, !loading else { throw WebPageError.busy }
            try Task.checkCancellation()
            nativeCancel?()
            let token = UUID()
            generation = token
            loading = true
            failure = nil
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pending = continuation
                    navigation = begin()
                    guard navigation != nil else {
                        complete(.failure(WebPageError.navigationFailed))
                        return
                    }
                    deadline = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(25)) } catch { return }
                        guard let self, generation == token else { return }
                        webView.stopLoading()
                        complete(.failure(WebPageError.timedOut))
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, generation == token else { return }
                    webView.stopLoading()
                    complete(.failure(CancellationError()))
                }
            }
        }
        private func complete(_ result: Result<Void, any Error>) {
            deadline?.cancel()
            deadline = nil
            loading = false
            if case .failure(let error) = result { failure = String(describing: error) }
            let waiter = pending
            pending = nil
            waiter?.resume(with: result)
        }
        private func native<Value: Sendable>(
            _ start: (@escaping @MainActor (Result<Value, any Error>) -> Void) -> Void
        ) async throws -> Value {
            guard nativeCancel == nil else { throw WebPageError.busy }
            try Task.checkCancellation()
            let token = UUID()
            nativeToken = token
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let finish: @MainActor (Result<Value, any Error>) -> Void = { [weak self] result in
                        guard let self, nativeToken == token else { return }
                        nativeToken = nil
                        nativeCancel = nil
                        nativeDeadline?.cancel()
                        nativeDeadline = nil
                        continuation.resume(with: result)
                    }
                    nativeCancel = { finish(.failure(CancellationError())) }
                    nativeDeadline = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(10)) } catch { return }
                        finish(.failure(WebPageError.timedOut))
                        self?.close()
                    }
                    start(finish)
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, nativeToken == token else { return }
                    nativeCancel?()
                }
            }
        }
        public func observe() async throws -> WebPageObservation {
            guard !documentUpdating else { throw WebPageError.busy }
            return try await readObservation()
        }
        private func readObservation() async throws -> WebPageObservation {
            if documentUpdating { nativeCancel?() }
            guard available, !loading, webView.url != nil, failure == nil else { throw WebPageError.unavailable }
            try Task.checkCancellation()
            let token = generation
            let view = webView
            let script = """
                JSON.stringify({title:document.title.slice(0,256),text:(document.body?.innerText||'').slice(0,10000),
                errors:(window.__mobileHarnessErrors||[]).slice(0,8).map(x=>String(x).slice(0,512)).join('\\n')})
                """
            let json: String = try await native { finish in
                view.evaluateJavaScript(script) { value, error in
                    if let error {
                        finish(.failure(error))
                    } else if let text = value as? String {
                        finish(.success(text))
                    } else {
                        finish(.failure(WebPageError.navigationFailed))
                    }
                }
            }
            guard token == generation, view === nativeView, available, !loading else { throw WebPageError.unavailable }
            guard let data = json.data(using: .utf8),
                let object = try JSONSerialization.jsonObject(with: data) as? [String: String]
            else {
                throw WebPageError.navigationFailed
            }
            try Task.checkCancellation()
            address = webView.url?.absoluteString ?? ""
            return .init(
                url: address, title: object["title"] ?? "",
                text: String(decoding: (object["text"] ?? "").utf8.prefix(8000), as: UTF8.self),
                diagnostics: String(decoding: (object["errors"] ?? "").utf8.prefix(2048), as: UTF8.self))
        }
        public func snapshot() async throws -> Data {
            guard !documentUpdating else { throw WebPageError.busy }
            guard available, !loading, failure == nil else { throw WebPageError.unavailable }
            guard webView.window != nil, !webView.isHidden, webView.bounds.width > 1, webView.bounds.height > 1 else {
                throw WebPageError.notVisible
            }
            try Task.checkCancellation()
            let view = webView
            let token = generation
            let configuration = WKSnapshotConfiguration()
            #if os(iOS)
                let scale = view.window?.screen.scale ?? 1
            #else
                let scale = view.window?.backingScaleFactor ?? 1
            #endif
            configuration.snapshotWidth = NSNumber(value: 1024 / Double(scale))
            configuration.afterScreenUpdates = true
            let data: Data = try await native { finish in
                view.takeSnapshot(with: configuration) { image, error in
                    if let error {
                        finish(.failure(error))
                        return
                    }
                    #if os(iOS)
                        let data = image?.jpegData(compressionQuality: 0.8)
                    #else
                        let data = image?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
                            .representation(using: .jpeg, properties: [.compressionFactor: 0.8])
                    #endif
                    guard let data, !data.isEmpty, data.count <= 4 * 1024 * 1024 else {
                        finish(.failure(WebPageError.snapshotFailed))
                        return
                    }
                    finish(.success(data))
                }
            }
            try Task.checkCancellation()
            guard available, view === nativeView, token == generation, !loading else { throw WebPageError.unavailable }
            return data
        }
        public func navigate(_ command: String) async throws -> WebPageObservation {
            guard !documentUpdating else { throw WebPageError.busy }
            if command == "reload", let localEntry, let localRoot {
                return try await loadLocal(
                    localEntry, executesScripts: localExecutesScripts ?? true,
                    readAccessRoot: localRoot, preservingViewport: true)
            }
            switch command {
            case "back": try await waitForNavigation { webView.goBack() }
            case "forward": try await waitForNavigation { webView.goForward() }
            case "reload": try await waitForNavigation { webView.reload() }
            case "up", "down", "top", "bottom":
                guard available, !loading, failure == nil else { throw WebPageError.unavailable }
                let scripts = [
                    "up": "window.scrollBy(0,-innerHeight*0.8)", "down": "window.scrollBy(0,innerHeight*0.8)",
                    "top": "window.scrollTo(0,0)", "bottom": "window.scrollTo(0,document.documentElement.scrollHeight)",
                ]
                guard let script = scripts[command] else { throw WebPageError.invalidURL }
                let view = webView
                let _: Bool = try await native { finish in
                    view.evaluateJavaScript(script) { _, error in
                        if let error { finish(.failure(error)) } else { finish(.success(true)) }
                    }
                }
            case "stop":
                webView.stopLoading()
                complete(.failure(WebPageError.navigationFailed))
            default: throw WebPageError.invalidURL
            }
            return try await observe()
        }
        public func close() {
            cancelDocumentPreview()
            generation = UUID()
            nativeCancel?()
            nativeView?.stopLoading()
            complete(.failure(WebPageError.unavailable))
            nativeView?.navigationDelegate = nil
            nativeView?.uiDelegate = nil
            nativeView?.removeFromSuperview()
            nativeView = nil
            localRoot = nil
            localExecutesScripts = nil
            localEntry = nil
            address = ""
        }
        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard webView === nativeView, navigation === self.navigation, loading else { return }
            address = webView.url?.absoluteString ?? ""
            complete(.success(()))
        }
        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            guard webView === nativeView, navigation === self.navigation, loading else { return }
            complete(.failure(error))
        }
        public func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
        ) {
            self.webView(webView, didFail: navigation, withError: error)
        }
        public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard webView === nativeView else { return }
            nativeCancel?()
            complete(.failure(WebPageError.processTerminated))
        }
        public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard webView === nativeView else { return }
            if pending != nil { return }
            nativeCancel?()
            generation = UUID()
            self.navigation = navigation
            loading = true
            failure = nil
            deadline?.cancel()
            let token = generation
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                guard let self, generation == token else { return }
                webView.stopLoading()
                complete(.failure(WebPageError.timedOut))
            }
        }
        public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async
            -> WKNavigationActionPolicy
        {
            guard available, let url = action.request.url else { return .cancel }
            do {
                if let localRoot {
                    try WebPagePolicy.local(url, root: localRoot)
                } else {
                    try WebPagePolicy.remote(url)
                }
                return .allow
            } catch { return .cancel }
        }
        public func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for action: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if action.targetFrame == nil, let url = action.request.url, localRoot == nil,
                (try? WebPagePolicy.remote(url)) != nil
            {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
#endif

#if os(iOS) && canImport(WebKit)
    @MainActor private final class WebPDFPageRenderer: UIPrintPageRenderer {
        override var paperRect: CGRect { CGRect(x: 0, y: 0, width: 595.28, height: 841.89) }
        override var printableRect: CGRect { paperRect.insetBy(dx: 28, dy: 28) }
    }
#endif

#if canImport(WebKit)
    /// Host-only DOM reconciliation. Source HTML is an argument, never executable host code.
    private enum WebDocumentUpdate {
        static let cancel = #"""
            const s=globalThis.__mobileHarnessPreview;
            if(s && (!revision || s.revision===revision)) s.cancel?.();
            return 'cancelled';
            """#
        static let patch = #"""
            const doc=document;
            const s=globalThis.__mobileHarnessPreview ||= {revision:'0',lastScroll:-Infinity,until:0};
            if(BigInt(revision)<BigInt(s.revision)) throw new Error('Stale preview');
            s.cancel?.(); s.revision=revision;
            if(!s.listening){
              s.listening=true;
              for(const event of ['touchstart','touchmove','pointerdown','pointermove','wheel'])
                addEventListener(event,()=>{s.until=performance.now()+250;},{passive:true,capture:true});
              addEventListener('scroll',()=>{s.lastScroll=performance.now();},{passive:true,capture:true});
            }
            const desired=new DOMParser().parseFromString(html,'text/html');
            desired.querySelectorAll('script,iframe,frame,object,embed,base,meta[http-equiv]').forEach(n=>n.remove());
            for(const node of desired.querySelectorAll('*')){
              for(const a of [...node.attributes]){
                if(/^on/i.test(a.name) || /^(?:javascript|vbscript):/i.test(a.value.trim())) node.removeAttribute(a.name);
                else if(['href','src','poster','data','xlink:href'].includes(a.name) && a.value){
                  try {
                    const value=a.name==='href' && a.value.startsWith('#') ? new URL(a.value,document.URL) : new URL(a.value,baseURL);
                    if(['javascript:','vbscript:'].includes(value.protocol))node.removeAttribute(a.name);
                    else node.setAttributeNS(a.namespaceURI,a.name,value.href);
                  } catch { node.removeAttribute(a.name); }
                }
              }
            }
            const base=desired.createElement('base'); base.href=baseURL; desired.head.prepend(base);
            const stages=new Map(), staged=new Set(), activated=new Set(), rejectors=new Set();
            const owned=s.staging ||= new WeakSet();
            let aborted=false;
            s.cancel=()=>{aborted=true;for(const reject of [...rejectors])reject(new Error('Preview cancelled'));};
            const current=()=>!aborted && s.revision===revision && document===doc;
            const attrs=(live,next)=>{
              for(const a of [...live.attributes]) if(!next.hasAttributeNS(a.namespaceURI,a.localName)) live.removeAttributeNS(a.namespaceURI,a.localName);
              for(const a of [...next.attributes]) if(live.getAttributeNS(a.namespaceURI,a.localName)!==a.value)
                live.setAttributeNS(a.namespaceURI,a.name,a.value);
            };
            const type=n=>n.nodeType===1 ? n.namespaceURI+':'+n.localName : String(n.nodeType);
            const key=n=>{
              if(n.nodeType!==1)return null;
              if(n.id)return type(n)+'#'+n.id;
              if(n.hasAttribute('data-key'))return type(n)+'@'+n.getAttribute('data-key');
              if(n.localName==='meta')return 'meta:'+ (n.getAttribute('name')||n.getAttribute('charset'));
              if(n.localName==='link')return 'link:'+n.rel+':'+new URL(n.href,baseURL).pathname.split('/').pop();
              return null;
            };
            const children=(live,next)=>{
              const old=[...live.childNodes].filter(n=>!owned.has(n));
              const keyed=new Map(), pools=new Map(), used=new Set();
              for(const node of old){
                const k=key(node), map=k ? keyed : pools, id=k||type(node);
                if(!map.has(id))map.set(id,{nodes:[],index:0});
                map.get(id).nodes.push(node);
              }
              let cursor=live.firstChild;
              for(const wanted of [...next.childNodes]){
                const k=key(wanted), pool=(k ? keyed : pools).get(k||type(wanted));
                let node=pool?.nodes[pool.index++];
                if(node && type(node)!==type(wanted))node=null;
                if(node)used.add(node);
                const ready=stages.get(wanted);
                if(ready){
                  attrs(ready,wanted); activated.add(ready);owned.delete(ready);
                  if(node){if(cursor===node)cursor=node.nextSibling;node.remove();}
                  live.insertBefore(ready,cursor);
                  node=ready;
                }else if(!node){
                  node=doc.importNode(wanted,true);live.insertBefore(node,cursor);
                }else{
                  if(node!==cursor)live.insertBefore(node,cursor);
                  if(node.nodeType===1){attrs(node,wanted);children(node,wanted);}
                  else if(node.nodeValue!==wanted.nodeValue)node.nodeValue=wanted.nodeValue;
                }
                cursor=node.nextSibling;
              }
              for(const node of old)if(!used.has(node))node.remove();
            };
            try{
              // Prepare local styles without removing the currently active sheet. Capture the user's
              // viewport only after this asynchronous work, immediately before the synchronous commit.
              await Promise.all([...desired.querySelectorAll('link[rel~="stylesheet"]')].map(async target=>{
                if(new URL(target.href).protocol!=='file:')return;
                const existing=[...doc.querySelectorAll('link[rel~="stylesheet"]')].find(n=>!owned.has(n) && n.href===target.href && n.sheet);
                if(existing)return;
                const link=doc.createElement('link');link.rel='stylesheet';link.href=target.href;link.media='not all';
                stages.set(target,link);staged.add(link);owned.add(link);
                await new Promise((resolve,reject)=>{
                  let timer;
                  const done=error=>{clearTimeout(timer);rejectors.delete(cancel);link.onload=null;link.onerror=null;error?reject(error):resolve();};
                  const cancel=error=>done(error);rejectors.add(cancel);
                  link.onload=()=>done();link.onerror=()=>done(new Error('Local stylesheet failed: '+target.href));
                  timer=setTimeout(()=>done(new Error('Local stylesheet timed out')),2000);
                  doc.head.append(link);
                });
              }));
              if(!current())throw new Error('Preview superseded');
              const vv=visualViewport;
              const pointX=(vv?.offsetLeft||0)+(vv?.width||innerWidth)/2;
              const pointY=(vv?.offsetTop||0)+Math.min(80,(vv?.height||innerHeight)/3);
              const hit=doc.elementFromPoint(pointX,pointY);
              let anchor=hit?.closest('[id],[data-key]')||hit;
              if(!anchor || anchor===doc.body || anchor===doc.documentElement){
                anchor=[...doc.querySelectorAll('[id],[data-key]')].find(node=>{
                  const r=node.getBoundingClientRect();return r.height>0 && r.top>=0 && r.top<innerHeight;
                })||null;
              }
              const top=anchor?.getBoundingClientRect().top;
              const x=scrollX,y=scrollY;
              const interacting=nativeInteracting || performance.now()<s.until || performance.now()-s.lastScroll<150;
              attrs(doc.documentElement,desired.documentElement);
              attrs(doc.head,desired.head);children(doc.head,desired.head);
              attrs(doc.body,desired.body);children(doc.body,desired.body);
              if(!interacting){
                const delta=anchor?.isConnected && top!==undefined ? anchor.getBoundingClientRect().top-top : 0;
                window.scrollTo({left:x,top:anchor?.isConnected ? scrollY+delta : y,behavior:'instant'});
              }
              return 'updated';
            }finally{
              for(const link of staged)if(!activated.has(link)){link.remove();owned.delete(link);}
              if(s.revision===revision)s.cancel=null;
            }
            """#
    }
#endif

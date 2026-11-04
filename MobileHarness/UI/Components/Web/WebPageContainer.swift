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
        public func createSession(windowID: UUID) throws -> WebPageContainer {
            if let page = sessions[windowID] { return page }
            guard sessions.count < 4 else { throw WebPageError.busy }
            let page = WebPageContainer()
            page.setAvailable(available)
            sessions[windowID] = page
            return page
        }
        public func removeSession(windowID: UUID) {
            sessions.removeValue(forKey: windowID)?.close()
        }
        public func closeSessions() {
            for page in sessions.values { page.close() }
            sessions.removeAll()
        }
        public func loadLocal(_ entry: URL, executesScripts: Bool, readAccessRoot: URL? = nil) async throws
            -> WebPageObservation
        {
            let root = readAccessRoot ?? entry.deletingLastPathComponent()
            try WebPagePolicy.local(entry, root: root)
            try await prepare(local: root)
            webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = executesScripts
            try await waitForNavigation { webView.loadFileURL(entry, allowingReadAccessTo: root) }
            return try await observe()
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
        public func setAvailable(_ value: Bool) {
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
                        "windowID": .text(id.uuidString), "page": .object(page.pageBusiness),
                        "loading": .flag(page.loading), "available": .flag(page.available),
                    ])
                })
            return .init(
                path: "ui.web", business: business,
                runtime: ["available": .flag(available), "loading": .flag(loading)])
        }
        private func prepare(local root: URL?) async throws {
            guard available else { throw WebPageError.unavailable }
            guard pending == nil, !loading, !preparing else { throw WebPageError.busy }
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
            let root = entry.deletingLastPathComponent()
            try WebPagePolicy.local(entry, root: root)
            try await prepare(local: root)
            try await waitForNavigation { webView.loadFileURL(entry, allowingReadAccessTo: root) }
            return try await observe()
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
            generation = UUID()
            nativeCancel?()
            nativeView?.stopLoading()
            complete(.failure(WebPageError.unavailable))
            nativeView?.navigationDelegate = nil
            nativeView?.uiDelegate = nil
            nativeView?.removeFromSuperview()
            nativeView = nil
            localRoot = nil
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

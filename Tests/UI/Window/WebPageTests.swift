import Foundation
import Testing
import UI

@Test func webURLPolicyRejectsPrivilegeSchemesCredentialsAndTraversal() throws {
    for raw in ["javascript:alert(1)", "data:text/html,test", "file:///etc/hosts", "https://user:pass@example.com"] {
        #expect(throws: WebPageError.invalidURL) { try WebPagePolicy.remote(URL(string: raw)!) }
    }
    try WebPagePolicy.remote(URL(string: "https://example.com/path?q=a")!)
    let root = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().appendingPathComponent("project")
    try WebPagePolicy.local(root.appendingPathComponent("index.html"), root: root)
    #expect(throws: WebPageError.invalidURL) {
        try WebPagePolicy.local(root.appendingPathComponent("../secret.html"), root: root)
    }
}

#if os(macOS)
    import AppKit
    import WebKit

    extension NativePresentationTests {
        @Test @MainActor func webNativeLoadsLocalJavaScriptAndCapturesVisiblePixels() async throws {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let entry = root.appendingPathComponent("index.html")
            try """
            <!doctype html><html><head><title>Native Web Fixture</title>
            <link rel="stylesheet" href="style.css"></head><body><h1 id="title">Before</h1>
            <script src="app.js"></script></body></html>
            """.write(to: entry, atomically: true, encoding: .utf8)
            try "body{background:#d4ecff}h1{color:#123456}".write(
                to: root.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
            try "document.querySelector('#title').textContent='Rendered with JavaScript';".write(
                to: root.appendingPathComponent("app.js"), atomically: true, encoding: .utf8)
            let page = WebPageContainer()
            page.setAvailable(true)
            let observation = try await page.loadLocal(entry)
            #expect(observation.title == "Native Web Fixture")
            #expect(observation.text.contains("Rendered with JavaScript"))
            #expect(observation.diagnostics.isEmpty)
            let state = try await page.stateSnapshot()
            #expect(state.business["content"] == .text("local"))
            #expect(state.business["url"] == .unknown)
            #expect(page.snapshotIdentity == nil)
            await #expect(throws: WebPageError.notVisible) { try await page.snapshot() }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = page.webView
            window.makeKeyAndOrderFront(nil)
            defer {
                page.close()
                window.close()
            }
            let bytes = try await page.snapshot()
            #expect(NSImage(data: bytes) != nil)
            let identity = try #require(page.snapshotIdentity)
            #expect(page.snapshotIdentity == identity)
            _ = try await page.navigate("top")
            #expect(page.snapshotIdentity != nil && page.snapshotIdentity != identity)
            let navigated = page.snapshotIdentity
            page.webView.pageZoom = 1.25
            #expect(page.snapshotIdentity != navigated)
            page.setAvailable(false)
            #expect(page.snapshotIdentity == nil)
            await #expect(throws: WebPageError.unavailable) { try await page.snapshot() }
            page.close()
            let closed = try await page.stateSnapshot()
            #expect(closed.business["content"] == .text("empty") && closed.business["url"] == .unknown)
        }

        @Test @MainActor func webSessionStateListsAllOwnersAndHidesLocalPaths() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let pages = WebPageContainer()
            pages.setAvailable(true)
            defer {
                pages.closeSessions()
                pages.close()
            }
            var ids: [UUID] = []
            let references = ["window_1", "window_2"]
            for (title, reference) in zip(["Writer A", "Writer B"], references) {
                let id = UUID()
                ids.append(id)
                let page = try pages.createSession(windowID: id, reference: reference)
                let entry = root.appendingPathComponent(id.uuidString + ".html")
                try "<title>\(title)</title><h1>\(title)</h1>".write(to: entry, atomically: true, encoding: .utf8)
                _ = try await page.loadLocal(entry)
            }
            let state = try await pages.stateSnapshot()
            #expect(state.business["content"] == .text("empty"))
            guard case .array(let sessions) = state.business["sessions"] else {
                Issue.record("Missing session facts")
                return
            }
            #expect(sessions.count == 2)
            let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
            for reference in references { #expect(json.contains(reference)) }
            for id in ids { #expect(!json.contains(id.uuidString)) }
            #expect(json.contains("Writer A") && json.contains("Writer B"))
            #expect(!json.contains(root.path) && !json.contains("file:"))
            pages.removeSession(windowID: ids[0])
            guard case .array(let remaining) = try await pages.stateSnapshot().business["sessions"] else {
                Issue.record("Missing remaining page")
                return
            }
            #expect(remaining.count == 1)
        }

        @Test @MainActor func webNavigationPreemptsInFlightInspectionInsteadOfRejectingRender() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let old = root.appendingPathComponent("old.html")
            let updated = root.appendingPathComponent("updated.html")
            try "<h1>Old</h1>".write(to: old, atomically: true, encoding: .utf8)
            try "<h1>Updated</h1>".write(to: updated, atomically: true, encoding: .utf8)
            let page = WebPageContainer()
            page.setAvailable(true)
            defer { page.close() }
            _ = try await page.loadLocal(old)
            _ = try await page.webView.evaluateJavaScript(
                "Object.defineProperty(document.body,'innerText',{get(){const until=Date.now()+500;while(Date.now()<until){};return 'Old';}});true"
            )
            let read = Task { try await page.observe() }
            try await Task.sleep(for: .milliseconds(30))
            let result = try await page.loadLocal(updated)
            #expect(result.text.contains("Updated"))
            await #expect(throws: CancellationError.self) { try await read.value }
            #expect(!page.loading)
        }
    }
#endif

#if os(macOS)
    extension NativePresentationTests {
        @Test @MainActor func webPreviewPatchesRetainNativeDocumentAnchorZoomAndScriptIsolation() async throws {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let page = WebPageContainer()
            page.setAvailable(true)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = page.webView
            window.makeKeyAndOrderFront(nil)
            defer {
                page.close()
                window.close()
            }
            func version(_ number: Int, extra: Bool) throws -> (URL, String) {
                let directory = root.appendingPathComponent("version-\(number)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let rows = (0..<80).map { "<section id='row\($0)'>Row \($0)</section>" }.joined()
                let html = """
                    <!doctype html><html><head><meta name=viewport content='width=device-width,initial-scale=1'>
                    <title>Preview \(number)</title><link rel=stylesheet href=style.css></head><body>
                    \(extra ? "<aside id='inserted' style='height:250px'>New content above</aside>" : "")
                    \(rows)<button id=button onclick="document.body.dataset.ran='event'">Click</button>
                    <script>document.body.dataset.ran='script';</script></body></html>
                    """
                try "body{margin:0;color:\(number == 1 ? "rgb(10,20,30)" : "rgb(40,50,60)")}section{height:100px}"
                    .write(
                        to: directory.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
                let entry = directory.appendingPathComponent("index.html")
                try html.write(to: entry, atomically: true, encoding: .utf8)
                return (entry, html)
            }
            let first = try version(1, extra: false)
            _ = try await page.updateLocalPreview(first.1, entry: first.0, readAccessRoot: root)
            let view = page.webView
            window.contentView = view
            view.pageZoom = 1.25
            _ = try await view.evaluateJavaScript(
                "window.keptDocument=document;window.keptNode=document.getElementById('row40');scrollTo(0,4000)")
            try await Task.sleep(for: .milliseconds(300))
            let before = try #require(
                try await view.evaluateJavaScript(
                    "JSON.stringify({y:scrollY,top:document.getElementById('row40').getBoundingClientRect().top})")
                    as? String)
            let old = try #require(try JSONSerialization.jsonObject(with: Data(before.utf8)) as? [String: Double])
            for number in 2...3 {
                let next = try version(number, extra: true)
                let result = try await page.updateLocalPreview(next.1, entry: next.0, readAccessRoot: root)
                #expect(result.title == "Preview \(number)")
                #expect(page.webView === view && view.pageZoom == 1.25)
                let value = try #require(
                    try await view.evaluateJavaScript(
                        """
                        JSON.stringify({same:window.keptDocument===document && window.keptNode===document.getElementById('row40'),
                        top:document.getElementById('row40').getBoundingClientRect().top,color:getComputedStyle(document.body).color,
                        safe:!document.body.dataset.ran && document.scripts.length===0 && !document.getElementById('button').hasAttribute('onclick')})
                        """) as? String)
                let metrics = try #require(try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
                #expect(metrics["same"] as? Bool == true && metrics["safe"] as? Bool == true)
                #expect(metrics["color"] as? String == "rgb(40, 50, 60)")
                #expect(abs((metrics["top"] as? Double ?? 99999) - (old["top"] ?? 0)) < 3)
            }
            // A failed stylesheet must leave the last valid document visible.
            let broken = first.1.replacingOccurrences(of: "href=style.css", with: "href=missing.css")
            await #expect(throws: (any Error).self) {
                try await page.updateLocalPreview(broken, entry: first.0, readAccessRoot: root)
            }
            #expect(page.webView === view)
            #expect(try await page.observe().title == "Preview 3")
            let cancelled = Task { @MainActor in
                try await page.updateLocalPreview(first.1, entry: first.0, readAccessRoot: root)
            }
            cancelled.cancel()
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            #expect(try await page.observe().title == "Preview 3")
            // Wheel/touch state is shared across content worlds. A patch must not scroll against it.
            _ = try await view.callAsyncJavaScript(
                """
                globalThis.hostScrolls=0;const originalScroll=window.scrollTo.bind(window);
                window.scrollTo=(...args)=>{globalThis.hostScrolls++;return originalScroll(...args);};
                dispatchEvent(new WheelEvent('wheel',{deltaY:120})); return 'ready';
                """, arguments: [:], in: nil, contentWorld: .defaultClient)
            let gesture = try version(4, extra: true)
            _ = try await page.updateLocalPreview(gesture.1, entry: gesture.0, readAccessRoot: root)
            #expect(
                try await view.callAsyncJavaScript(
                    "return globalThis.hostScrolls;", arguments: [:], in: nil, contentWorld: .defaultClient) as? Int
                    == 0)
            let entry = try version(5, extra: true).0
            let offset = try #require(try await view.evaluateJavaScript("scrollY") as? Double)
            _ = try await page.loadLocal(entry, executesScripts: true, readAccessRoot: root, preservingViewport: true)
            #expect(page.webView === view && view.pageZoom == 1.25)
            let restored = try #require(try await view.evaluateJavaScript("scrollY") as? Double)
            #expect(abs(restored - offset) < 3)
            let executed = try await view.evaluateJavaScript("document.body.dataset.ran") as? String
            #expect(executed == "script")
        }
    }
#endif

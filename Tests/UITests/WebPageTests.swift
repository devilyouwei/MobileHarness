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
            page.setAvailable(false)
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
            for title in ["Writer A", "Writer B"] {
                let id = UUID()
                ids.append(id)
                let page = try pages.createSession(windowID: id)
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
            for id in ids { #expect(json.contains(id.uuidString)) }
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

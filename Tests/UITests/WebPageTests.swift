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
    }
#endif

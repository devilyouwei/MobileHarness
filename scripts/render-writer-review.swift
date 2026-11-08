// Offline visual evidence for generated Writer files; never calls a model or changes the source artifact.
import AppKit
import Foundation
import WebKit

@MainActor final class WriterReview: NSObject, WKNavigationDelegate {
    let window: NSWindow
    let view: WKWebView
    let output: URL
    var finished = false
    init(input: URL, output: URL) {
        self.output = output
        window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 390, height: 844), styleMask: [.borderless],
            backing: .buffered, defer: false)
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 390, height: 844))
        super.init()
        window.contentView = view
        view.navigationDelegate = self
        window.orderBack(nil)
        view.loadFileURL(input, allowingReadAccessTo: input.deletingLastPathComponent())
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in self?.finish(code: 2) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            let config = WKSnapshotConfiguration()
            config.snapshotWidth = 780
            view.takeSnapshot(with: config) { [self] image, error in
                guard error == nil, let tiff = image?.tiffRepresentation,
                    let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                else {
                    finish(code: 3)
                    return
                }
                do {
                    try png.write(to: output, options: .atomic)
                    finish(code: 0)
                } catch { finish(code: 4) }
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(code: 5)
    }
    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) { finish(code: 5) }
    func finish(code: Int32) {
        guard !finished else { return }
        finished = true
        view.stopLoading()
        window.orderOut(nil)
        exit(code)
    }
}
@main struct WriterReviewMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard CommandLine.arguments.count == 3 else { exit(1) }
        let review = WriterReview(
            input: URL(fileURLWithPath: CommandLine.arguments[1]),
            output: URL(fileURLWithPath: CommandLine.arguments[2]))
        withExtendedLifetime(review) { app.run() }
    }
}

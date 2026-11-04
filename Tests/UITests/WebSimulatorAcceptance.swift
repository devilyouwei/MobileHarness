#if WEBKIT_ACCEPTANCE && os(iOS)
    import Foundation
    import SwiftUI
    import PDFKit

    /// Standalone test host compiled with the production UI files by test-webkit-simulator.sh.
    @main @MainActor struct WebSimulatorAcceptance: App {
        @State private var page = WebPageContainer()
        @State private var status = "Running WebKit acceptance"
        var body: some Scene {
            WindowGroup {
                VStack {
                    Text(status).font(.headline).padding()
                    WebPageView(page: page)
                }.task { await run() }
            }
        }
        private func run() async {
            let files = FileManager.default
            let root = files.urls(for: .documentDirectory, in: .userDomainMask)[0]
            var evidence: [String: String] = [:]
            do {
                page.setAvailable(true)
                for version in 1...2 {
                    let folder = root.appendingPathComponent("version-\(version)").resolvingSymlinksInPath()
                    try files.createDirectory(at: folder, withIntermediateDirectories: true)
                    let html = """
                        <!doctype html><html lang="zh"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
                        <title>流程图 · 版本 \(version)</title><link rel="stylesheet" href="style.css"></head><body>
                        <header>WEBKIT · LOCAL WORKSPACE</header><h1>从想法到画面</h1><p>HTML + CSS + JavaScript</p>
                        <main><section>01<br><b>文字任务</b></section><i>↓</i><section>02<br><b>局部修改</b></section>
                        <i>↓</i><section class="result">03<br><b id="result">等待脚本</b></section></main>
                        <footer>独立页面 · 版本 \(version) <span id="tick">0</span></footer><script src="app.js"></script></body></html>
                        """
                    try html.write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
                    try """
                    *{box-sizing:border-box}body{margin:0;padding:30px 24px;background:#f4f0e9;color:#203c36;
                    font-family:system-ui}header{font-size:10px;letter-spacing:2px;color:#59776a}h1{font-size:28px;margin:24px 0 6px}
                    p{font-size:13px;color:#59776a}main{margin:32px 0}section{background:white;border:1px solid #d4dfd6;
                    padding:20px;border-radius:15px;font-size:12px}b{font-size:20px;line-height:1.9}i{display:block;text-align:center;
                    font-style:normal;margin:5px}.result{background:#d5eee0;animation:pulse 2s infinite alternate}
                    footer{font-size:12px;color:#59776a}@keyframes pulse{to{transform:translateX(5px)}}
                    @media(prefers-reduced-motion:reduce){.result{animation:none}}
                    """.write(to: folder.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
                    try """
                    document.getElementById('result').textContent='\(version == 1 ? "首次渲染" : "更新已呈现")';
                    let tick=0;setInterval(()=>document.getElementById('tick').textContent=String(++tick),100);
                    """.write(to: folder.appendingPathComponent("app.js"), atomically: true, encoding: .utf8)
                    let observation = try await page.loadLocal(folder.appendingPathComponent("index.html"))
                    evidence["observed-\(version)"] =
                        "title: \(observation.title); text: \(observation.text); errors: \(observation.diagnostics)"
                    guard observation.title.contains("\(version)"), observation.diagnostics.isEmpty else {
                        throw WebPageError.navigationFailed
                    }
                    try await Task.sleep(for: .milliseconds(600))
                    let rendered = try await page.observe()
                    guard rendered.text.contains(version == 1 ? "首次渲染" : "更新已呈现") else {
                        throw WebPageError.navigationFailed
                    }
                    let bytes = try await page.snapshot()
                    try bytes.write(to: root.appendingPathComponent("local-\(version).jpg"))
                    evidence["local-\(version)"] =
                        "HTML/CSS/JS loaded; screenshot \(bytes.count) bytes; " + rendered.text
                }
                let projectRoot = root.appendingPathComponent("version-2").resolvingSymlinksInPath()
                let nested = projectRoot.appendingPathComponent("pages")
                try files.createDirectory(at: nested, withIntermediateDirectories: true)
                let nestedEntry = nested.appendingPathComponent("index.html")
                try """
                <!doctype html><meta charset=utf-8><link rel=stylesheet href=../style.css>
                <b id=result>waiting</b><span id=tick>0</span><script src=../app.js></script>
                <script>const p=document.createElement("p"); p.textContent="CSS:"+getComputedStyle(document.body).color; document.body.append(p);</script>
                """.write(to: nestedEntry, atomically: true, encoding: .utf8)
                let nestedResult = try await page.loadLocal(
                    nestedEntry, executesScripts: true, readAccessRoot: projectRoot)
                guard nestedResult.text.contains("更新已呈现"), nestedResult.text.contains("CSS:rgb(32, 60, 54)"),
                    nestedResult.diagnostics.isEmpty
                else {
                    throw WebPageError.navigationFailed
                }
                evidence["nested-entry"] = "Nested entry loads sibling project scripts under explicit confined root."
                let exporter = WebPageContainer()
                exporter.setAvailable(true)
                let pdfBytes = try await exporter.exportLocalPDF(nestedEntry, readAccessRoot: projectRoot)
                guard let pdf = PDFDocument(data: pdfBytes), pdf.pageCount > 0,
                    pdf.string?.contains("更新已呈现") == true
                else { throw WebPageError.snapshotFailed }
                try pdfBytes.write(to: root.appendingPathComponent("writer-page.pdf"))
                let document = projectRoot.appendingPathComponent("document.html")
                let paragraphs = (1...140).map { "<p>Writer 文档测试 · 第 \($0) 段 · 可选择的文字</p>" }.joined()
                try ("<!doctype html><meta charset=utf-8><style>body{font:16px system-ui}</style>" + paragraphs).write(
                    to: document, atomically: true, encoding: .utf8)
                let documentBytes = try await exporter.exportLocalPDF(document, readAccessRoot: projectRoot)
                guard let pages = PDFDocument(data: documentBytes), pages.pageCount > 1,
                    pages.string?.contains("140") == true
                else { throw WebPageError.snapshotFailed }
                try documentBytes.write(to: root.appendingPathComponent("writer-document.pdf"))
                evidence["writer-pdf"] =
                    "HTML CSS JS exported; long Unicode document has \(pages.pageCount) selectable-text A4 pages."
                exporter.close()
                let windowA = UUID()
                let windowB = UUID()
                let first = try page.createSession(windowID: windowA)
                let second = try page.createSession(windowID: windowB)
                let local = root.appendingPathComponent("version-2/index.html").resolvingSymlinksInPath()
                _ = try await first.loadLocal(local, executesScripts: false)
                _ = try await second.loadLocal(local, executesScripts: true)
                try await Task.sleep(for: .milliseconds(300))
                let disabled = try await first.observe()
                let enabled = try await second.observe()
                guard disabled.text.contains("等待脚本"), !disabled.text.contains("更新已呈现"),
                    enabled.text.contains("更新已呈现")
                else { throw WebPageError.navigationFailed }
                page.removeSession(windowID: windowA)
                guard page.sessions[windowA] == nil, page.sessions[windowB] != nil else {
                    throw WebPageError.navigationFailed
                }
                evidence["writer-preview-isolation"] =
                    "Two independent pages; draft JavaScript disabled; checkpoint JavaScript enabled; closing one retains the other."
                page.closeSessions()
                let remote = try await page.loadRemote(URL(string: "https://example.com")!)
                evidence["remote-observed"] = remote.title + ": " + remote.text + "; " + remote.diagnostics
                guard remote.title == "Example Domain", !remote.text.isEmpty else {
                    throw WebPageError.navigationFailed
                }
                try await Task.sleep(for: .milliseconds(200))
                try await page.snapshot().write(to: root.appendingPathComponent("remote.jpg"))
                evidence["remote"] = remote.title + ": " + remote.text
                _ = try await page.loadLocal(
                    root.appendingPathComponent("version-2/index.html").resolvingSymlinksInPath())
                evidence["result"] = "passed"
                status = "WebKit 验证通过"
            } catch {
                evidence["result"] = "failed"
                evidence["error"] = String(describing: error)
                status = "验证失败：\(error)"
            }
            do {
                try JSONEncoder().encode(evidence).write(
                    to: root.appendingPathComponent("acceptance.json"), options: .atomic)
            } catch { status = "证据写入失败：\(error)" }
        }
    }
#endif

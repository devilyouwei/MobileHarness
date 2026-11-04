import Foundation
import FunctionContracts
import StorageFiles
import UI

#if canImport(WebKit)
    /// Per-project windows and bounded disposable render directories; no model or task lifetime ownership.
    @MainActor public final class ArtifactPresentation: WindowContentLifecycle {
        private let pages: WebPageContainer
        private let windows: WindowState
        private let disk: DiskFileStore
        private var bindings: [UUID: UUID] = [:]
        private var dismissed: Set<UUID> = []
        private var slots: [UUID: Int] = [:]
        private struct Latest {
            let title: String
            let entry: String
            let files: [String: String]
            let preview: Bool
        }
        private var latest: [UUID: Latest] = [:]
        private var rendering: Set<UUID> = []
        private var waiters: [UUID: [(UUID, CheckedContinuation<Void, any Error>)]] = [:]
        private func acquire(_ id: UUID) async throws {
            try Task.checkCancellation()
            if rendering.insert(id).inserted { return }
            guard (waiters[id]?.count ?? 0) < 2 else { throw WebPageError.busy }
            let token = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters[id, default: []].append((token, continuation))
                }
            } onCancel: {
                Task { @MainActor in
                    if let index = self.waiters[id]?.firstIndex(where: { $0.0 == token }) {
                        self.waiters[id]?.remove(at: index).1.resume(throwing: CancellationError())
                    }
                }
            }
            do { try Task.checkCancellation() } catch {
                release(id)
                throw error
            }
        }
        private func release(_ id: UUID) {
            if waiters[id]?.isEmpty == false {
                waiters[id]?.removeFirst().1.resume()
            } else {
                waiters.removeValue(forKey: id)
                rendering.remove(id)
            }
        }
        public init(pages: WebPageContainer, windows: WindowState, disk: DiskFileStore) {
            self.pages = pages
            self.windows = windows
            self.disk = disk
        }
        public func present(id: UUID, title: String, entry: String, files: [String: String], preview: Bool) async throws
            -> String
        {
            try await acquire(id)
            defer { release(id) }
            guard !dismissed.contains(id) else {
                return try report(
                    status: "unavailable", detail: "Window closed; draft retained. Visual verification unavailable.")
            }
            let window: UUID
            if let existing = bindings[id], windows.windows.contains(where: { $0.id == existing }) {
                window = existing
            } else {
                guard bindings.count < 4 else { throw WebPageError.busy }
                do {
                    window = try await windows.present(content: .artifact, title: title, icon: .emoji("📝"))
                } catch WindowError.interrupted {
                    dismissed.insert(id)
                    latest.removeValue(forKey: id)
                    return try report(
                        status: "unavailable", detail: "Window closed; draft retained. Visual verification unavailable."
                    )
                }
                bindings[id] = window
            }
            latest[id] = Latest(title: title, entry: entry, files: files, preview: preview)
            let page = try pages.createSession(windowID: window)
            guard try windows.find(window).mode != .minimized else {
                return try report(
                    status: "unavailable", detail: "Window minimized; draft retained. Visual verification unavailable.")
            }
            let slot = ((slots[id] ?? 0) + 1) % 2
            let prefix = "previews/" + id.uuidString + "/" + String(slot)
            try await disk.remove(prefix)
            var rendered = files
            if !entry.hasSuffix(".html") {
                rendered["index.html"] = ArtifactTextRendering.html(
                    files[entry] ?? "", markdown: entry.hasSuffix(".md"))
            } else if rendered[entry] == nil {
                rendered[entry] = "<!doctype html><meta charset=utf-8>"
            }
            for (path, content) in rendered {
                try ArtifactDraft.validatePath(path)
                try await disk.putIfAbsent(Data(("\u{feff}" + content).utf8), key: prefix + "/" + path)
            }
            let target = entry.hasSuffix(".html") ? entry : "index.html"
            let url = try await disk.fileURL(prefix + "/" + target, maximumBytes: Int.max)
            let observation: WebPageObservation
            do {
                var readRoot = url
                for _ in target.split(separator: "/") { readRoot.deleteLastPathComponent() }
                observation = try await page.loadLocal(
                    url, executesScripts: !preview && entry.hasSuffix(".html"), readAccessRoot: readRoot)
            } catch {
                if dismissed.contains(id) {
                    try await disk.remove("previews/" + id.uuidString)
                    return try report(
                        status: "unavailable", detail: "Window closed; draft retained. Visual verification unavailable."
                    )
                }
                throw error
            }
            slots[id] = slot
            return try report(
                status: preview ? "preview" : (observation.diagnostics.isEmpty ? "observed" : "errors"),
                detail: "", window: window.uuidString, text: observation.text, diagnostics: observation.diagnostics)
        }
        private func report(
            status: String, detail: String, window: String = "", text: String = "", diagnostics: String = ""
        ) throws -> String {
            String(
                decoding: try JSONEncoder().encode([
                    "status": status, "detail": detail, "windowID": window,
                    "text": String(text.prefix(1200)), "diagnostics": String(diagnostics.prefix(512)),
                ]), as: UTF8.self)
        }
        public func prepare(id: UUID, deleting: Bool) async throws {
            dismissed.remove(id)
            if deleting {
                latest.removeValue(forKey: id)
                try await disk.remove("previews/" + id.uuidString)
                if let window = bindings[id], windows.windows.contains(where: { $0.id == window }) {
                    try await windows.change(window, command: .close)
                    pages.removeSession(windowID: window)
                }
                bindings.removeValue(forKey: id)
                slots.removeValue(forKey: id)
            } else if let window = bindings[id], !windows.windows.contains(where: { $0.id == window }) {
                bindings.removeValue(forKey: id)
            } else if !deleting, let window = bindings[id], try windows.find(window).mode == .minimized {
                try await windows.change(window, command: .restore)
            }
        }
        public func snapshot(id: UUID) async throws -> Data? {
            guard let window = bindings[id], !dismissed.contains(id), let item = try? windows.find(window),
                item.mode != .minimized,
                let page = pages.sessions[window]
            else { return nil }
            do { return try await page.snapshot() } catch {
                if dismissed.contains(id) { return nil }
                throw error
            }
        }
        public func pauseWindow(invocation: any FunctionInput) async throws {}
        public func resumeWindow(invocation: any FunctionInput) async throws {
            guard let text = invocation.call.parameters["windowID"], let window = UUID(uuidString: text),
                let project = bindings.first(where: { $0.value == window })?.key, let value = latest[project]
            else { return }
            _ = try await present(
                id: project, title: value.title, entry: value.entry, files: value.files, preview: value.preview)
        }
        public func closeWindow(invocation: any FunctionInput) async throws {
            guard let text = invocation.call.parameters["windowID"], let window = UUID(uuidString: text) else { return }
            let projects = bindings.filter { $0.value == window }.map(\.key)
            for project in projects { dismissed.insert(project) }
            pages.removeSession(windowID: window)
            for project in projects {
                try await acquire(project)
                defer { release(project) }
                latest.removeValue(forKey: project)
                bindings.removeValue(forKey: project)
                slots.removeValue(forKey: project)
                try await disk.remove("previews/" + project.uuidString)
            }
        }
    }
#endif

/// Deterministic escaped rendering. Unsupported Markdown syntax remains readable source.
public enum ArtifactTextRendering {
    public static func html(_ text: String, markdown: Bool) -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func inline(_ value: String) -> String {
            // Match source tokens once, escaping every literal and link destination independently.
            let pattern = #"`([^`]+)`|\*\*([^*]+)\*\*|\*([^*]+)\*|\[([^\]]+)\]\(([^ )]+)\)"#
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return escape(value) }
            let source = value as NSString
            var result = ""
            var offset = 0
            for match in expression.matches(in: value, range: NSRange(location: 0, length: source.length)) {
                result += escape(
                    source.substring(with: NSRange(location: offset, length: match.range.location - offset)))
                if match.range(at: 1).location != NSNotFound {
                    result += "<code>" + escape(source.substring(with: match.range(at: 1))) + "</code>"
                } else if match.range(at: 2).location != NSNotFound {
                    result += "<strong>" + escape(source.substring(with: match.range(at: 2))) + "</strong>"
                } else if match.range(at: 3).location != NSNotFound {
                    result += "<em>" + escape(source.substring(with: match.range(at: 3))) + "</em>"
                } else {
                    let label = escape(source.substring(with: match.range(at: 4)))
                    let target = source.substring(with: match.range(at: 5))
                    if let url = URL(string: target), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                        url.host != nil
                    {
                        result += "<a href=\"" + escape(target) + "\" rel=\"noreferrer\">" + label + "</a>"
                    } else {
                        result += escape(source.substring(with: match.range))
                    }
                }
                offset = NSMaxRange(match.range)
            }
            result += escape(source.substring(from: offset))
            return result
        }
        var body = ""
        if !markdown {
            body = "<pre>" + escape(text) + "</pre>"
        } else {
            var fenced = false
            for line in text.components(separatedBy: "\n") {
                if line.hasPrefix("```") {
                    body += fenced ? "</code></pre>" : "<pre><code>"
                    fenced.toggle()
                } else if fenced {
                    body += escape(line) + "\n"
                } else if line.hasPrefix("#") {
                    let depth = min(6, line.prefix(while: { $0 == "#" }).count)
                    body +=
                        "<h\(depth)>" + inline(String(line.dropFirst(depth)).trimmingCharacters(in: .whitespaces))
                        + "</h\(depth)>"
                } else if line.hasPrefix("> ") {
                    body += "<blockquote>" + inline(String(line.dropFirst(2))) + "</blockquote>"
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    body += "<p>• " + inline(String(line.dropFirst(2))) + "</p>"
                } else {
                    if let dot = line.firstIndex(of: "."), !line[..<dot].isEmpty,
                        line[..<dot].allSatisfy(\.isNumber), line[line.index(after: dot)...].hasPrefix(" ")
                    {
                        body +=
                            "<p>" + escape(String(line[...dot])) + " " + inline(String(line[line.index(after: dot)...]))
                            + "</p>"
                    } else {
                        body += "<p>" + inline(line) + "</p>"
                    }
                }
            }
            if fenced { body += "</code></pre>" }
        }
        return
            "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><style>body{font:17px system-ui;padding:20px;color:#182034;background:#fff;line-height:1.6}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#f3f4f7;padding:12px;border-radius:10px}blockquote{border-left:3px solid #6878ac;padding-left:12px;margin-left:0}</style>"
            + body
    }
}

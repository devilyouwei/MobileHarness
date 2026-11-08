import Foundation
import FunctionContracts
import OSLog
import StorageCore
import StorageFiles
import UI

#if canImport(WebKit)
    /// Per-project windows and bounded disposable render directories; no model or task lifetime ownership.
    @MainActor public final class ArtifactPresentation: WindowContentLifecycle {
        private let pages: WebPageContainer
        private let windows: WindowState
        private let disk: DiskFileStore
        private var bindings: [WorkspaceID: UUID] = [:]
        private var dismissed: Set<WorkspaceID> = []
        private var pendingOpen: Set<WorkspaceID> = []
        private var slots: [WorkspaceID: Int] = [:]
        private struct Latest {
            var title: String
            var subtitle: String? = nil
            let entry: String
            let files: [String: String]
            let preview: Bool
        }
        private var latest: [WorkspaceID: Latest] = [:]
        private var sceneActive = true
        private var sceneRestore: Task<Void, Never>?
        private var restoreFailures: Set<WorkspaceID> = []
        private let log = Logger(subsystem: "dev.mobileharness", category: "ArtifactPresentation")
        private var serials: [WorkspaceID: Int] = [:]
        private var serial = 0
        public func describe(id: WorkspaceID, title: String?, subtitle: String?) {
            guard latest[id] != nil else { return }
            if let title { latest[id]?.title = title }
            if let subtitle { latest[id]?.subtitle = subtitle }
            refreshLabels()
        }
        private func refreshLabels() {
            let live = bindings.filter { pair in windows.windows.contains { $0.id == pair.value } }
            for (project, window) in live {
                guard let value = latest[project] else { continue }
                let peers = live.keys.filter { latest[$0]?.title == value.title }
                    .sorted { (serials[$0] ?? 0) < (serials[$1] ?? 0) }
                let suffix = peers.count > 1 ? " · " + String((peers.firstIndex(of: project) ?? 0) + 1) : ""
                windows.setPresentation(window, title: value.title + suffix, subtitle: value.subtitle)
            }
        }
        public func setSceneActive(_ active: Bool) async {
            if !active {
                sceneActive = false
                let previous = sceneRestore
                previous?.cancel()
                await previous?.value
                return
            }
            guard !sceneActive else { return }
            sceneActive = true
            let previous = sceneRestore
            sceneRestore = Task { [weak self] in
                await previous?.value
                await self?.restoreVisibleWindows()
            }
        }
        func waitForSceneRestoration() async { await sceneRestore?.value }

        private func restoreVisibleWindows() async {
            for (id, value) in Array(latest) where !dismissed.contains(id) {
                guard sceneActive, !Task.isCancelled else { return }
                do {
                    if pendingOpen.contains(id) { try await prepare(id: id, deleting: false) }
                    if let window = bindings[id], try windows.find(window).mode == .minimized { continue }
                    _ = try await present(
                        id: id, title: value.title, entry: value.entry, files: value.files, preview: value.preview,
                        restoring: true)
                } catch {
                    guard sceneActive, !Task.isCancelled else { return }
                    guard !dismissed.contains(id) else { continue }
                    let reason = String(describing: error)
                    log.error("Workspace preview restoration failed: \(reason, privacy: .private)")
                    if let window = bindings[id] {
                        restoreFailures.insert(id)
                        windows.report(window, message: "作品预览恢复失败（\(reason)）")
                    }
                }
            }
        }
        private var canRender: Bool { sceneActive && windows.available && pages.isAvailable }

        private var rendering: Set<WorkspaceID> = []
        private var waiters: [WorkspaceID: [(UUID, CheckedContinuation<Void, any Error>)]] = [:]
        private func acquire(_ id: WorkspaceID) async throws {
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
        private func release(_ id: WorkspaceID) {
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
        public func present(
            id: WorkspaceID, title: String, entry: String, files: [String: String], preview: Bool,
            restoring: Bool = false
        ) async throws
            -> String
        {
            try await acquire(id)
            defer { release(id) }
            guard !restoring || latest[id] != nil else {
                return try report(status: "unavailable", detail: "Window presentation retired.")
            }
            let current = restoring ? latest[id] : nil
            let title = current?.title ?? title
            let entry = current?.entry ?? entry
            let files = current?.files ?? files
            let preview = current?.preview ?? preview
            guard !dismissed.contains(id) else {
                return try report(
                    status: "unavailable", detail: "Window closed; draft retained. Visual verification unavailable.")
            }
            guard latest[id] != nil || latest.count < 4 else { throw WebPageError.busy }
            let subtitle = latest[id]?.subtitle
            latest[id] = Latest(title: title, subtitle: subtitle, entry: entry, files: files, preview: preview)
            guard canRender else {
                return try report(
                    status: "deferred", detail: "Scene hidden; files continue. Rendering deferred until foreground.")
            }
            let window: UUID
            var interrupted = false
            if let existing = bindings[id], windows.windows.contains(where: { $0.id == existing }) {
                window = existing
            } else {
                guard bindings.count < 4 else { throw WebPageError.busy }
                let reserved = UUID()
                bindings[id] = reserved
                serial += 1
                serials[id] = serial
                do {
                    window = try await windows.present(
                        content: .artifact, title: title, icon: .emoji("📝"), windowID: reserved)
                } catch {
                    let retained = windows.windows.contains { $0.id == reserved }
                    if !retained {
                        bindings.removeValue(forKey: id)
                        serials.removeValue(forKey: id)
                    }
                    try Task.checkCancellation()
                    if !canRender {
                        refreshLabels()
                        return try report(
                            status: "deferred", detail: "Scene hidden during window presentation; files retained.")
                    }
                    if dismissed.contains(id) {
                        return try report(status: "unavailable", detail: "Window closed; draft retained.")
                    }
                    guard error as? WindowError == .interrupted else {
                        latest.removeValue(forKey: id)
                        throw error
                    }
                    guard retained else {
                        return try report(status: "deferred", detail: "Window transition interrupted; draft retained.")
                    }
                    window = reserved
                    interrupted = true
                }
            }
            refreshLabels()
            let page = try pages.createSession(windowID: window, reference: windows.reference(for: window))
            guard try windows.find(window).mode != .minimized else {
                return try report(
                    status: "unavailable", detail: "Window minimized; draft retained. Visual verification unavailable.",
                    reason: "minimized")
            }
            let slot = ((slots[id] ?? 0) + 1) % 2
            let slotRoot = "previews/" + id.rawValue + "/" + String(slot)
            try await disk.remove(slotRoot)
            let prefix = slotRoot + "/" + UUID().uuidString
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
                // Stable project confinement, fresh resource URLs, and a retained native surface.
                readRoot.deleteLastPathComponent()
                readRoot.deleteLastPathComponent()
                if preview {
                    // Keep the document's file origin alive while rotating its resource snapshots.
                    let hostKey = "previews/" + id.rawValue + "/preview.html"
                    if try await disk.info(hostKey) == nil {
                        try await disk.putIfAbsent(
                            Data(
                                "<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'><body></body>"
                                    .utf8),
                            key: hostKey)
                    }
                    let host = try await disk.fileURL(hostKey, maximumBytes: Int.max)
                    observation = try await page.updateLocalPreview(
                        rendered[target] ?? "", entry: url, readAccessRoot: readRoot, documentEntry: host)
                } else {
                    observation = try await page.loadLocal(
                        url, executesScripts: entry.hasSuffix(".html"), readAccessRoot: readRoot,
                        preservingViewport: true)
                }
            } catch {
                try Task.checkCancellation()
                if !canRender {
                    return try report(
                        status: "deferred", detail: "Scene hidden during render; files retained.",
                        window: windows.reference(for: window) ?? "")
                }
                if dismissed.contains(id) {
                    try await disk.remove("previews/" + id.rawValue)
                    return try report(
                        status: "unavailable", detail: "Window closed; draft retained. Visual verification unavailable."
                    )
                }
                throw error
            }
            slots[id] = slot
            if restoreFailures.remove(id) != nil { windows.report(window, message: nil) }
            if interrupted {
                return try report(
                    status: "deferred", detail: "Window transition interrupted; entry content retained.",
                    window: windows.reference(for: window) ?? "")
            }
            return try report(
                status: preview ? "preview" : (observation.diagnostics.isEmpty ? "observed" : "errors"),
                detail: "", window: windows.reference(for: window) ?? "", text: observation.text,
                diagnostics: observation.diagnostics)
        }
        private func report(
            status: String, detail: String, window: String = "", text: String = "", diagnostics: String = "",
            reason: String = ""
        ) throws -> String {
            String(
                decoding: try JSONEncoder().encode([
                    "status": status, "detail": detail, "windowID": window, "reason": reason,
                    "text": String(text.prefix(1200)), "diagnostics": String(diagnostics.prefix(512)),
                ]), as: UTF8.self)
        }
        public func prepare(id: WorkspaceID, deleting: Bool) async throws {
            dismissed.remove(id)
            pendingOpen.remove(id)
            if deleting {
                latest.removeValue(forKey: id)
                restoreFailures.remove(id)
                try await disk.remove("previews/" + id.rawValue)
                if let window = bindings[id], windows.windows.contains(where: { $0.id == window }) {
                    try await windows.change(window, command: .close)
                    pages.removeSession(windowID: window)
                }
                bindings.removeValue(forKey: id)
                slots.removeValue(forKey: id)
                serials.removeValue(forKey: id)
                refreshLabels()
            } else if let window = bindings[id], !windows.windows.contains(where: { $0.id == window }) {
                bindings.removeValue(forKey: id)
            } else if let window = bindings[id] {
                if canRender {
                    if try windows.find(window).mode == .minimized {
                        try await windows.change(window, command: .restore)
                    }
                    try windows.focus(window)
                } else {
                    pendingOpen.insert(id)
                }
            }
        }
        public func snapshot(id: WorkspaceID) async throws -> Data? {
            try Task.checkCancellation()
            guard canRender else { return nil }
            guard let window = bindings[id], !dismissed.contains(id), let item = try? windows.find(window),
                item.mode != .minimized,
                let page = pages.sessions[window]
            else { return nil }
            do { return try await page.snapshot() } catch {
                if !canRender || dismissed.contains(id) || error as? WebPageError == .notVisible
                    || error as? WebPageError == .unavailable
                {
                    return nil
                }
                throw error
            }
        }
        public func pauseWindow(invocation: any FunctionInput) async throws {}
        public func resumeWindow(invocation: any FunctionInput) async throws {
            guard let text = invocation.call.parameters["windowID"], let window = try? windows.resolve(reference: text),
                let project = bindings.first(where: { $0.value == window })?.key, let value = latest[project]
            else { return }
            _ = try await present(
                id: project, title: value.title, entry: value.entry, files: value.files, preview: value.preview,
                restoring: true)
        }
        public func closeWindow(invocation: any FunctionInput) async throws {
            guard let text = invocation.call.parameters["windowID"], let window = try? windows.resolve(reference: text)
            else { return }
            let projects = bindings.filter { $0.value == window }.map(\.key)
            for project in projects {
                dismissed.insert(project)
                pendingOpen.remove(project)
            }
            pages.removeSession(windowID: window)
            for project in projects {
                try await acquire(project)
                defer { release(project) }
                latest.removeValue(forKey: project)
                restoreFailures.remove(project)
                bindings.removeValue(forKey: project)
                slots.removeValue(forKey: project)
                serials.removeValue(forKey: project)
                refreshLabels()
                try await disk.remove("previews/" + project.rawValue)
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

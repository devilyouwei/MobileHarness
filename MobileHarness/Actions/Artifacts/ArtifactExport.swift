import Foundation
import StorageFiles
import UI

/// Standard store-only ZIP with checked format widths, UTF-8 names, no shell or external dependency.
public enum ArtifactArchive {
    public static func zip(_ files: [String: String]) throws -> Data {
        guard files.count < UInt16.max else { throw ArtifactWorkspaceError.archiveFormatLimit }
        var archiveBytes: UInt64 = 22
        for (path, text) in files {
            guard path.utf8.count < UInt16.max, text.utf8.count < UInt32.max else {
                throw ArtifactWorkspaceError.archiveFormatLimit
            }
            archiveBytes += 76 + UInt64(path.utf8.count) * 2 + UInt64(text.utf8.count)
            guard archiveBytes < UInt32.max else { throw ArtifactWorkspaceError.archiveFormatLimit }
        }
        _ = try ArtifactDraft(files: files)
        var output = Data()
        var central = Data()
        func bytes(_ values: [(UInt32, Int)]) -> Data {
            Data(values.flatMap { value, count in (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } })
        }
        for (path, text) in files.sorted(by: { $0.key < $1.key }) {
            let name = Data(path.utf8)
            let body = Data(text.utf8)
            var crc: UInt32 = 0xffff_ffff
            for byte in body {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb8_8320) }
            }
            crc ^= 0xffff_ffff
            let offset = UInt32(output.count)
            let size = UInt32(body.count)
            let length = UInt32(name.count)
            output.append(
                bytes([
                    (0x0403_4b50, 4), (20, 2), (0x800, 2), (0, 2), (0, 2), (33, 2), (crc, 4), (size, 4), (size, 4),
                    (length, 2), (0, 2),
                ]))
            output.append(name)
            output.append(body)
            central.append(
                bytes([
                    (0x0201_4b50, 4), (20, 2), (20, 2), (0x800, 2), (0, 2), (0, 2), (33, 2), (crc, 4), (size, 4),
                    (size, 4), (length, 2), (0, 2), (0, 2), (0, 2), (0, 2), (0, 4), (offset, 4),
                ]))
            central.append(name)
        }
        let start = UInt32(output.count)
        output.append(central)
        output.append(
            bytes([
                (0x0605_4b50, 4), (0, 2), (0, 2), (UInt32(files.count), 2), (UInt32(files.count), 2),
                (UInt32(central.count), 4), (start, 4), (0, 2),
            ]))
        return output
    }
}

#if os(iOS)
    @MainActor public final class ArtifactExportService: WriterArtifactsControlling {
        private let workspace: ArtifactWorkspace
        private let disk: DiskFileStore
        private var worker: Task<URL, any Error>?
        private var prefix: String?
        private var closed = false
        private var prepared = false
        private var preparation: Task<Void, any Error>?
        private var previewPrefix: String?
        private var previewBusy = false
        private var previewWorker: Task<WriterFilePreview, any Error>?
        public init(workspace: ArtifactWorkspace, disk: DiskFileStore) {
            self.workspace = workspace
            self.disk = disk
        }
        public func read(_ id: String) async throws -> WriterArtifactSnapshot {
            guard !closed, let uuid = UUID(uuidString: id) else { throw ArtifactWorkspaceError.invalidPath }
            if let draft = try await workspace.checkpoint(for: uuid) {
                return .init(
                    item: .init(id: id, title: draft.title, state: "draft", entry: draft.entry),
                    files: draft.draft.files.sorted(by: { $0.key < $1.key }).map {
                        .init(path: $0.key, content: $0.value)
                    })
            }
            let project = try await workspace.project(uuid)
            return .init(
                item: .init(id: id, title: project.title, state: "published", entry: project.entry),
                files: project.files.sorted(by: { $0.key < $1.key }).map { .init(path: $0.key, content: $0.value) })
        }
        private func prepareExports() async throws {
            if prepared { return }
            if let preparation {
                try await preparation.value
                return
            }
            let work = Task { [disk] in try await disk.remove("exports") }
            preparation = work
            defer { preparation = nil }
            try await work.value
            prepared = true
        }
        public func preview(_ snapshot: WriterArtifactSnapshot, path: String) async throws -> WriterFilePreview {
            guard !closed, previewWorker == nil else { throw ArtifactWorkspaceError.busy }
            let work = Task { try await self.generatePreview(snapshot, path: path) }
            previewWorker = work
            defer { previewWorker = nil }
            return try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
        }
        private func generatePreview(_ snapshot: WriterArtifactSnapshot, path: String) async throws -> WriterFilePreview
        {
            guard !closed, !previewBusy, previewPrefix == nil else { throw ArtifactWorkspaceError.busy }
            previewBusy = true
            defer { previewBusy = false }
            guard Set(snapshot.files.map(\.path)).count == snapshot.files.count else {
                throw ArtifactWorkspaceError.invalidPath
            }
            _ = try ArtifactDraft(files: Dictionary(uniqueKeysWithValues: snapshot.files.map { ($0.path, $0.content) }))
            try await prepareExports()
            let prefix = "exports/preview-" + UUID().uuidString
            previewPrefix = prefix
            do {
                guard let selected = snapshot.files.first(where: { $0.path == path }) else {
                    throw ArtifactWorkspaceError.missingProject
                }
                for file in snapshot.files {
                    try ArtifactDraft.validatePath(file.path)
                    let content =
                        file.path.lowercased().hasSuffix(".html") && !file.content.hasPrefix("\u{feff}")
                        ? "\u{feff}" + file.content : file.content
                    try await disk.putIfAbsent(Data(content.utf8), key: prefix + "/" + file.path)
                }
                let ext = (path as NSString).pathExtension.lowercased()
                let entry: String
                if ext == "html" {
                    entry = path
                } else {
                    entry = "preview-" + UUID().uuidString + ".html"
                    let html =
                        ext == "svg"
                        ? "<!doctype html><meta charset=utf-8>" + selected.content
                        : ArtifactTextRendering.html(selected.content, markdown: ext == "md")
                    try await disk.putIfAbsent(Data(html.utf8), key: prefix + "/" + entry)
                }
                let url = try await disk.fileURL(prefix + "/" + entry, maximumBytes: Int.max)
                var root = url
                for _ in entry.split(separator: "/") { root.deleteLastPathComponent() }
                try Task.checkCancellation()
                return .init(url: url, root: root)
            } catch {
                let primary = error
                do {
                    try await disk.remove(prefix)
                    previewPrefix = nil
                } catch { throw BinaryPublicationError(publication: primary, cleanup: error) }
                throw primary
            }
        }
        public func closePreview() async throws {
            if let previewWorker {
                previewWorker.cancel()
                _ = await previewWorker.result
            }
            guard !previewBusy else { throw ArtifactWorkspaceError.busy }
            if let previewPrefix {
                try await disk.remove(previewPrefix)
                self.previewPrefix = nil
            }
        }
        public func export(_ snapshot: WriterArtifactSnapshot, path: String?, pdf: Bool) async throws -> URL {
            guard !closed, worker == nil, prefix == nil else { throw ArtifactWorkspaceError.busy }
            let location = "exports/" + UUID().uuidString
            prefix = location
            let task = Task { try await self.generate(snapshot, path: path, pdf: pdf, prefix: location) }
            worker = task
            do {
                let url = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                worker = nil
                try Task.checkCancellation()
                return url
            } catch {
                worker = nil
                let primary = error
                do { try await Task { try await self.discardExport() }.value } catch {
                    throw BinaryPublicationError(publication: primary, cleanup: error)
                }
                throw primary
            }
        }
        private func generate(_ snapshot: WriterArtifactSnapshot, path: String?, pdf: Bool, prefix: String) async throws
            -> URL
        {
            guard Set(snapshot.files.map(\.path)).count == snapshot.files.count else {
                throw ArtifactWorkspaceError.invalidPath
            }
            try await prepareExports()
            let files = Dictionary(uniqueKeysWithValues: snapshot.files.map { ($0.path, $0.content) })
            _ = try ArtifactDraft(files: files)
            let data: Data
            let name: String
            if let path {
                guard let source = files[path] else { throw ArtifactWorkspaceError.missingFile }
                try ArtifactDraft.validatePath(path)
                if pdf {
                    let ext = (path as NSString).pathExtension.lowercased()
                    guard ["html", "md", "txt", "svg", "css", "js", "json"].contains(ext) else {
                        throw ArtifactWorkspaceError.invalidPath
                    }
                    for (file, content) in files {
                        try Task.checkCancellation()
                        let rendering =
                            file.lowercased().hasSuffix(".html") && !content.hasPrefix("\u{feff}")
                            ? "\u{feff}" + content : content
                        try await disk.putIfAbsent(Data(rendering.utf8), key: prefix + "/source/" + file)
                    }
                    let entry: String
                    if ext == "html" {
                        entry = path
                    } else {
                        entry = "export-" + UUID().uuidString + ".html"
                        try await disk.putIfAbsent(
                            Data(
                                (ext == "svg"
                                    ? "<!doctype html><meta charset=utf-8>" + source
                                    : ArtifactTextRendering.html(source, markdown: ext == "md")).utf8),
                            key: prefix + "/source/" + entry)
                    }
                    let url = try await disk.fileURL(prefix + "/source/" + entry, maximumBytes: Int.max)
                    var root = url
                    for _ in entry.split(separator: "/") { root.deleteLastPathComponent() }
                    let page = WebPageContainer()
                    page.setAvailable(true)
                    defer { page.close() }
                    data = try await page.exportLocalPDF(url, readAccessRoot: root)
                    name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension + ".pdf"
                } else {
                    data = Data(source.utf8)
                    name = (path as NSString).lastPathComponent
                }
            } else {
                guard !pdf else { throw ArtifactWorkspaceError.invalidPath }
                data = try ArtifactArchive.zip(files)
                name = "Writer-project.zip"
            }
            try Task.checkCancellation()
            let key = prefix + "/" + name
            try await disk.putIfAbsent(data, key: key)
            return try await disk.fileURL(key, maximumBytes: Int.max)
        }
        public func discardExport() async throws {
            guard worker == nil else { throw ArtifactWorkspaceError.busy }
            if let prefix {
                try await disk.remove(prefix)
                self.prefix = nil
            }
        }
        public func shutdown() async throws {
            closed = true
            if let worker {
                worker.cancel()
                _ = await worker.result
            }
            worker = nil
            try await discardExport()
            try await closePreview()
        }
    }
#endif

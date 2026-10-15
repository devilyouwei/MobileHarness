import Compression
import CryptoKit
import Foundation
import Synchronization

/// Two active packages, eight pending; explicit user retries. Complete snapshots preserve outcomes.
public actor ModelArtifactStore {
    private struct Transfer {
        let generation: String
        let source: ModelDownloadSource
        var task: Task<Void, Never>?
    }
    private var fixtureDownload: (@Sendable (URL, URL, Int64) async throws -> URL)?
    private let downloader: (any ModelArtifactDownloader)?
    private final class ProgressMeter: Sendable { let value = Mutex<Double>(0) }
    private var hubProgress: [String: ProgressMeter] = [:]
    private let catalog: ModelArtifactCatalog
    private let storage: any ModelArtifactStorage
    private var transfers: [String: Transfer] = [:]
    private var queue: [String] = []
    private var phases: [String: ModelArtifactPhase] = [:]
    private var liveTransports: [String: ArtifactDownloadTransport] = [:]
    private var progress: [String: Int64] = [:]
    private var failures: [String: String] = [:]
    private var restored = false
    private var restoring: Task<[ModelArtifactTransferRecord], Error>?
    private var mutation = false
    private var deleting: Set<String> = []
    public init(
        catalog: ModelArtifactCatalog, storage: any ModelArtifactStorage,
        downloader: (any ModelArtifactDownloader)? = nil
    ) {
        self.downloader = downloader
        self.catalog = catalog
        self.storage = storage
    }
    @_spi(ModelAssembly) public init(
        catalog: ModelArtifactCatalog, storage: any ModelArtifactStorage,
        download: @escaping @Sendable (URL, URL, Int64) async throws -> URL
    ) {
        self.catalog = catalog
        self.storage = storage
        self.downloader = nil
        self.fixtureDownload = download
    }
    private func package(_ id: String) throws -> ModelArtifact {
        guard let value = catalog.packages.first(where: { $0.id == id }) else {
            throw ModelArtifactError.missingArtifact
        }
        return value
    }
    private func restore() async throws {
        guard !restored else { return }
        if restoring == nil {
            restoring = Task {
                let records = try await storage.restoreTransfers()
                guard records.count <= 10 else { throw ModelArtifactError.storage }
                return records
            }
        }
        guard let task = restoring else { throw ModelArtifactError.storage }
        let records = try await task.value
        guard !restored else { return }
        guard records.count <= 10, Set(records.map(\.id)).count == records.count else {
            throw ModelArtifactError.storage
        }
        for record in records {
            _ = try package(record.id)
            let source = try ModelDownloadSource(
                endpoint: record.source.endpoint, allowsCellular: record.source.allowsCellular)
            transfers[record.id] = Transfer(generation: record.generation, source: source)
            phases[record.id] = .queued
            queue.append(record.id)
        }
        restored = true
        restoring = nil
        startNext()
    }
    private func persist() async throws {
        let records = transfers.map {
            ModelArtifactTransferRecord(id: $0.key, generation: $0.value.generation, source: $0.value.source)
        }
        try await storage.saveTransfers(records)
    }
    public func snapshots() async throws -> [ModelArtifactSnapshot] {
        try await restore()
        var result: [ModelArtifactSnapshot] = []
        for artifact in catalog.packages {
            do {
                let installed = try await storage.installed(artifact)
                let recorded = phases[artifact.id]
                let phase: ModelArtifactPhase =
                    installed && transfers[artifact.id] == nil && !deleting.contains(artifact.id)
                    ? .installed
                    : (recorded == .installed && !installed
                        ? .failed : (recorded ?? (installed ? .installed : .notInstalled)))
                result.append(
                    ModelArtifactSnapshot(
                        artifact: artifact,
                        phase: phase,
                        completedBytes: (hubProgress[artifact.id].map {
                            Int64($0.value.withLock { $0 } * Double(artifact.downloadBytes))
                        } ?? progress[artifact.id] ?? 0) + (liveTransports[artifact.id]?.receivedBytes ?? 0),
                        installedBytes: installed ? try await storage.installedBytes(artifact) : nil,
                        failure: phase == .installed
                            ? (["transferIndex", "removal"].contains(failures[artifact.id] ?? "")
                                ? failures[artifact.id] : nil)
                            : failures[artifact.id] ?? (recorded == .installed && !installed ? "integrity" : nil)))
            } catch {
                // A malformed/older installation receipt must leave explicit deletion available.
                result.append(
                    ModelArtifactSnapshot(
                        artifact: artifact, phase: .failed, completedBytes: 0, installedBytes: nil,
                        failure: error is ModelArtifactError ? String(describing: error) : "integrity"))
            }
        }
        return result
    }
    public func download(_ id: String, source: ModelDownloadSource) async throws {
        try await restore()
        guard !mutation else { throw ModelArtifactError.busy }
        mutation = true
        defer { mutation = false }
        let artifact = try package(id)
        guard !deleting.contains(id) else { throw ModelArtifactError.busy }
        if let existing = transfers[id], existing.task != nil || phases[id] == .queued { return }
        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersion
        guard operatingSystem.majorVersion >= artifact.minimumOS else { throw ModelArtifactError.incompatible }
        #if targetEnvironment(simulator)
            guard !artifact.requiresPhysicalDevice else { throw ModelArtifactError.incompatible }
        #endif
        guard queue.count < 8 else { throw ModelArtifactError.busy }
        transfers[id] = Transfer(
            generation: transfers[id]?.generation ?? UUID().uuidString, source: source)
        phases[id] = .queued
        failures[id] = nil
        progress[id] = 0
        queue.append(id)
        do { try await persist() } catch {
            queue.removeAll { $0 == id }
            transfers[id] = nil
            phases[id] = .failed
            throw error
        }
        startNext()
    }
    private func startNext() {
        while transfers.values.filter({ $0.task != nil }).count < 2, !queue.isEmpty {
            let id = queue.removeFirst()
            guard let transfer = transfers[id] else { continue }
            transfers[id]?.task = Task { await self.run(id, generation: transfer.generation, source: transfer.source) }
        }
    }
    private func run(_ id: String, generation: String, source: ModelDownloadSource) async {
        do {
            let artifact = try package(id)
            if try await storage.installed(artifact) {
                phases[id] = .installed
                failures[id] = nil
                transfers[id] = nil
                await persistCompletion(id)
                startNext()
                return
            }
            let stage = try await storage.stage(artifact, task: generation)
            phases[id] = .downloading
            if artifact.source.kind == .huggingface {
                guard let downloader else { throw ModelArtifactError.invalidCatalog }
                let meter = ProgressMeter()
                hubProgress[id] = meter
                defer { hubProgress[id] = nil }
                try await downloader.download(artifact, source: source, into: stage) { fraction in
                    meter.value.withLock { $0 = max(0, min(1, fraction)) }
                }
                progress[id] = artifact.downloadBytes
            } else {
                guard let url = artifact.source.url else { throw ModelArtifactError.invalidCatalog }
                let transport = ArtifactDownloadTransport(
                    identifier: "dev.mobileharness.artifacts." + id, allowsCellular: source.allowsCellular)
                liveTransports[id] = transport
                defer {
                    transport.finishTransfers()
                    liveTransports[id] = nil
                }
                let temporary = try await fetch(
                    url, bytes: 64 * 1024 * 1024, hash: artifact.source.sha256,
                    transport: transport, stage: stage)
                phases[id] = .verifying
                try extractZIP(temporary, artifact: artifact, into: stage)
                try FileManager.default.removeItem(at: temporary)
                progress[id] = artifact.downloadBytes
            }
            try validateInstallation(artifact, at: stage)
            try Task.checkCancellation()
            guard transfers[id]?.generation == generation, !deleting.contains(id) else { throw CancellationError() }
            phases[id] = .verifying
            try await storage.publish(artifact, task: generation)
            phases[id] = .installed
            failures[id] = nil
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            phases[id] = cancelled ? .notInstalled : .failed
            let network = error as NSError
            failures[id] =
                cancelled
                ? nil : (network.domain == NSURLErrorDomain ? "network:\(network.code)" : String(describing: error))
            if cancelled || (try? package(id).source.kind) != .huggingface {
                try? await storage.discard(task: generation)
            }
        }
        if transfers[id]?.generation == generation {
            if phases[id] == .failed, (try? package(id).source.kind) == .huggingface {
                transfers[id]?.task = nil
            } else {
                transfers[id] = nil
            }
        }
        await persistCompletion(id)
        startNext()
    }
    private func persistCompletion(_ id: String) async {
        do { try await persist() } catch {
            // Files have already committed. Bookkeeping failure must not undo installation state.
            if phases[id] == .installed {
                failures[id] = "transferIndex"
            } else if failures[id] == nil {
                failures[id] = "transferIndex"
            }
        }
    }
    private func fetch(_ url: URL, bytes: Int64, hash: String?, transport: ArtifactDownloadTransport, stage: URL)
        async throws -> URL
    {
        let incoming = stage.appendingPathComponent(".incoming-" + (hash ?? UUID().uuidString))
        let file: URL
        if let fixtureDownload {
            file = try await fixtureDownload(url, incoming, bytes)
        } else {
            file = try await transport.download(url, to: incoming, maximumBytes: bytes)
        }
        do {
            try verify(file, maximumBytes: bytes, hash: hash)
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }
    private func verify(_ url: URL, maximumBytes: Int64, hash: String?) throws {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        guard let size, size.int64Value <= maximumBytes else { throw ModelArtifactError.integrity }
        guard let hash else { return }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            digest.update(data: data)
        }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == hash else {
            throw ModelArtifactError.integrity
        }
    }
    private func validateInstallation(_ artifact: ModelArtifact, at directory: URL) throws {
        let manager = FileManager.default
        guard
            let enumerator = manager.enumerator(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        else {
            throw ModelArtifactError.integrity
        }
        var count = 0
        var total: Int64 = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            count += 1
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard count <= 16384, values.isSymbolicLink != true else { throw ModelArtifactError.integrity }
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
            guard total <= 32 * 1024 * 1024 * 1024 else { throw ModelArtifactError.integrity }
        }
        for path in artifact.requiredFiles {
            let url = directory.appendingPathComponent(path)
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw ModelArtifactError.integrity
            }
        }
    }

    public func cancel(_ id: String) async throws {
        try await restore()
        _ = try package(id)
        guard transfers[id] != nil else { return }
        queue.removeAll { $0 == id }
        let generation = transfers[id]?.generation
        if let task = transfers[id]?.task {
            task.cancel()
            await task.value
        }
        if let generation { try await storage.discard(task: generation) }
        transfers[id] = nil
        phases[id] = .notInstalled
        failures[id] = nil
        progress[id] = 0
        try await persist()
    }

    public func cancelAll() async {
        queue.removeAll()
        let ids = Array(transfers.keys)
        for id in ids { try? await cancel(id) }
    }
    public func remove(_ id: String) async throws {
        let artifact = try package(id)
        guard deleting.insert(id).inserted else { throw ModelArtifactError.busy }
        defer { deleting.remove(id) }
        try await cancel(id)
        phases[id] = .deleting
        do {
            try await storage.remove(artifact)
            phases[id] = .notInstalled
            failures[id] = nil
            progress[id] = 0
        } catch {
            phases[id] = .failed
            failures[id] = "removal"
            throw error
        }
    }

    /// Small declared archives only. Central directory member list is authoritative, not filenames from remote headers.
    private func extractZIP(_ url: URL, artifact: ModelArtifact, into directory: URL) throws {
        let data = try Data(contentsOf: url)
        func number(_ offset: Int, _ length: Int) throws -> Int {
            guard offset >= 0, offset + length <= data.count else { throw ModelArtifactError.integrity }
            return (0..<length).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
        }
        guard data.count >= 22 else { throw ModelArtifactError.integrity }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try number(offset, 4) == 0x0605_4b50 {
                end = offset
                break
            }
        }
        guard let end, try number(end + 4, 2) == 0, try number(end + 6, 2) == 0 else {
            throw ModelArtifactError.unsupportedArchive
        }
        let count = try number(end + 10, 2)
        guard count <= 4096 else { throw ModelArtifactError.integrity }
        var cursor = try number(end + 16, 4)
        var seen: Set<String> = []
        var totalExpanded = 0
        for _ in 0..<count {
            guard try number(cursor, 4) == 0x0201_4b50 else { throw ModelArtifactError.integrity }
            let flags = try number(cursor + 8, 2)
            let method = try number(cursor + 10, 2)
            let compressed = try number(cursor + 20, 4)
            let expanded = try number(cursor + 24, 4)
            let nameLength = try number(cursor + 28, 2)
            let extraLength = try number(cursor + 30, 2)
            let commentLength = try number(cursor + 32, 2)
            let mode = try number(cursor + 38, 4) >> 16
            let local = try number(cursor + 42, 4)
            guard cursor + 46 + nameLength <= data.count,
                let name = String(data: data.subdata(in: cursor + 46..<cursor + 46 + nameLength), encoding: .utf8),
                flags & 1 == 0, mode & 0xf000 != 0xa000
            else { throw ModelArtifactError.integrity }
            cursor += 46 + nameLength + extraLength + commentLength
            if name.hasSuffix("/") {
                guard ModelArtifactCatalog.validPath(String(name.dropLast())) else {
                    throw ModelArtifactError.integrity
                }
                continue
            }
            totalExpanded += expanded
            guard ModelArtifactCatalog.validPath(name), seen.insert(name).inserted,
                expanded <= 64 * 1024 * 1024, totalExpanded <= 256 * 1024 * 1024,
                try number(local, 4) == 0x0403_4b50
            else { throw ModelArtifactError.integrity }
            let start = try local + 30 + number(local + 26, 2) + number(local + 28, 2)
            guard start >= 0, compressed >= 0, start + compressed <= data.count else {
                throw ModelArtifactError.integrity
            }
            let payload = data.subdata(in: start..<start + compressed)
            var result: Data
            if method == 0 {
                result = payload
            } else if method == 8 {
                if expanded == 0 {
                    result = Data()
                } else {
                    result = Data(count: expanded)
                    let written = result.withUnsafeMutableBytes { output in
                        payload.withUnsafeBytes { input -> Int in
                            guard let out = output.bindMemory(to: UInt8.self).baseAddress,
                                let source = input.bindMemory(to: UInt8.self).baseAddress
                            else { return 0 }
                            return compression_decode_buffer(out, expanded, source, compressed, nil, COMPRESSION_ZLIB)
                        }
                    }
                    guard written == expanded else { throw ModelArtifactError.integrity }
                }
            } else {
                throw ModelArtifactError.unsupportedArchive
            }
            let destination = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try result.write(to: destination)
            guard result.count == expanded else { throw ModelArtifactError.integrity }
        }
        guard Set(artifact.requiredFiles).isSubset(of: seen) else { throw ModelArtifactError.integrity }
    }
}

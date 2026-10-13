import Foundation

/// Durable, bounded JPEG evidence. Readers must own the exact producing source/session/input.
public actor CapturedPhotoStore {
    /// Caller-owned archive policy; validation occurs before the first file operation.
    public enum OverflowPolicy: Sendable { case reject, evictOldest }
    public struct Limits: Sendable {
        public let maximumPhotos: Int
        public let maximumBytes: Int
        public let maximumIndexBytes: Int
        public let overflowPolicy: OverflowPolicy
        public init(
            maximumPhotos: Int = 32, maximumBytes: Int = 128 * 1024 * 1024, maximumIndexBytes: Int = 16384,
            overflowPolicy: OverflowPolicy = .reject
        ) {
            self.maximumPhotos = maximumPhotos
            self.maximumBytes = maximumBytes
            self.maximumIndexBytes = maximumIndexBytes
            self.overflowPolicy = overflowPolicy
        }
    }
    private struct Entry: Codable {
        let id: UUID
        let source: String
        let session: UUID
        let input: UUID
        let bytes: Int
    }
    private let root: URL
    private let limits: Limits
    private var entries: [Entry]?
    public init(root: URL, limits: Limits = Limits()) {
        self.root = root
        self.limits = limits
    }
    private func load() throws -> [Entry] {
        guard root.isFileURL, (1...8192).contains(limits.maximumPhotos),
            limits.maximumBytes > 0, limits.maximumBytes <= 32 * 1024 * 1024 * 1024,
            (1024...4 * 1024 * 1024).contains(limits.maximumIndexBytes)
        else { throw FileStorageError.invalidFile }
        if let entries { return entries }
        let index = root.appendingPathComponent("index.json")
        var loaded: [Entry]
        if FileManager.default.fileExists(atPath: index.path) {
            let file = try FileHandle(forReadingFrom: index)
            defer { try? file.close() }
            let readLimit = limits.overflowPolicy == .evictOldest ? 4 * 1024 * 1024 : limits.maximumIndexBytes
            let data = try file.read(upToCount: readLimit + 1) ?? Data()
            guard data.count <= readLimit else { throw FileStorageError.capacityExceeded }
            loaded = try JSONDecoder().decode([Entry].self, from: data)
            guard loaded.count <= 8192 else { throw FileStorageError.invalidFile }
            guard Set(loaded.map(\.id)).count == loaded.count,
                loaded.allSatisfy({ $0.bytes > 0 && $0.bytes <= 4 * 1024 * 1024 })
            else { throw FileStorageError.invalidFile }
            if limits.overflowPolicy == .evictOldest {
                let originalCount = loaded.count
                try trimOldest(&loaded)
                if loaded.count != originalCount { try writeIndex(JSONEncoder().encode(loaded)) }
            } else if loaded.count > limits.maximumPhotos || loaded.reduce(0, { $0 + $1.bytes }) > limits.maximumBytes {
                throw FileStorageError.capacityExceeded
            }
        } else {
            loaded = []
        }
        if limits.overflowPolicy == .evictOldest { try cleanRetiredFiles(keeping: loaded) }
        entries = loaded
        return loaded
    }
    public func save(_ data: Data, owner: StorageOwner) throws -> UUID {
        guard owner.namespace == "photos", !owner.source.isEmpty, owner.source.utf8.count <= 64 else {
            throw FileStorageError.invalidFile
        }
        var current = try load()
        guard !data.isEmpty, data.count <= 4 * 1024 * 1024, data.count <= limits.maximumBytes else {
            throw FileStorageError.capacityExceeded
        }
        if limits.overflowPolicy == .reject {
            guard current.count < limits.maximumPhotos,
                data.count <= limits.maximumBytes - current.reduce(0, { $0 + $1.bytes })
            else { throw FileStorageError.capacityExceeded }
        }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let id = UUID()
        current.append(
            .init(id: id, source: owner.source, session: owner.session, input: owner.input, bytes: data.count))
        if limits.overflowPolicy == .evictOldest { try trimOldest(&current) }
        let index = try JSONEncoder().encode(current)
        guard index.count <= limits.maximumIndexBytes else { throw FileStorageError.capacityExceeded }
        let photo = root.appendingPathComponent(id.uuidString + ".jpg")
        #if os(iOS)
            try data.write(to: photo, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
            try data.write(to: photo, options: .atomic)
        #endif
        do {
            try writeIndex(index)
        } catch {
            try FileManager.default.removeItem(at: photo)
            throw error
        }
        entries = current
        if limits.overflowPolicy == .evictOldest {
            do { try cleanRetiredFiles(keeping: current) } catch {
                entries = nil
                throw error
            }
        }
        return id
    }
    private func trimOldest(_ current: inout [Entry]) throws {
        let encodedSizes = try current.map { try JSONEncoder().encode($0).count }
        var bytes = current.reduce(0) { $0 + $1.bytes }
        var indexBytes = 2 + max(0, current.count - 1) + encodedSizes.reduce(0, +)
        var retired = 0
        while current.count - retired > limits.maximumPhotos || bytes > limits.maximumBytes
            || indexBytes > limits.maximumIndexBytes
        {
            guard current.count - retired > 1 else { throw FileStorageError.capacityExceeded }
            bytes -= current[retired].bytes
            indexBytes -= encodedSizes[retired] + 1
            retired += 1
        }
        current.removeFirst(retired)
    }
    private func writeIndex(_ data: Data) throws {
        #if os(iOS)
            try data.write(
                to: root.appendingPathComponent("index.json"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
            try data.write(to: root.appendingPathComponent("index.json"), options: .atomic)
        #endif
    }
    /// Index commits first; orphan/retired cleanup can safely retry after interruption or restart.
    private func cleanRetiredFiles(keeping current: [Entry]) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let retained = Set(current.map(\.id))
        for file in try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isRegularFileKey])
        {
            guard file.pathExtension == "jpg",
                let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                !retained.contains(id), try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            else { continue }
            try FileManager.default.removeItem(at: file)
        }
    }

    public func read(_ id: UUID, owner: StorageOwner) throws -> Data {
        guard owner.namespace == "photos", let entry = try load().first(where: { $0.id == id }),
            entry.source == owner.source,
            entry.session == owner.session, entry.input == owner.input
        else { throw FileStorageError.invalidFile }
        return try readBytes(entry)
    }

    /// Read a durable reference after its producing live session has ended.
    public func readForInput(_ id: UUID, source: String, input: UUID) throws -> Data? {
        guard let entry = try load().first(where: { $0.id == id }) else { return nil }
        guard entry.source == source, entry.input == input else { throw FileStorageError.invalidFile }
        let url = root.appendingPathComponent(id.uuidString + ".jpg")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try readBytes(entry)
    }

    private func readBytes(_ entry: Entry) throws -> Data {
        let file = try FileHandle(forReadingFrom: root.appendingPathComponent(entry.id.uuidString + ".jpg"))
        defer { try? file.close() }
        let data = try file.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
        guard data.count == entry.bytes else { throw FileStorageError.invalidFile }
        return data
    }
}

import Foundation

/// Durable, bounded JPEG evidence. Readers must own the exact producing source/session/input.
public actor CapturedPhotoStore {
    private struct Entry: Codable {
        let id: UUID
        let source: String
        let session: UUID
        let input: UUID
        let bytes: Int
    }
    private let root: URL
    private var entries: [Entry]?
    public init(root: URL) { self.root = root }
    private func load() throws -> [Entry] {
        if let entries { return entries }
        let index = root.appendingPathComponent("index.json")
        let loaded: [Entry]
        if FileManager.default.fileExists(atPath: index.path) {
            let file = try FileHandle(forReadingFrom: index)
            defer { try? file.close() }
            let data = try file.read(upToCount: 16_385) ?? Data()
            guard data.count <= 16_384 else { throw FileStorageError.capacityExceeded }
            loaded = try JSONDecoder().decode([Entry].self, from: data)
            guard loaded.count <= 32, Set(loaded.map(\.id)).count == loaded.count,
                loaded.allSatisfy({ $0.bytes > 0 && $0.bytes <= 4 * 1024 * 1024 })
            else { throw FileStorageError.invalidFile }
        } else {
            loaded = []
        }
        entries = loaded
        return loaded
    }
    public func save(_ data: Data, owner: StorageOwner) throws -> UUID {
        guard owner.namespace == "photos", !owner.source.isEmpty, owner.source.utf8.count <= 64 else {
            throw FileStorageError.invalidFile
        }
        var current = try load()
        guard !data.isEmpty, data.count <= 4 * 1024 * 1024, current.count < 32,
            current.reduce(0, { $0 + $1.bytes }) + data.count <= 128 * 1024 * 1024
        else { throw FileStorageError.capacityExceeded }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let id = UUID()
        let photo = root.appendingPathComponent(id.uuidString + ".jpg")
        #if os(iOS)
            try data.write(to: photo, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
            try data.write(to: photo, options: .atomic)
        #endif
        current.append(
            .init(id: id, source: owner.source, session: owner.session, input: owner.input, bytes: data.count))
        do {
            let index = try JSONEncoder().encode(current)
            #if os(iOS)
                try index.write(
                    to: root.appendingPathComponent("index.json"),
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
                try index.write(to: root.appendingPathComponent("index.json"), options: .atomic)
            #endif
        } catch {
            try FileManager.default.removeItem(at: photo)
            throw error
        }
        entries = current
        return id
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

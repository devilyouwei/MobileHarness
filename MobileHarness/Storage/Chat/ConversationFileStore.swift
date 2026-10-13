import Foundation
import Storage

public struct ConversationFileSnapshot: Codable, Sendable {
    public let version: Int
    public var conversation: StoredConversation
    public var recovery: Data?
    public var revision: UInt64
    public init(conversation: StoredConversation, recovery: Data? = nil, revision: UInt64 = 0) {
        version = 3
        self.conversation = conversation
        self.recovery = recovery
        self.revision = revision
    }
    private enum CodingKeys: String, CodingKey { case version, conversation, recovery, revision, textPool }
    public func encode(to encoder: any Encoder) throws {
        var pool: [String] = []
        var indices: [String: Int] = [:]
        var expandedBytes = 0
        func intern(_ text: String) throws -> String {
            expandedBytes += text.utf8.count
            guard expandedBytes <= ConversationHistoryStore.maximumBytes else {
                throw DocumentStorageError.capacityExceeded
            }
            var ids: [String] = []
            var start = text.startIndex
            while start < text.endIndex {
                let end = text.index(start, offsetBy: 4096, limitedBy: text.endIndex) ?? text.endIndex
                let chunk = String(text[start..<end])
                let id: Int
                if let existing = indices[chunk] {
                    id = existing
                } else {
                    id = pool.count
                    indices[chunk] = id
                    pool.append(chunk)
                }
                ids.append(String(id))
                start = end
            }
            return ids.joined(separator: ",")
        }
        let packed = try transformTexts(conversation, using: intern)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(packed, forKey: .conversation)
        try container.encodeIfPresent(recovery, forKey: .recovery)
        try container.encode(revision, forKey: .revision)
        try container.encode(pool, forKey: .textPool)
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version == 3 else { throw DocumentStorageError.unsupportedVersion }
        let pool = try container.decode([String].self, forKey: .textPool)
        guard pool.count <= 65536 else { throw DocumentStorageError.capacityExceeded }
        var expandedBytes = 0
        conversation = try transformTexts(container.decode(StoredConversation.self, forKey: .conversation)) {
            reference in
            var text = ""
            for item in reference.split(separator: ",", omittingEmptySubsequences: false) where !item.isEmpty {
                guard let id = Int(item), pool.indices.contains(id) else { throw DocumentStorageError.invalidFile }
                expandedBytes += pool[id].utf8.count
                guard expandedBytes <= ConversationHistoryStore.maximumBytes,
                    text.utf8.count + pool[id].utf8.count <= 524288
                else { throw DocumentStorageError.capacityExceeded }
                text += pool[id]
            }
            return text
        }
        recovery = try container.decodeIfPresent(Data.self, forKey: .recovery)
        revision = try container.decode(UInt64.self, forKey: .revision)
    }
}

private func transformTexts(_ source: StoredConversation, using transform: (String) throws -> String) rethrows
    -> StoredConversation
{
    var value = source
    for index in value.turns.indices {
        let messages = value.turns[index].request
        value.turns[index].request = try messages.map { try .init(role: $0.role, content: transform($0.content)) }
        value.turns[index].toolDefinitions = try value.turns[index].toolDefinitions?.map(transform)
        for request in value.turns[index].modelRequests?.indices ?? 0..<0 {
            if let text = value.turns[index].modelRequests?[request].requestJSON {
                value.turns[index].modelRequests?[request].requestJSON = try transform(text)
            }
            if let text = value.turns[index].modelRequests?[request].decisionMetadata?.catalogJSON {
                value.turns[index].modelRequests?[request].decisionMetadata?.catalogJSON = try transform(text)
            }
        }
    }
    return value

}

/// File mechanics only. The owning Agent selects checkpoint and recovery policy.
public actor ConversationFileStore {
    private struct Index: Codable, Sendable {
        let version: Int
        var conversations: [StoredConversation]
    }
    private struct Rotation: Codable, Sendable {
        let version: Int
        let archivedID: UUID
        let next: StoredConversation
    }
    private let directory: URL
    private let current: LocalDocumentStore<ConversationFileSnapshot>
    private let index: LocalDocumentStore<Index>
    private let rotation: LocalDocumentStore<Rotation>
    private let maximumBytes: Int
    private var prepared = false
    public private(set) var checkpointCount = 0
    public init(directory: URL, maximumBytes: Int = ConversationHistoryStore.maximumBytes) throws {
        guard directory.isFileURL else { throw DocumentStorageError.invalidConfiguration }
        self.directory = directory
        self.maximumBytes = maximumBytes
        current = try LocalDocumentStore(
            url: directory.appendingPathComponent("current.json"), maximumBytes: maximumBytes,
            protection: .afterFirstUnlock)
        index = try LocalDocumentStore(
            url: directory.appendingPathComponent("index.json"), maximumBytes: 1_048_576, protection: .afterFirstUnlock)
        rotation = try LocalDocumentStore(
            url: directory.appendingPathComponent("rotation.json"), maximumBytes: 4096, protection: .afterFirstUnlock)
    }
    private func archiveURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("conversation-\(id.uuidString).json")
    }
    private func archive(_ id: UUID) throws -> LocalDocumentStore<ConversationFileSnapshot> {
        try LocalDocumentStore(url: archiveURL(id), maximumBytes: maximumBytes, protection: .afterFirstUnlock)
    }
    private func valid(_ snapshot: ConversationFileSnapshot) throws {
        guard snapshot.version == 3 else { throw DocumentStorageError.unsupportedVersion }
        try snapshot.conversation.validateCompressions()
    }
    private func metadata(_ conversation: StoredConversation) -> StoredConversation {
        var result = conversation
        result.turnCount = conversation.turns.count
        result.latestUser = conversation.turns.last.map { String($0.user.prefix(80)) }
        result.inputIDs = conversation.turns.map(\.id)
        result.turns = []
        result.taskCompressions = []
        return result
    }
    private func readIndex() async throws -> Index {
        let value: Index
        if let saved = try await index.load()?.value {
            value = saved
        } else {
            let names: [URL]
            do {
                names = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                names = []
            }
            let candidates = names.filter {
                $0.lastPathComponent.hasPrefix("conversation-") && $0.pathExtension == "json"
            }
            guard candidates.count <= 64 else { throw ConversationHistoryError.capacityExceeded }
            var recovered: [StoredConversation] = []
            for url in candidates {
                let rawID = String(url.deletingPathExtension().lastPathComponent.dropFirst("conversation-".count))
                guard let id = UUID(uuidString: rawID), let saved = try await archive(id).load()?.value else {
                    throw DocumentStorageError.invalidFile
                }
                try valid(saved)
                guard saved.conversation.id == id else { throw DocumentStorageError.invalidFile }
                recovered.append(metadata(saved.conversation))
            }
            value = Index(
                version: 3,
                conversations: recovered.sorted { ($0.archivedAt ?? $0.createdAt) > ($1.archivedAt ?? $1.createdAt) })
            try await index.save(value, expecting: nil)
        }
        guard value.version == 3 else { throw DocumentStorageError.unsupportedVersion }
        guard value.conversations.count <= 64 else { throw ConversationHistoryError.capacityExceeded }
        return value
    }
    private func publishArchive(_ conversation: StoredConversation) async throws {
        var value = try await readIndex()
        value.conversations.removeAll { $0.id == conversation.id }
        value.conversations.append(metadata(conversation))
        value.conversations.sort { ($0.archivedAt ?? $0.createdAt) > ($1.archivedAt ?? $1.createdAt) }
        guard value.conversations.count <= 64 else { throw ConversationHistoryError.capacityExceeded }
        try await index.replace(value)
    }
    private func finishRotation(_ transaction: Rotation) async throws {
        guard transaction.version == 3 else { throw DocumentStorageError.unsupportedVersion }
        let archived = try archive(transaction.archivedID)
        if try await archived.load() == nil {
            guard let old = try await current.refresh()?.value, old.conversation.id == transaction.archivedID else {
                throw DocumentStorageError.invalidFile
            }
            try valid(old)
            guard old.conversation.archivedAt != nil else { throw DocumentStorageError.invalidFile }
            try FileManager.default.moveItem(
                at: directory.appendingPathComponent("current.json"), to: archiveURL(transaction.archivedID))
            await current.invalidate()
        }
        let old = try await archived.refresh()
        guard let old, old.value.conversation.id == transaction.archivedID else {
            throw DocumentStorageError.invalidFile
        }
        try valid(old.value)
        if let active = try await current.load()?.value {
            guard active.conversation.id == transaction.next.id else { throw DocumentStorageError.conflict }
            try valid(active)
        } else {
            try await current.save(.init(conversation: transaction.next), expecting: nil)
        }
        try await publishArchive(old.value.conversation)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("rotation.json"))
        await rotation.invalidate()
    }
    public func loadCurrent() async throws -> ConversationFileSnapshot? {
        if !prepared {
            _ = try await readIndex()
            if let pending = try await rotation.load()?.value { try await finishRotation(pending) }
            prepared = true
        }
        var value = try await current.load()?.value
        if let old = value, old.conversation.archivedAt != nil {
            let transaction = Rotation(version: 3, archivedID: old.conversation.id, next: StoredConversation())
            try await rotation.save(transaction, expecting: nil)
            try await finishRotation(transaction)
            value = try await current.load()?.value
        }
        if let value { try valid(value) }
        return value
    }
    public func currentExists() throws -> Bool {
        do {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent("current.json").path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw DocumentStorageError.invalidFile
            }
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return false
        }
    }
    public func saveCurrent(_ snapshot: ConversationFileSnapshot) async throws {
        _ = try await loadCurrent()
        try valid(snapshot)
        // replace atomically creates a missing current, without a check-then-overwrite race.
        try await current.replace(snapshot)
        checkpointCount += 1
    }
    public func list() async throws -> [StoredConversation] {
        _ = try await loadCurrent()
        return try await readIndex().conversations
    }
    public func read(_ id: UUID) async throws -> StoredConversation {
        _ = try await loadCurrent()
        guard try await readIndex().conversations.contains(where: { $0.id == id }) else {
            throw ConversationHistoryError.missingTurn
        }
        guard let saved = try await archive(id).load()?.value else { throw DocumentStorageError.invalidFile }
        try valid(saved)
        guard saved.conversation.id == id else { throw DocumentStorageError.invalidFile }
        return saved.conversation
    }
    public func rotate(_ snapshot: ConversationFileSnapshot, next: StoredConversation) async throws {
        _ = try await loadCurrent()
        guard try await readIndex().conversations.count < 64 else { throw ConversationHistoryError.capacityExceeded }
        try await saveCurrent(snapshot)
        let transaction = Rotation(version: 3, archivedID: snapshot.conversation.id, next: next)
        try await rotation.save(transaction, expecting: nil)
        try await finishRotation(transaction)
    }
    public func update(_ conversation: StoredConversation) async throws {
        let file = try archive(conversation.id)
        guard var saved = try await file.load()?.value else { throw DocumentStorageError.invalidFile }
        saved.conversation = conversation
        try valid(saved)
        try await file.replace(saved)
        try await publishArchive(conversation)
    }
    public func setTitle(_ title: String?, error: String?, for id: UUID) async throws {
        var conversation = try await read(id)
        conversation.summaryTitle = title
        conversation.titleError = error
        let file = try archive(id)
        guard var saved = try await file.load()?.value else { throw DocumentStorageError.invalidFile }
        saved.conversation = conversation
        try await file.replace(saved)
        try await publishArchive(conversation)
    }
    public func delete(_ id: UUID) async throws {
        _ = try await read(id)
        // Remove the index entry before the file: an interrupted deletion cannot expose a missing body.
        var value = try await readIndex()
        value.conversations.removeAll { $0.id == id }
        try await index.replace(value)
        try FileManager.default.removeItem(at: archiveURL(id))
    }
}

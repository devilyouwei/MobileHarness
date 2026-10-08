import Foundation
import Storage

public protocol ProviderCredentialStorage: Sendable {
    func legacy() throws -> Data?
    func removeLegacy() throws
    func key(id: String) throws -> Data?
    func insertKey(_ data: Data, id: String) throws
    func removeKey(id: String) throws
}

private struct UserSettingsDocument: Codable, Sendable {
    let version: Int
    let cloud: CloudRecord?

    struct CloudRecord: Codable, Sendable {
        let enabled: Bool
        let url: String
        let model: String
        let credentialID: String
    }
}

/// Business schema and credential migration; Storage owns document consistency.
public actor ProviderSettingsStore: ProviderSettingsPersistence {
    private var document: LocalDocumentStore<UserSettingsDocument>?
    private var snapshot: DocumentSnapshot<UserSettingsDocument>?
    private var loaded = false
    private var busy = false
    private let credentials: any ProviderCredentialStorage
    private let makeDocument: @Sendable () throws -> LocalDocumentStore<UserSettingsDocument>
    public init(credentials: any ProviderCredentialStorage, documentURL: URL? = nil) {
        self.credentials = credentials
        makeDocument = {
            if let documentURL { return try LocalDocumentStore<UserSettingsDocument>(url: documentURL) }
            let root = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            var directory = root.appendingPathComponent("MobileHarness/Settings", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var attributes = URLResourceValues()
            attributes.isExcludedFromBackup = true
            try directory.setResourceValues(attributes)
            return try LocalDocumentStore<UserSettingsDocument>(url: directory.appendingPathComponent("settings.json"))
        }
    }

    private func documents() throws -> LocalDocumentStore<UserSettingsDocument> {
        if let document { return document }
        let document = try makeDocument()
        self.document = document
        return document
    }

    public func load() async throws -> ProviderSettings? {
        guard !busy else { throw ProviderSettingsError.busy }
        busy = true
        defer { busy = false }
        do {
            snapshot = try await documents().refresh()
            if let snapshot {
                guard snapshot.value.version == 1 else { throw ProviderSettingsError.persistence }
                let value = try resolve(snapshot.value.cloud)
                loaded = true
                return value
            }
            let value = try credentials.legacy().map { try JSONDecoder().decode(ProviderSettings.self, from: $0) }
            loaded = true
            if let value {
                try await persist(value)
                // Remove the original only after the document and its credential can be read back.
                let verified = try await documents().refresh()
                guard let verified, try resolve(verified.value.cloud) == value else {
                    throw ProviderSettingsError.persistence
                }
                try credentials.removeLegacy()
            }
            return value
        } catch {
            loaded = false
            throw error
        }
    }

    public func save(_ value: ProviderSettings?) async throws {
        guard !busy else { throw ProviderSettingsError.busy }
        guard loaded else { throw ProviderSettingsError.persistence }
        busy = true
        defer { busy = false }
        try await persist(value)
    }

    private func persist(_ value: ProviderSettings?) async throws {
        let oldID = snapshot?.value.cloud?.credentialID
        let newID = UUID().uuidString
        if let value { try credentials.insertKey(Data(value.key.utf8), id: newID) }
        let record = value.map {
            UserSettingsDocument.CloudRecord(
                enabled: $0.enabled, url: $0.url, model: $0.model, credentialID: newID)
        }
        do {
            snapshot = try await documents().save(
                UserSettingsDocument(version: 1, cloud: record), expecting: snapshot?.revision)
        } catch {
            if value != nil { try? credentials.removeKey(id: newID) }
            throw error
        }
        // Cleanup is best-effort after commit. An interrupted cleanup may leave an unreferenced key.
        if let oldID { try? credentials.removeKey(id: oldID) }
    }

    private func resolve(_ record: UserSettingsDocument.CloudRecord?) throws -> ProviderSettings? {
        guard let record else { return nil }
        guard let data = try credentials.key(id: record.credentialID), let key = String(data: data, encoding: .utf8)
        else {
            throw ProviderSettingsError.persistence
        }
        return ProviderSettings(enabled: record.enabled, url: record.url, key: key, model: record.model)
    }

}

import Foundation
import ModelKitOpenAI
import Security
import Storage

/// Runtime configuration; credentials are persisted separately from the document.
struct CloudSettings: Codable, Equatable, Sendable {
    let enabled: Bool
    let url: String
    let key: String
    let model: String

    init(enabled: Bool, url: String, key: String, model: String) {
        self.enabled = enabled
        self.url = url
        self.key = key
        self.model = model
    }

    private enum CodingKeys: String, CodingKey { case enabled, url, key, model }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Existing records predate the switch and represent an enabled cloud configuration.
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        url = try values.decode(String.self, forKey: .url)
        key = try values.decode(String.self, forKey: .key)
        model = try values.decode(String.self, forKey: .model)
    }

    func configuration() throws -> OpenAIChatConfiguration? {
        guard enabled else { return nil }
        guard let endpoint = URL(string: url) else { throw CloudSettingsError.invalidURL }
        return try OpenAIChatConfiguration(baseURL: endpoint, apiKey: key, model: model)
    }
}

enum CloudSettingsError: Error {
    case invalidURL
    case keychain(OSStatus)
    case invalidSelection
    case persistence
    case busy
}

private struct LegacyCloudSettingsStore {
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.mobileharness.cloud-chat",
            kSecAttrAccount as String: "configuration",
        ]
    }
    func load() throws -> CloudSettings? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CloudSettingsError.keychain(status) }
        return try JSONDecoder().decode(CloudSettings.self, from: data)
    }
    func save(_ value: CloudSettings?) throws {
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CloudSettingsError.keychain(status)
            }
            return
        }
        let data = try JSONEncoder().encode(value)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let insert = query.merging(attributes) { _, new in new }
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw CloudSettingsError.keychain(added) }
        } else if status != errSecSuccess {
            throw CloudSettingsError.keychain(status)
        }
    }
}

private nonisolated struct UserSettingsDocument: Codable, Sendable {
    let version: Int
    let cloud: CloudRecord?

    struct CloudRecord: Codable, Sendable {
        let enabled: Bool
        let url: String
        let model: String
        let credentialID: String
    }
}

/// App owns schema, credential references and legacy migration; Storage owns file/cache consistency.
@MainActor
final class CloudSettingsStore {
    private var document: LocalDocumentStore<UserSettingsDocument>?
    private var snapshot: DocumentSnapshot<UserSettingsDocument>?
    private var loaded = false
    private var busy = false
    private let legacy = LegacyCloudSettingsStore()

    private func documents() throws -> LocalDocumentStore<UserSettingsDocument> {
        if let document { return document }
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        var directory = root.appendingPathComponent("MobileHarness/Settings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let document = try LocalDocumentStore<UserSettingsDocument>(
            url: directory.appendingPathComponent("settings.json"))
        self.document = document
        return document
    }

    func load() async throws -> CloudSettings? {
        guard !busy else { throw CloudSettingsError.busy }
        busy = true
        defer { busy = false }
        do {
            snapshot = try await documents().refresh()
            if let snapshot {
                guard snapshot.value.version == 1 else { throw CloudSettingsError.persistence }
                let value = try resolve(snapshot.value.cloud)
                loaded = true
                return value
            }
            let value = try legacy.load()
            loaded = true
            if let value {
                try await persist(value)
                // Remove the original only after the document and its credential can be read back.
                let verified = try await documents().refresh()
                guard let verified, try resolve(verified.value.cloud) == value else {
                    throw CloudSettingsError.persistence
                }
                try legacy.save(nil)
            }
            return value
        } catch {
            loaded = false
            throw error
        }
    }

    func save(_ value: CloudSettings?) async throws {
        guard !busy else { throw CloudSettingsError.busy }
        guard loaded else { throw CloudSettingsError.persistence }
        busy = true
        defer { busy = false }
        try await persist(value)
    }

    private func persist(_ value: CloudSettings?) async throws {
        let oldID = snapshot?.value.cloud?.credentialID
        let newID = UUID().uuidString
        if let value { try writeKey(value.key, id: newID) }
        let record = value.map {
            UserSettingsDocument.CloudRecord(
                enabled: $0.enabled, url: $0.url, model: $0.model, credentialID: newID)
        }
        do {
            snapshot = try await documents().save(
                UserSettingsDocument(version: 1, cloud: record), expecting: snapshot?.revision)
        } catch {
            if value != nil { SecItemDelete(keyQuery(newID) as CFDictionary) }
            throw error
        }
        // Cleanup is best-effort after commit. An interrupted cleanup may leave an unreferenced key.
        if let oldID { SecItemDelete(keyQuery(oldID) as CFDictionary) }
    }

    private func resolve(_ record: UserSettingsDocument.CloudRecord?) throws -> CloudSettings? {
        guard let record else { return nil }
        var query = keyQuery(record.credentialID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
            let key = String(data: data, encoding: .utf8)
        else {
            throw CloudSettingsError.keychain(status)
        }
        return CloudSettings(enabled: record.enabled, url: record.url, key: key, model: record.model)
    }

    private func keyQuery(_ id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.mobileharness.cloud-chat.keys",
            kSecAttrAccount as String: id,
        ]
    }

    private func writeKey(_ key: String, id: String) throws {
        var query = keyQuery(id)
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw CloudSettingsError.keychain(status) }
    }
}

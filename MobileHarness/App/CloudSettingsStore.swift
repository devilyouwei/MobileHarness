import Foundation
import ModelKitOpenAI
import Security

/// One atomic Keychain record keeps URL, key and selected model consistent across launches.
struct CloudSettings: Codable, Equatable {
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
}

struct CloudSettingsStore {
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

import Foundation
import FunctionContracts
import Security

/// Raw native credential access; reference replacement belongs to Actions.
nonisolated public struct SettingsCredentialAdapter: ProviderCredentialStorage {
    public init() {}
    public func key(id: String) throws -> Data? { try read(service: "dev.mobileharness.cloud-chat.keys", account: id) }
    public func removeKey(id: String) throws { try remove(service: "dev.mobileharness.cloud-chat.keys", account: id) }
    public func insertKey(_ data: Data, id: String) throws {
        var request = query(service: "dev.mobileharness.cloud-chat.keys", account: id)
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(request as CFDictionary, nil)
        guard status == errSecSuccess else { throw ProviderSettingsError.keychain(status) }
    }
    private func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
    private func read(service: String, account: String) throws -> Data? {
        var request = query(service: service, account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw ProviderSettingsError.keychain(status) }
        return data
    }
    private func remove(service: String, account: String) throws {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderSettingsError.keychain(status)
        }
    }
}

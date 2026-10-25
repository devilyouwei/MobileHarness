import Foundation

/// Private configuration value; decoding exists only for the legacy credential record.
public struct ProviderSettings: Decodable, Equatable, Sendable {
    public let providers: [ProviderSettings]
    public let name: String
    public let enabled: Bool
    public let url: String
    public let key: String
    public let model: String
    public init(
        enabled: Bool, url: String, key: String, model: String, providers: [ProviderSettings] = [], name: String = ""
    ) {
        self.name = name.isEmpty ? (URL(string: url)?.host ?? "Provider") : name
        self.providers = providers
        self.enabled = enabled
        self.url = url
        self.key = key
        self.model = model
    }
    private enum CodingKeys: String, CodingKey { case enabled, url, key, model, name }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Provider"
        providers = []
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        url = try values.decode(String.self, forKey: .url)
        key = try values.decode(String.self, forKey: .key)
        model = try values.decode(String.self, forKey: .model)
    }
}
/// Secret-bearing host values deliberately have no Codable conformance.
public struct ProviderDiscoveryConfiguration: Sendable {
    public let url: String
    public let key: String
    public init(url: String, key: String) {
        self.url = url
        self.key = key
    }
}
public enum ProviderPresentationOperation: Sendable { case restore, save, discovery }
@MainActor public protocol ProviderSettingsStaging: Sendable {
    func stageRestore(sessionID: String) throws -> String
    func stageSave(_ value: ProviderSettings, sessionID: String) throws -> String
    func take(_ requestID: String, sessionID: String) throws -> ProviderSettings
    func discard(_ requestID: String, sessionID: String)
}
public protocol ProviderDiscoveryStaging: Sendable {
    func stage(_ configuration: ProviderDiscoveryConfiguration, sessionID: String) async throws -> String
    func discard(_ requestID: String, sessionID: String) async
}
@MainActor public protocol ProviderPresentationRegistering: Sendable {
    func register(_ id: String, operation: ProviderPresentationOperation) throws
    func discard(_ id: String)
}

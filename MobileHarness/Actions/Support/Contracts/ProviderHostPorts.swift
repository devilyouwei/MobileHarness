import Foundation

/// Private in-process configuration; credentials never enter a Codable payload.
public struct ProviderSettings: Equatable, Sendable {
    public let id: String
    public let decisionProviderID: String?
    public let decisionModel: String
    public var decisionUsesLocal: Bool?
    public let writerProviderID: String?
    public let writerModel: String
    public let writerThinking: Bool
    public let providers: [ProviderSettings]
    public let name: String
    public let enabled: Bool
    public let url: String
    public let key: String
    public let model: String
    public init(
        enabled: Bool, url: String, key: String, model: String, providers: [ProviderSettings] = [], name: String = "",
        id: String? = nil, writerProviderID: String? = nil, writerModel: String = "", writerThinking: Bool = false,
        decisionProviderID: String? = nil, decisionModel: String = "", decisionUsesLocal: Bool? = nil
    ) {
        self.id = id ?? url
        self.decisionProviderID = decisionProviderID
        self.decisionModel = decisionModel
        self.decisionUsesLocal = decisionUsesLocal
        self.writerProviderID = writerProviderID
        self.writerModel = writerModel
        self.writerThinking = writerThinking
        self.name = name.isEmpty ? (URL(string: url)?.host ?? "Provider") : name
        self.providers = providers
        self.enabled = enabled
        self.url = url
        self.key = key
        self.model = model
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
public enum ProviderPresentationOperation: Sendable { case restore, save }
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

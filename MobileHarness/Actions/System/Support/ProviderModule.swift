import Foundation
import FunctionContracts

/// Secret-bearing host values deliberately have no Codable conformance.
public struct ProviderDiscoveryConfiguration: Sendable {
    public let url: String
    public let key: String
    public init(url: String, key: String) {
        self.url = url
        self.key = key
    }
}
public enum ProviderDiscoveryError: LocalizedError, Sendable, ActionExecutionFailureProviding {
    case unavailable, invalidConfiguration, invalidRequest, capacityExceeded, expired, invalidModels
    case httpStatus(Int)
    public var errorDescription: String? { executionFailureCode.rawValue }
    public var executionFailureCode: ActionExecutionFailureCode {
        switch self {
        case .unavailable: .init(rawValue: "provider.unavailable")
        case .invalidConfiguration: .init(rawValue: "provider.configuration")
        case .invalidRequest: .init(rawValue: "provider.request")
        case .capacityExceeded: .init(rawValue: "provider.capacity")
        case .expired: .init(rawValue: "provider.expired")
        case .invalidModels: .init(rawValue: "provider.models")
        case .httpStatus(let status): .init(rawValue: "provider.http.\((100...599).contains(status) ? status : 0)")
        }
    }
}
public protocol ProviderDiscoveryCapability: Sendable {
    func discoverModels(requestID: UUID, sessionID: UUID) async throws -> [String]
}
public enum ProviderModelList {
    // /models has no standard capability field. Exclude known non-chat families while
    // retaining opaque third-party deployment names; discovery is not a compatibility probe.
    public static func isLikelyChatModel(_ id: String) -> Bool {
        let name = id.lowercased()
        let excluded = [
            "embedding", "embed-", "rerank", "moderation", "whisper", "tts", "transcribe",
            "transcription", "realtime", "audio", "dall-e", "dalle", "image", "sora",
            "stable-diffusion", "flux", "video", "davinci", "babbage", "gpt-3.5-turbo-instruct",
            "deep-research", "computer-use", "codex",
        ]
        if excluded.contains(where: { name.contains($0) }) { return false }
        return !["o1-pro", "o3-pro", "gpt-5-pro", "gpt-5.2-pro", "gpt-5.4-pro", "gpt-5.5-pro"].contains {
            name == $0 || name.hasPrefix($0 + "-")
        }
    }

    public static func eligible(_ models: [String]) throws -> [String] {
        guard models.count <= 2048,
            models.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 512 })
        else { throw ProviderDiscoveryError.invalidModels }
        var seen: Set<String> = []
        return models.filter { isLikelyChatModel($0) && seen.insert($0).inserted }
    }

    public static func encoded(_ models: [String]) throws -> String {
        guard models.count <= 2048, Set(models).count == models.count,
            models.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 512 })
        else { throw ProviderDiscoveryError.invalidModels }
        let data = try JSONEncoder().encode(models)
        guard data.count <= 65_536 else { throw ProviderDiscoveryError.invalidModels }
        return String(decoding: data, as: UTF8.self)
    }
}
@ActionCatalog
public struct ProviderModule: CapabilityModule {
    private let provider: any ProviderDiscoveryCapability
    private let settings: any ProviderSettingsCapability
    public init(discovery: any ProviderDiscoveryCapability, settings: any ProviderSettingsCapability) {
        self.provider = discovery
        self.settings = settings
    }
    public var definitions: [ActionFunction] {
        [
            SystemActions.discoverModelsDefinition(completing: { [provider] in
                .value(try await SystemActions.discoverModels(invocation: $0, using: provider))
            }),
            SystemActions.readSettingsDefinition(completing: { [settings] in
                .value(try await SystemActions.readSettings(invocation: $0, using: settings))
            }),
            SystemActions.restoreSettingsDefinition(completing: { [settings] in
                .value(try await SystemActions.restoreSettings(invocation: $0, using: settings))
            }),
            SystemActions.saveSettingsDefinition(completing: { [settings] in
                .value(try await SystemActions.saveSettings(invocation: $0, using: settings))
            }),
        ]
    }
}

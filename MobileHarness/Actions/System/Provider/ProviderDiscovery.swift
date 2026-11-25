import Foundation
import FunctionContracts
import ModelKitOpenAI
import StorageCore

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
    func discoverModels(requestID: String, sessionID: String) async throws -> [String]
}
public enum ProviderModelList {
    public static func eligible(_ models: [String]) throws -> [String] {
        guard models.count <= 2048,
            models.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 512 })
        else { throw ProviderDiscoveryError.invalidModels }
        var seen: Set<String> = []
        return models.filter { OpenAIChatConfiguration.isLikelyChatModel($0) && seen.insert($0).inserted }
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

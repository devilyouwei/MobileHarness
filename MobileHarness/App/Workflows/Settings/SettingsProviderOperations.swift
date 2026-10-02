import Foundation
import UI

/// Narrow provider operations. Preparing validates first; applying occurs inside the save transaction.
@MainActor
public struct SettingsProviderOperations {
    public let initial: CloudSettingsDraft
    public let prepare: (CloudSettingsDraft?) throws -> @MainActor () async throws -> Void
    public let discover: (CloudSettingsDraft) async throws -> [String]
    public let errorMessage: (any Error) -> String?
    public init(
        initial: CloudSettingsDraft,
        prepare: @escaping (CloudSettingsDraft?) throws -> @MainActor () async throws -> Void,
        discover: @escaping (CloudSettingsDraft) async throws -> [String],
        errorMessage: @escaping (any Error) -> String?
    ) {
        self.initial = initial
        self.prepare = prepare
        self.discover = discover
        self.errorMessage = errorMessage
    }
}

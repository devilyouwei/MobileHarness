import Foundation
import UI

/// Form-facing operations are injected transports, never storage or provider application.
@MainActor
public struct SettingsProviderOperations {
    public let initial: CloudSettingsDraft
    public let restore: () async throws -> CloudSettingsDraft
    public let discover: (CloudSettingsDraft) async throws -> [String]
    public let save: (CloudSettingsDraft) async throws -> Void
    public let errorMessage: (any Error) -> String?
    public init(
        initial: CloudSettingsDraft,
        restore: @escaping () async throws -> CloudSettingsDraft,
        discover: @escaping (CloudSettingsDraft) async throws -> [String],
        save: @escaping (CloudSettingsDraft) async throws -> Void,
        errorMessage: @escaping (any Error) -> String?
    ) {
        self.initial = initial
        self.restore = restore
        self.discover = discover
        self.save = save
        self.errorMessage = errorMessage
    }
}

import Actions
import Foundation
import PlatformKit
import UI

/// Bounded form facade; provider transactions execute through injected Agent transport.
@available(iOS 27, macOS 27, *)
@MainActor
public final class ProviderSettingsClient: SettingsOperating {
    public let presentsResults: Bool
    private let provider: SettingsProviderOperations
    private var restoration: Task<CloudSettingsDraft, any Error>?
    private var restoreWaiters = 0
    private var saved: CloudSettingsDraft?
    private var changing = false
    private var needsRestore = true
    public init(provider: SettingsProviderOperations, presentsResults: Bool = false) {
        self.provider = provider
        self.presentsResults = presentsResults
    }
    public var modelName: String {
        guard let saved, saved.enabled else { return "Local Gemma 4 E2B" }
        return saved.model.isEmpty ? "Cloud default model" : saved.model
    }
    public func restore() async throws -> CloudSettingsDraft {
        guard !changing, restoreWaiters < 32 else { throw WorkflowMessage("配置正在读取或保存，请稍后重试") }
        if !needsRestore, let saved { return saved }
        restoreWaiters += 1
        defer { restoreWaiters -= 1 }
        if let restoration { return try await restoration.value }
        let task = Task {
            do {
                let value = try await self.provider.restore()
                self.saved = value
                self.needsRestore = false
                return value
            } catch {
                throw WorkflowMessage(
                    self.message(error), wasPresented: (error as? ProviderIntentFailure)?.presented == true)
            }
        }
        restoration = task
        defer { restoration = nil }
        return try await task.value
    }
    public func discover(_ draft: CloudSettingsDraft) async throws -> [String] {
        do { return try await provider.discover(draft) } catch {
            throw WorkflowMessage(message(error), wasPresented: (error as? ProviderIntentFailure)?.presented == true)
        }
    }
    public func save(_ draft: CloudSettingsDraft) async throws {
        guard !changing, restoration == nil else { throw WorkflowMessage("配置正在读取或保存，请稍后重试") }
        changing = true
        defer { changing = false }
        do {
            try await provider.save(draft)
            saved = draft
            needsRestore = false
        } catch {
            needsRestore = true
            throw WorkflowMessage(message(error), wasPresented: (error as? ProviderIntentFailure)?.presented == true)
        }
    }
    private func message(_ error: any Error) -> String {
        if let message = provider.errorMessage(error) { return message }
        if error is CancellationError { return "操作已取消" }
        return "无法连接服务，请检查 HTTPS URL、Key 和网络后重试"
    }
}
private struct WorkflowMessage: LocalizedError, SettingsFailurePresenting {
    let wasPresented: Bool
    let message: String
    init(_ message: String, wasPresented: Bool = false) {
        self.message = message
        self.wasPresented = wasPresented
    }
    var errorDescription: String? { message }
}

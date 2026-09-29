import Foundation
import ModelKitDefaults
import ModelKitOpenAI
import Storage
import UI

/// Application configuration transaction; form values live in UI.SettingsState.
@available(iOS 27, macOS 27, *)
@MainActor
public final class SettingsWorkflow: SettingsOperating {
    private let store = CloudSettingsStore()
    private let resources: URL
    private let beginChange: @MainActor () async -> Void
    private let endChange: @MainActor () -> Void
    private var restoration: Task<CloudSettingsDraft, any Error>?
    private var saved: CloudSettings?
    private var restored = false
    private var changing = false
    public static var initial: CloudSettingsDraft {
        .init(
            enabled: false, url: OpenAIChatConfiguration.defaultBaseURL, key: "",
            model: OpenAIChatConfiguration.defaultModel)
    }
    public init(
        resources: URL, beginChange: @escaping @MainActor () async -> Void, endChange: @escaping @MainActor () -> Void
    ) {
        self.resources = resources
        self.beginChange = beginChange
        self.endChange = endChange
    }
    public var modelName: String {
        guard let saved, saved.enabled else { return "Local Qwen3.5" }
        return saved.model.isEmpty ? "Cloud default model" : saved.model
    }
    public func restore() async throws -> CloudSettingsDraft {
        if restored { return draft(saved) }
        if let restoration { return try await restoration.value }
        let task = Task { try await self.restoreSaved() }
        restoration = task
        defer { restoration = nil }
        return try await task.value
    }
    private func restoreSaved() async throws -> CloudSettingsDraft {
        do {
            let value = try await store.load()
            try await ModelKitDefaults.configureChat(resources: resources, configuration: try value?.configuration())
            saved = value
            restored = true
            return draft(value)
        } catch { throw WorkflowMessage(Self.message(error)) }
    }
    private func draft(_ value: CloudSettings?) -> CloudSettingsDraft {
        guard let value else { return Self.initial }
        return .init(enabled: value.enabled, url: value.url, key: value.key, model: value.model)
    }
    public func discover(_ draft: CloudSettingsDraft) async throws -> [String] {
        do {
            let endpoint = try OpenAIChatConfiguration.endpoint(draft.url)
            return try await OpenAIChatConfiguration.models(baseURL: endpoint, apiKey: draft.key)
        } catch { throw WorkflowMessage(Self.message(error)) }
    }
    public func save(_ draft: CloudSettingsDraft) async throws {
        guard !changing else { throw WorkflowMessage(Self.message(CloudSettingsError.busy)) }
        changing = true
        defer { changing = false }
        do {
            if draft.enabled, draft.model.isEmpty { throw CloudSettingsError.invalidSelection }
            let value = CloudSettings(enabled: draft.enabled, url: draft.url, key: draft.key, model: draft.model)
            let configuration = try value.configuration()
            let previous = saved
            await beginChange()
            defer { endChange() }
            try await store.save(value)
            do {
                try await ModelKitDefaults.configureChat(resources: resources, configuration: configuration)
            } catch {
                do { try await store.save(previous) } catch { throw CloudSettingsError.persistence }
                throw error
            }
            saved = value
            restored = true
        } catch { throw WorkflowMessage(Self.message(error)) }
    }
    private static func message(_ error: any Error) -> String {
        if case OpenAIChatError.httpStatus(let status) = error {
            return status == 401 || status == 403 ? "Key 无效或没有访问权限，请检查后重试" : "服务返回错误（\(status)），请检查 URL 后重试"
        }
        if error is DocumentStorageError || error is CocoaError || error is DecodingError {
            return "本地配置读取或保存失败，可能已被修改，请重新启动后重试"
        }
        if case CloudSettingsError.persistence = error { return "配置持久化或回滚失败，请重新启动后检查配置" }
        if case CloudSettingsError.busy = error { return "配置正在读取或保存，请稍后重试" }
        if error is CloudSettingsError { return "无法保存配置，请检查地址、模型选择或设备钥匙串访问" }
        if error is CancellationError { return "操作已取消" }
        return "无法连接服务，请检查 HTTPS URL、Key 和网络后重试"
    }
}

private struct WorkflowMessage: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

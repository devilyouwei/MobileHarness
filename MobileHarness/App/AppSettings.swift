import Foundation
import ModelKitDefaults
import ModelKitOpenAI
import Observation
import Storage

@MainActor @Observable
final class AppSettings {
    var isEnabled = false {
        didSet {
            error = nil
            notice = nil
        }
    }
    var url = "" { didSet { if url != oldValue { invalidateModels() } } }
    var key = "" { didSet { if key != oldValue { invalidateModels() } } }
    var selectedModel = ""
    private(set) var models: [String] = []
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var error: String?
    private(set) var notice: String?
    private var discovery: Task<Void, Never>?
    private var revision = 0
    private var restored = false
    private var restoration: Task<Void, any Error>?
    private var saved: CloudSettings?
    private let store = CloudSettingsStore()
    private let resources = Bundle.main.bundleURL.appendingPathComponent("Models")

    var canLoad: Bool { !url.isEmpty && !key.isEmpty && !isLoading && !isSaving }
    var canSave: Bool {
        !isLoading && !isSaving && (!isEnabled || models.contains(selectedModel))
    }

    func restore() async throws {
        guard !restored else { return }
        if let restoration { return try await restoration.value }
        let task = Task { try await restoreSettings() }
        restoration = task
        defer { restoration = nil }
        try await task.value
    }

    private func restoreSettings() async throws {
        let value = try await store.load()
        saved = value
        isEnabled = value?.enabled ?? false
        url = value?.url ?? ""
        key = value?.key ?? ""
        selectedModel = value?.model ?? ""
        models = value.flatMap { $0.model.isEmpty ? nil : [$0.model] } ?? []
        try await ModelKitDefaults.configureChat(resources: resources, configuration: try value?.configuration())
        restored = true
    }

    func loadModels() {
        guard canLoad else { return }
        discovery?.cancel()
        revision += 1
        let current = revision
        let endpoint = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = key.trimmingCharacters(in: .whitespacesAndNewlines)
        isLoading = true
        error = nil
        notice = nil
        models = []
        selectedModel = ""
        discovery = Task { [weak self] in
            do {
                guard let address = URL(string: endpoint) else { throw CloudSettingsError.invalidURL }
                let result = try await OpenAIChatConfiguration.models(baseURL: address, apiKey: credential)
                try Task.checkCancellation()
                guard let self, self.revision == current else { return }
                self.models = result
                self.isLoading = false
                self.notice = result.isEmpty ? "此服务没有返回可用模型" : "请选择用于对话的模型"
            } catch {
                guard let self, self.revision == current else { return }
                self.isLoading = false
                self.error = Self.message(error)
            }
        }
    }

    func save(beginChange: () async -> Void, endChange: () -> Void) async -> Bool {
        guard canSave else { return false }
        isSaving = true
        error = nil
        notice = nil
        defer { isSaving = false }
        do {
            if isEnabled, !models.contains(selectedModel) { throw CloudSettingsError.invalidSelection }
            let value = CloudSettings(
                enabled: isEnabled,
                url: url.trimmingCharacters(in: .whitespacesAndNewlines),
                key: key.trimmingCharacters(in: .whitespacesAndNewlines), model: selectedModel)
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
            notice = !value.enabled ? "已切换为本地模型" : "已保存，云端模型立即生效"
            return true
        } catch {
            self.error = Self.message(error)
            return false
        }
    }

    func cancelDiscovery() {
        revision += 1
        discovery?.cancel()
        discovery = nil
        isLoading = false
    }

    private func invalidateModels() {
        cancelDiscovery()
        models = []
        selectedModel = ""
        error = nil
        notice = nil
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

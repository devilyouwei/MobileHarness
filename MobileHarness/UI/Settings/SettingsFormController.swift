import Foundation

/// Root-owned form state; business effects cross injected UI-owned operation ports.
@MainActor public final class SettingsFormController: SettingsControlling {
    public let state: any SettingsPresenting
    private let operations: any SettingsOperating
    private let defaultModel: String
    private var discovery: Task<Void, Never>?
    private var restored = false
    public init(state: any SettingsPresenting, operations: any SettingsOperating, defaultModel: String) {
        self.state = state
        self.operations = operations
        self.defaultModel = defaultModel
    }
    private var draft: CloudSettingsDraft {
        .init(
            enabled: state.isEnabled, url: state.url.trimmingCharacters(in: .whitespacesAndNewlines),
            key: state.key.trimmingCharacters(in: .whitespacesAndNewlines), model: state.selectedModel)
    }
    public func restore() async throws {
        guard !restored else { return }
        let value = try await operations.restore()
        // A coalesced restore must not overwrite edits after the first caller applied its result.
        guard !restored else { return }
        if !operations.presentsResults {
            state.present(.isEnabled(value.enabled))
            state.present(.url(value.url))
            state.present(.key(value.key))
            state.present(.selectedModel(value.model.isEmpty ? defaultModel : value.model))
            state.present(.models(value.model.isEmpty ? [] : [value.model]))
        }
        restored = true
    }
    public func loadModels() {
        guard state.canLoad else { return }
        cancelDiscovery()
        let current = state.revision
        let value = draft
        state.present(.isLoading(true))
        state.present(.error(nil))
        state.present(.notice(nil))
        state.present(.models([]))
        state.present(.selectedModel(defaultModel))
        discovery = Task { [weak self, operations] in
            do {
                let result = try await operations.discover(value)
                try Task.checkCancellation()
                guard let self, self.state.revision == current else { return }
                if !operations.presentsResults {
                    self.state.present(.models(result))
                    if !result.isEmpty && !result.contains(self.state.selectedModel) {
                        self.state.present(.selectedModel(""))
                    }
                    self.state.present(.isLoading(false))
                    self.state.present(.notice(result.isEmpty ? "此服务没有返回可识别的聊天模型" : "请选择用于对话的模型"))
                }
                self.state.present(.isLoading(false))
            } catch {
                guard let self, self.state.revision == current else { return }
                self.state.present(.isLoading(false))
                if (error as? any SettingsFailurePresenting)?.wasPresented != true {
                    self.state.present(.error(error.localizedDescription))
                }
            }
        }
    }
    public func save() async -> Bool {
        guard state.canSave else { return false }
        state.present(.isSaving(true))
        state.present(.error(nil))
        state.present(.notice(nil))
        defer { state.present(.isSaving(false)) }
        do {
            let value = draft
            try await operations.save(value)
            restored = true
            if !operations.presentsResults { state.present(.notice(value.enabled ? "已保存，云端模型立即生效" : "已切换为本地模型")) }
            return true
        } catch {
            if (error as? any SettingsFailurePresenting)?.wasPresented != true {
                self.state.present(.error(error.localizedDescription))
            }
            return false
        }
    }
    public func cancelDiscovery() {
        state.invalidateRevision()
        discovery?.cancel()
        discovery = nil
        state.present(.isLoading(false))
    }
    public func credentialsChanged() {
        cancelDiscovery()
        state.present(.models([]))
        state.present(.selectedModel(defaultModel))
        state.present(.error(nil))
        state.present(.notice(nil))
    }
}

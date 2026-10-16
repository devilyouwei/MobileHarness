import ActionBindings
import Foundation
import PlatformKit
import UI

/// Root-owned form admission; native effects cross injected Agent operations.
@MainActor public final class SettingsInteractionWorkflow: SettingsControlling {
    public let state: SettingsState
    private let operations: any SettingsOperating
    private let defaultModel: String
    private var discovery: Task<Void, Never>?
    private var restored = false
    public init(state: SettingsState, operations: any SettingsOperating, defaultModel: String) {
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
            state.isEnabled = value.enabled
            state.url = value.url
            state.key = value.key
            state.selectedModel = value.model.isEmpty ? defaultModel : value.model
            state.models = value.model.isEmpty ? [] : [value.model]
        }
        restored = true
    }
    public func loadModels() {
        guard state.canLoad else { return }
        cancelDiscovery()
        let current = state.revision
        let value = draft
        state.isLoading = true
        state.error = nil
        state.notice = nil
        state.models = []
        state.selectedModel = defaultModel
        discovery = Task { [weak self, operations] in
            do {
                let result = try await operations.discover(value)
                try Task.checkCancellation()
                guard let self, self.state.revision == current else { return }
                if !operations.presentsResults {
                    self.state.models = result
                    if !result.isEmpty && !result.contains(self.state.selectedModel) { self.state.selectedModel = "" }
                    self.state.isLoading = false
                    self.state.notice = result.isEmpty ? "此服务没有返回可识别的聊天模型" : "请选择用于对话的模型"
                }
                self.state.isLoading = false
            } catch {
                guard let self, self.state.revision == current else { return }
                self.state.isLoading = false
                if (error as? any SettingsFailurePresenting)?.wasPresented != true {
                    self.state.error = error.localizedDescription
                }
            }
        }
    }
    public func save() async -> Bool {
        guard state.canSave else { return false }
        state.isSaving = true
        state.error = nil
        state.notice = nil
        defer { state.isSaving = false }
        do {
            let value = draft
            try await operations.save(value)
            restored = true
            if !operations.presentsResults { state.notice = value.enabled ? "已保存，云端模型立即生效" : "已切换为本地模型" }
            return true
        } catch {
            if (error as? any SettingsFailurePresenting)?.wasPresented != true {
                self.state.error = error.localizedDescription
            }
            return false
        }
    }
    public func cancelDiscovery() {
        state.invalidateRevision()
        discovery?.cancel()
        discovery = nil
        state.isLoading = false
    }
    public func credentialsChanged() {
        cancelDiscovery()
        state.models = []
        state.selectedModel = defaultModel
        state.error = nil
        state.notice = nil
    }
}

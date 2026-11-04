import Foundation

/// Root-owned form state; business effects cross injected UI-owned operation ports.
@MainActor public final class SettingsFormController: SettingsControlling {
    public let state: any SettingsPresenting
    private let operations: any SettingsOperating
    private let defaultModel: String
    private var providerRequests: [String: UUID] = [:]
    private var restored = false
    private var stopped = false
    private var discoveries: [UUID: Task<Void, Never>] = [:]
    public init(state: any SettingsPresenting, operations: any SettingsOperating, defaultModel: String) {
        self.state = state
        self.operations = operations
        self.defaultModel = defaultModel
    }
    private var draft: CloudSettingsDraft {
        .init(
            enabled: state.isEnabled, url: state.url.trimmingCharacters(in: .whitespacesAndNewlines),
            key: state.key.trimmingCharacters(in: .whitespacesAndNewlines), model: state.selectedModel,
            providers: state.providers, writerProviderID: state.writerProviderID, writerModel: state.writerModel,
            writerThinking: state.writerThinking)
    }
    public func restore() async throws {
        guard !stopped else { throw CancellationError() }
        guard !restored else { return }
        let value = try await operations.restore()
        // A coalesced restore must not overwrite edits after the first caller applied its result.
        guard !restored else { return }
        if !operations.presentsResults {
            state.writerProviderID = value.writerProviderID
            state.writerModel = value.writerModel
            state.writerThinking = value.writerThinking
            state.providers =
                value.providers.isEmpty && value.enabled && !value.url.isEmpty
                ? [.init(enabled: false, url: value.url, key: value.key, model: value.model)] : value.providers
            state.present(.isEnabled(value.enabled))
            state.present(.url(value.url))
            state.present(.key(value.key))
            state.present(.selectedModel(value.model.isEmpty ? defaultModel : value.model))
        }
        restored = true
    }
    public func refreshModels() {
        var ids = Set<String>()
        if state.isEnabled, let provider = state.providers.first(where: { $0.url == state.url }) {
            ids.insert(provider.id)
        }
        if let id = state.writerProviderID { ids.insert(id) }
        for id in ids { loadModels(providerID: id) }
    }
    public func loadModels(providerID: String) {
        guard !stopped, !state.isSaving,
            let provider = state.providers.first(where: { $0.id == providerID })
        else { return }
        if let prior = providerRequests[providerID] { discoveries[prior]?.cancel() }
        guard discoveries.count < 32 else {
            state.modelErrors[providerID] = "同时处理的模型查询过多，请稍后重试"
            return
        }
        let id = UUID()
        providerRequests[providerID] = id
        state.loadingProviderIDs.insert(providerID)
        state.modelErrors[providerID] = nil
        state.present(.isLoading(true))
        let worker = Task { [weak self, operations] in
            defer {
                self?.discoveries[id] = nil
                if let self, self.providerRequests[providerID] == id {
                    self.providerRequests[providerID] = nil
                    self.state.loadingProviderIDs.remove(providerID)
                    self.state.present(.isLoading(!self.state.loadingProviderIDs.isEmpty))
                }
            }
            do {
                let result = try await operations.discover(provider)
                try Task.checkCancellation()
                guard let self, self.providerRequests[providerID] == id,
                    let current = self.state.providers.first(where: { $0.id == providerID }),
                    current.url == provider.url, current.key == provider.key
                else { return }
                self.state.modelCatalogs[providerID] = result
                if result.isEmpty { self.state.modelErrors[providerID] = "此服务没有返回可识别的聊天模型" }
            } catch {
                guard let self, !Task.isCancelled, self.providerRequests[providerID] == id,
                    let current = self.state.providers.first(where: { $0.id == providerID }),
                    current.url == provider.url, current.key == provider.key
                else { return }
                self.state.modelErrors[providerID] = error.localizedDescription
            }
        }
        discoveries[id] = worker
    }
    public func shutdown() async {
        stopped = true
        cancelDiscovery()
        let workers = Array(discoveries.values)
        for worker in workers { worker.cancel() }
        for worker in workers { await worker.value }
    }
    public func save() async -> Bool {
        guard !stopped, state.canSave else { return false }
        state.present(.isSaving(true))
        state.present(.error(nil))
        state.present(.notice(nil))
        defer { state.present(.isSaving(false)) }
        do {
            var value = draft
            if let index = value.providers.firstIndex(where: { $0.url == value.url }) {
                value.providers[index].key = value.key
                value.providers[index].model = value.model
            }
            try await operations.save(value)
            restored = true
            if !operations.presentsResults { state.present(.notice("已保存智能体大脑配置")) }
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
        for worker in discoveries.values { worker.cancel() }
        providerRequests.removeAll()
        state.loadingProviderIDs.removeAll()
        state.present(.isLoading(false))
    }
}

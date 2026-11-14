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
            writerThinking: state.writerThinking,
            decisionProviderID: state.decisionProviderID, decisionModel: state.decisionModel,
            decisionUsesLocal: state.decisionUsesLocal)
    }
    public func restore() async throws {
        guard !stopped else { throw CancellationError() }
        guard !restored else { return }
        let value = try await operations.restore()
        // A coalesced restore must not overwrite edits after the first caller applied its result.
        guard !restored else { return }
        if !operations.presentsResults {
            state.decisionProviderID = value.decisionProviderID
            state.decisionModel = value.decisionModel
            state.decisionUsesLocal = value.decisionUsesLocal
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
    /// Only a successful restore can establish that no cloud provider is configured.
    public var needsWelcome: Bool { restored && !stopped && state.providers.isEmpty }

    public func saveWelcomeProvider(url: String, key: String) async -> Bool {
        guard needsWelcome, !state.isSaving else { return false }
        do {
            var editor = ProviderEditorDraft(provider: nil, existing: state.providers)
            editor.url = url
            editor.key = key
            var provider = try editor.validated(existing: state.providers)
            guard !provider.key.isEmpty else { throw ProviderEditorError.missingKey }
            if let host = URL(string: provider.url)?.host, host.utf8.count <= 128 { provider.name = host }
            var value = draft
            value.providers = [provider]
            guard await save(value) else { return false }
            // Publish only after the existing configuration/credential transaction succeeds.
            guard !stopped, state.isPresentationAvailable else { return true }
            state.providers = value.providers
            state.invalidateRevision()
            return true
        } catch {
            state.present(.error(error.localizedDescription))
            return false
        }
    }

    public func refreshModels() {
        var ids = Set<String>()
        if state.isEnabled, let provider = state.providers.first(where: { $0.url == state.url }) {
            ids.insert(provider.id)
        }
        if let id = state.decisionProviderID { ids.insert(id) }
        if let id = state.writerProviderID { ids.insert(id) }
        for id in ids { loadModels(providerID: id) }
    }
    public func loadModels(providerID: String) {
        guard !stopped, !state.isSaving,
            let provider = state.providers.first(where: { $0.id == providerID })
        else { return }
        if let prior = providerRequests[providerID] { discoveries[prior]?.cancel() }
        guard discoveries.count < 32 else {
            state.modelErrors[providerID] = "Too many model lookups are running. Try again later."
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
                if result.isEmpty {
                    self.state.modelErrors[providerID] = "This service returned no recognizable chat models."
                }
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
        var value = draft
        if value.enabled, let index = value.providers.firstIndex(where: { $0.url == value.url }) {
            value.providers[index].key = value.key
            value.providers[index].model = value.model
        }
        return await save(value)
    }
    public func save(_ change: BrainSettingsChange) async -> Bool {
        guard restored, !stopped, !state.isSaving else { return false }
        let previous = draft
        var candidate = previous
        switch change {
        case .providers(let providers):
            candidate.providers = providers
            if candidate.enabled {
                let selectedID = previous.providers.first { $0.url == previous.url }?.id
                let selected = providers.first { $0.id == selectedID }
                Self.setAssistant(&candidate, provider: selected, model: selected == nil ? "" : previous.model)
            }
            if !providers.contains(where: { $0.id == candidate.writerProviderID }) {
                candidate.writerProviderID = nil
                candidate.writerModel = ""
            }
            if !providers.contains(where: { $0.id == candidate.decisionProviderID }) {
                candidate.decisionProviderID = nil
                candidate.decisionModel = ""
            }
        case .brain(let brain, let choice):
            let selected = previous.providers.first { $0.id == choice.providerID }
            let model = choice.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard choice.providerID == nil || (selected != nil && !model.isEmpty) else {
                state.present(.error("Select a saved provider and model."))
                return false
            }
            switch brain {
            case .assistant:
                guard choice.usesLocal || selected != nil else {
                    state.present(.error("Select a provider."))
                    return false
                }
                Self.setAssistant(
                    &candidate, provider: choice.usesLocal ? nil : selected, model: choice.usesLocal ? "" : model)
            case .writer:
                guard !choice.usesLocal else {
                    state.present(.error("This local model lacks the native tools Writer needs."))
                    return false
                }
                candidate.writerProviderID = selected?.id
                candidate.writerModel = selected == nil ? "" : model
                candidate.writerThinking = choice.writerThinking
            case .decision:
                candidate.decisionUsesLocal = choice.usesLocal
                candidate.decisionProviderID = selected?.id
                candidate.decisionModel = selected == nil ? "" : model
            }
        }
        guard await save(candidate) else { return false }
        guard !stopped, state.isPresentationAvailable else { return true }
        for provider in previous.providers {
            let current = candidate.providers.first { $0.id == provider.id }
            if provider.url != current?.url || provider.key != current?.key {
                state.modelCatalogs[provider.id] = nil
                state.modelErrors[provider.id] = nil
            }
        }
        _ = state.presentRestored(candidate, revision: state.revision)
        return true
    }
    private static func setAssistant(_ draft: inout CloudSettingsDraft, provider: CloudSettingsDraft?, model: String) {
        draft.enabled = provider != nil
        draft.url = provider?.url ?? ""
        draft.key = provider?.key ?? ""
        draft.model = model
    }
    private func save(_ value: CloudSettingsDraft) async -> Bool {
        state.present(.isSaving(true))
        state.present(.error(nil))
        state.present(.notice(nil))
        defer { state.present(.isSaving(false)) }
        do {
            try await operations.save(value)
            restored = true
            if !operations.presentsResults { state.present(.notice("Model settings saved")) }
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

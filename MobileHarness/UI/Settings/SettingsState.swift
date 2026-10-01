import Foundation
import Observation

public struct CloudSettingsDraft: Sendable, Equatable {
    public var enabled: Bool
    public var url: String
    public var key: String
    public var model: String
    public init(enabled: Bool, url: String, key: String, model: String) {
        self.enabled = enabled
        self.url = url
        self.key = key
        self.model = model
    }
}

@MainActor
public protocol SettingsOperating: AnyObject {
    func restore() async throws -> CloudSettingsDraft
    func discover(_ draft: CloudSettingsDraft) async throws -> [String]
    func save(_ draft: CloudSettingsDraft) async throws
}

/// Form editing and request presentation. Persistence and runtime switching are injected operations.
@MainActor @Observable
public final class SettingsState {
    public var isEnabled = false {
        didSet {
            error = nil
            notice = nil
        }
    }
    public var url: String { didSet { if oldValue != url { invalidateModels() } } }
    public var key = "" { didSet { if oldValue != key { invalidateModels() } } }
    public var selectedModel: String
    public private(set) var models: [String] = []
    public private(set) var isLoading = false
    public private(set) var isSaving = false
    public private(set) var error: String?
    public private(set) var notice: String?
    private let operations: any SettingsOperating
    private let defaultModel: String
    private var discovery: Task<Void, Never>?
    private var revision = 0
    private var restored = false

    public init(operations: any SettingsOperating, initial: CloudSettingsDraft) {
        self.operations = operations
        defaultModel = initial.model
        url = initial.url
        selectedModel = initial.model
        isEnabled = initial.enabled
        key = initial.key
    }
    public var canLoad: Bool { !isLoading && !isSaving }
    public var canSave: Bool { !isLoading && !isSaving && (!isEnabled || !selectedModel.isEmpty) }
    private var draft: CloudSettingsDraft {
        .init(
            enabled: isEnabled, url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            key: key.trimmingCharacters(in: .whitespacesAndNewlines), model: selectedModel)
    }
    public func restore() async throws {
        guard !restored else { return }
        let value = try await operations.restore()
        // A coalesced restore must not overwrite edits after the first caller applied its result.
        guard !restored else { return }
        isEnabled = value.enabled
        url = value.url
        key = value.key
        selectedModel = value.model.isEmpty ? defaultModel : value.model
        models = value.model.isEmpty ? [] : [value.model]
        restored = true
    }
    public func loadModels() {
        guard canLoad else { return }
        cancelDiscovery()
        let current = revision
        let value = draft
        isLoading = true
        error = nil
        notice = nil
        models = []
        selectedModel = defaultModel
        discovery = Task { [weak self, operations] in
            do {
                let result = try await operations.discover(value)
                try Task.checkCancellation()
                guard let self, self.revision == current else { return }
                self.models = result
                if !result.isEmpty && !result.contains(self.selectedModel) { self.selectedModel = "" }
                self.isLoading = false
                self.notice = result.isEmpty ? "此服务没有返回可识别的聊天模型" : "请选择用于对话的模型"
            } catch {
                guard let self, self.revision == current else { return }
                self.isLoading = false
                self.error = error.localizedDescription
            }
        }
    }
    public func save() async -> Bool {
        guard canSave else { return false }
        isSaving = true
        error = nil
        notice = nil
        defer { isSaving = false }
        do {
            let value = draft
            try await operations.save(value)
            restored = true
            notice = value.enabled ? "已保存，云端模型立即生效" : "已切换为本地模型"
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
    public func cancelDiscovery() {
        revision += 1
        discovery?.cancel()
        discovery = nil
        isLoading = false
    }
    private func invalidateModels() {
        cancelDiscovery()
        models = []
        selectedModel = defaultModel
        error = nil
        notice = nil
    }
}

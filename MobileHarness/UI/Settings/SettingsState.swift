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
    var presentsResults: Bool { get }
    func restore() async throws -> CloudSettingsDraft
    func discover(_ draft: CloudSettingsDraft) async throws -> [String]
    func save(_ draft: CloudSettingsDraft) async throws
}

@MainActor
public protocol SettingsControlling: AnyObject {
    func restore() async throws
    func loadModels()
    func save() async -> Bool
    func cancelDiscovery()
    func credentialsChanged()
}

/// Editable form values only. Execution and lifetime are supplied through SettingsControlling.
@MainActor @Observable
public final class SettingsState {
    public var isEnabled: Bool
    public var url: String { didSet { if oldValue != url { revision += 1 } } }
    public var key: String { didSet { if oldValue != key { revision += 1 } } }
    public var selectedModel: String
    public var models: [String] = []
    public var isLoading = false
    public var isSaving = false
    public var error: String?
    public var notice: String?
    public private(set) var revision: UInt64 = 0
    public init(initial: CloudSettingsDraft) {
        isEnabled = initial.enabled
        url = initial.url
        key = initial.key
        selectedModel = initial.model
    }
    public var canLoad: Bool { !isLoading && !isSaving }
    public var canSave: Bool { !isLoading && !isSaving && (!isEnabled || !selectedModel.isEmpty) }
    public func invalidateRevision() { revision += 1 }
}

extension SettingsOperating { public var presentsResults: Bool { false } }
public protocol SettingsFailurePresenting: Error { var wasPresented: Bool { get } }

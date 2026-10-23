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
@MainActor
@Observable
public final class SettingsState {
    @ObservationIgnored var presentationAdmission: UIPresentationAdmission?
    public var isPresentationAvailable: Bool { presentationAdmission.map { $0.started && !$0.stopped } ?? true }

    public internal(set) var isEnabled: Bool
    public internal(set) var url: String { didSet { if oldValue != url { revision += 1 } } }
    public internal(set) var key: String { didSet { if oldValue != key { revision += 1 } } }
    public internal(set) var selectedModel: String
    public internal(set) var models: [String] = []
    public internal(set) var isLoading = false
    public internal(set) var isSaving = false
    public internal(set) var error: String?
    public internal(set) var notice: String?
    public private(set) var revision: UInt64 = 0
    public init(initial: CloudSettingsDraft) {
        isEnabled = initial.enabled
        url = initial.url
        key = initial.key
        selectedModel = initial.model
    }
    public var canLoad: Bool { !isLoading && !isSaving }
    public var canSave: Bool { !isLoading && !isSaving && (!isEnabled || !selectedModel.isEmpty) }
    @discardableResult
    public func presentFailure(_ message: String, revision: UInt64) -> Bool {
        guard presentationAdmission?.acceptsRetained() ?? true else { return false }
        guard revision == self.revision else { return false }
        error = message
        isLoading = false
        return true
    }
    @discardableResult
    public func presentModels(_ values: [String], notice: String, revision: UInt64) -> Bool {
        guard presentationAdmission?.acceptsRetained() ?? true else { return false }
        guard revision == self.revision else { return false }
        models = values
        if !values.isEmpty && !values.contains(selectedModel) { selectedModel = "" }
        self.notice = notice
        isLoading = false
        error = nil
        return true
    }
    @discardableResult
    public func presentRestored(_ value: CloudSettingsDraft, revision: UInt64) -> Bool {
        guard presentationAdmission?.acceptsRetained() ?? true else { return false }
        guard revision == self.revision else { return false }
        isEnabled = value.enabled
        url = value.url
        key = value.key
        selectedModel = value.model
        models = value.model.isEmpty ? [] : [value.model]
        error = nil
        return true
    }
    @discardableResult
    public func presentNotice(_ message: String, revision: UInt64) -> Bool {
        guard presentationAdmission?.acceptsRetained() ?? true else { return false }
        guard revision == self.revision else { return false }
        notice = message
        error = nil
        return true
    }
    public func invalidateRevision() {
        guard presentationAdmission?.acceptsRetained() ?? true else { return }
        revision += 1
    }

    @discardableResult
    public func present(_ update: SettingsUpdate) -> Bool {
        guard presentationAdmission?.acceptsRetained() ?? true else { return false }
        apply(update)
        return true
    }
    func apply(_ update: SettingsUpdate) {
        switch update {
        case .isEnabled(let value): isEnabled = value
        case .url(let value): url = value
        case .key(let value): key = value
        case .selectedModel(let value): selectedModel = value
        case .models(let value): models = value
        case .isLoading(let value): isLoading = value
        case .isSaving(let value): isSaving = value
        case .error(let value): error = value
        case .notice(let value): notice = value
        }
    }
}

extension SettingsOperating { public var presentsResults: Bool { false } }
public protocol SettingsFailurePresenting: Error { var wasPresented: Bool { get } }

public enum SettingsUpdate {
    case isEnabled(Bool)
    case url(String)
    case key(String)
    case selectedModel(String)
    case models([String])
    case isLoading(Bool)
    case isSaving(Bool)
    case error(String?)
    case notice(String?)
}

@MainActor
public protocol SettingsPresenting: UIPresentationAccess {
    var isEnabled: Bool { get }
    var url: String { get }
    var key: String { get }
    var selectedModel: String { get }
    var models: [String] { get }
    var isLoading: Bool { get }
    var isSaving: Bool { get }
    var error: String? { get }
    var notice: String? { get }
    var revision: UInt64 { get }
    var canLoad: Bool { get }
    var canSave: Bool { get }
    @discardableResult
    func present(_ update: SettingsUpdate) -> Bool
    func presentFailure(_ message: String, revision: UInt64) -> Bool
    func presentModels(_ values: [String], notice: String, revision: UInt64) -> Bool
    func presentRestored(_ value: CloudSettingsDraft, revision: UInt64) -> Bool
    func presentNotice(_ message: String, revision: UInt64) -> Bool
    func invalidateRevision()
}

extension SettingsState: SettingsPresenting {}

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

public protocol ProviderRequestFailure: Error {
    var failureCode: String? { get }
}

@MainActor
public final class UISettingsContainer {
    public let requests = UIRequests<SettingsInput, SettingsReply>()

    public let state: SettingsState
    public var presentation: any SettingsPresenting { state }
    init(initial: CloudSettingsDraft, admission: UIPresentationAdmission) {
        state = SettingsState(initial: initial)
        state.presentationAdmission = admission
    }
    func clearSensitiveDraft() {
        state.key = ""
        state.models = []
        state.isLoading = false
        state.isSaving = false
        state.invalidateRevision()
    }
}

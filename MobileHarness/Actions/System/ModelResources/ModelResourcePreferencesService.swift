import Foundation
import FunctionContracts
import StorageCore
import StorageFiles

/// Durable business data, independent of UI drafts and calling conventions.
public struct ModelResourcePreferences: Codable, Sendable, Equatable {
    public var endpoint: String
    public var allowsCellular: Bool
    public var useCustomRecognition: Bool
    public var useCustomSynthesis: Bool
    public init(
        endpoint: String = "https://huggingface.co", allowsCellular: Bool = true,
        useCustomRecognition: Bool = false, useCustomSynthesis: Bool = false
    ) {
        self.endpoint = endpoint
        self.allowsCellular = allowsCellular
        self.useCustomRecognition = useCustomRecognition
        self.useCustomSynthesis = useCustomSynthesis
    }
    public func encoded() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 2048 else { throw ModelResourcePreferenceError.invalidSource }
        return String(decoding: data, as: UTF8.self)
    }
}
public enum ModelResourcePreferenceError: Error, Sendable, CustomStringConvertible, ActionExecutionFailureProviding {
    case invalidSource, recognitionRequired, synthesisRequired
    public var executionFailureCode: ActionExecutionFailureCode { .init(rawValue: description) }
    public var description: String {
        switch self {
        case .invalidSource: "resource.source.invalid"
        case .recognitionRequired: "resource.selection.recognition"
        case .synthesisRequired: "resource.selection.synthesis"
        }
    }
}
public protocol ModelResourcePreferencesCapability: Sendable {
    func restoreSource() async throws -> ModelResourcePreferences
    func saveSource(_ preferences: ModelResourcePreferences) async throws -> ModelResourcePreferences
}
public actor ModelResourcePreferencesService: ModelResourcePreferencesCapability {
    private let makeStore: @Sendable () throws -> any DocumentStore<ModelResourcePreferences>
    private let validate: @Sendable (ModelResourcePreferences) async throws -> ModelResourcePreferences
    private let installed: @Sendable () async throws -> Set<String>
    private var store: (any DocumentStore<ModelResourcePreferences>)?
    private var changing = false
    public init(
        store: @escaping @Sendable () throws -> any DocumentStore<ModelResourcePreferences>,
        validate: @escaping @Sendable (ModelResourcePreferences) async throws -> ModelResourcePreferences,
        installed: @escaping @Sendable () async throws -> Set<String>
    ) {
        makeStore = store
        self.validate = validate
        self.installed = installed
    }
    private func persistence() throws -> any DocumentStore<ModelResourcePreferences> {
        if let store { return store }
        let value = try makeStore()
        store = value
        return value
    }
    public func restoreSource() async throws -> ModelResourcePreferences {
        guard !changing else { throw DocumentStorageError.conflict }
        changing = true
        defer { changing = false }
        try Task.checkCancellation()
        let record = try await persistence().load()
        let value = record?.value ?? ModelResourcePreferences()
        var valid = try await validate(value)
        let ids = try await installed()
        if !ResourceModelGroup.recognition.isInstalled(in: ids) { valid.useCustomRecognition = false }
        if !ResourceModelGroup.synthesis.isInstalled(in: ids) { valid.useCustomSynthesis = false }
        try Task.checkCancellation()
        // Persist actual preference changes; endpoint canonicalization alone does not force a write.
        if valid.allowsCellular != value.allowsCellular || valid.useCustomRecognition != value.useCustomRecognition
            || valid.useCustomSynthesis != value.useCustomSynthesis
        {
            try await persistence().save(valid, expecting: record?.revision)
        }
        return valid
    }
    public func saveSource(_ preferences: ModelResourcePreferences) async throws -> ModelResourcePreferences {
        guard !changing else { throw DocumentStorageError.conflict }
        changing = true
        defer { changing = false }
        try Task.checkCancellation()
        let value = try await validate(preferences)
        let ids = try await installed()
        if value.useCustomRecognition && !ResourceModelGroup.recognition.isInstalled(in: ids) {
            throw ModelResourcePreferenceError.recognitionRequired
        }
        if value.useCustomSynthesis && !ResourceModelGroup.synthesis.isInstalled(in: ids) {
            throw ModelResourcePreferenceError.synthesisRequired
        }
        let current = try await persistence().load()
        try Task.checkCancellation()
        try await persistence().save(value, expecting: current?.revision)
        return value
    }
}

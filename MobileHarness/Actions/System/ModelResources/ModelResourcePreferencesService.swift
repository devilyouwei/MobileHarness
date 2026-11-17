import Foundation
import FunctionContracts
import StorageCore
import StorageFiles

/// Durable business data, independent of UI drafts and calling conventions.
public struct ModelResourcePreferences: Codable, Sendable, Equatable {
    public var endpoint: String
    public var allowsCellular: Bool
    public var useSpeechEnhancement: Bool
    public var useCustomRecognition: Bool
    public var useCustomSynthesis: Bool
    public var vadOnsetWindows: Int
    public var vadThreshold: Double
    public var useLocalDecision: Bool
    private enum CodingKeys: String, CodingKey {
        case endpoint, allowsCellular, useCustomRecognition, useCustomSynthesis, useLocalDecision, vadOnsetWindows,
            vadThreshold, useSpeechEnhancement
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        useSpeechEnhancement = try values.decodeIfPresent(Bool.self, forKey: .useSpeechEnhancement) ?? false
        vadOnsetWindows = try values.decodeIfPresent(Int.self, forKey: .vadOnsetWindows) ?? 8
        vadThreshold = try values.decodeIfPresent(Double.self, forKey: .vadThreshold) ?? 0.65
        endpoint = try values.decode(String.self, forKey: .endpoint)
        allowsCellular = try values.decode(Bool.self, forKey: .allowsCellular)
        useCustomRecognition = try values.decode(Bool.self, forKey: .useCustomRecognition)
        useCustomSynthesis = try values.decode(Bool.self, forKey: .useCustomSynthesis)
        useLocalDecision = try values.decodeIfPresent(Bool.self, forKey: .useLocalDecision) ?? false
    }
    public init(
        endpoint: String = "https://huggingface.co", allowsCellular: Bool = true,
        useCustomRecognition: Bool = false, useCustomSynthesis: Bool = false, useLocalDecision: Bool = false,
        vadOnsetWindows: Int = 8, vadThreshold: Double = 0.65, useSpeechEnhancement: Bool = false
    ) {
        self.useSpeechEnhancement = useSpeechEnhancement
        self.vadOnsetWindows = vadOnsetWindows
        self.vadThreshold = vadThreshold
        self.endpoint = endpoint
        self.allowsCellular = allowsCellular
        self.useCustomRecognition = useCustomRecognition
        self.useCustomSynthesis = useCustomSynthesis
        self.useLocalDecision = useLocalDecision
    }
    public func encoded() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 2048 else { throw ModelResourcePreferenceError.invalidSource }
        return String(decoding: data, as: UTF8.self)
    }
}
public enum ModelResourcePreferenceError: Error, Sendable, CustomStringConvertible, ActionExecutionFailureProviding {
    case invalidSource, invalidDetection, recognitionRequired, synthesisRequired, enhancementRequired
    public var executionFailureCode: ActionExecutionFailureCode { .init(rawValue: description) }
    public var description: String {
        switch self {
        case .enhancementRequired: "Download DeepFilterNet3 before enabling noise suppression."
        case .invalidSource: "resource.source.invalid"
        case .invalidDetection: "Invalid speech detection settings."
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
    private let preferredLanguage: @Sendable () -> String?
    private var changing = false
    public init(
        store: @escaping @Sendable () throws -> any DocumentStore<ModelResourcePreferences>,
        validate: @escaping @Sendable (ModelResourcePreferences) async throws -> ModelResourcePreferences,
        installed: @escaping @Sendable () async throws -> Set<String>,
        preferredLanguage: @escaping @Sendable () -> String? = { Locale.preferredLanguages.first }
    ) {
        makeStore = store
        self.validate = validate
        self.installed = installed
        self.preferredLanguage = preferredLanguage
    }
    private func persistence() throws -> any DocumentStore<ModelResourcePreferences> {
        if let store { return store }
        let value = try makeStore()
        store = value
        return value
    }
    public func legacyDecisionSelection() async throws -> Bool {
        try await persistence().load()?.value.useLocalDecision ?? false
    }
    public func restoreSource() async throws -> ModelResourcePreferences {
        guard !changing else { throw DocumentStorageError.conflict }
        changing = true
        defer { changing = false }
        try Task.checkCancellation()
        let record = try await persistence().load()
        let language = preferredLanguage()?.lowercased().replacingOccurrences(of: "_", with: "-")
        let isChinese = language == "zh" || language?.hasPrefix("zh-") == true
        let value =
            record?.value
            ?? ModelResourcePreferences(
                endpoint: isChinese ? "https://hf-mirror.com" : "https://huggingface.co")
        var valid = try await validate(value)
        let ids = try await installed()
        if !ids.contains("deepfilternet3") { valid.useSpeechEnhancement = false }
        if !ResourceModelGroup.recognition.isInstalled(in: ids) { valid.useCustomRecognition = false }
        if !ResourceModelGroup.synthesis.isInstalled(in: ids) { valid.useCustomSynthesis = false }
        try Task.checkCancellation()
        // Persist actual preference changes; endpoint canonicalization alone does not force a write.
        if valid.allowsCellular != value.allowsCellular || valid.useCustomRecognition != value.useCustomRecognition
            || valid.useCustomSynthesis != value.useCustomSynthesis
            || valid.useSpeechEnhancement != value.useSpeechEnhancement
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
        var value = try await validate(preferences)
        let ids = try await installed()
        if value.useSpeechEnhancement && !ids.contains("deepfilternet3") {
            throw ModelResourcePreferenceError.enhancementRequired
        }
        if value.useCustomRecognition && !ResourceModelGroup.recognition.isInstalled(in: ids) {
            throw ModelResourcePreferenceError.recognitionRequired
        }
        if value.useCustomSynthesis && !ResourceModelGroup.synthesis.isInstalled(in: ids) {
            throw ModelResourcePreferenceError.synthesisRequired
        }
        let current = try await persistence().load()
        value.useLocalDecision = current?.value.useLocalDecision ?? false
        try Task.checkCancellation()
        try await persistence().save(value, expecting: current?.revision)
        return value
    }
}

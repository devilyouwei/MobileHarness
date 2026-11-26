import Foundation
import FunctionContracts
import ModelKitDefaults
import ModelKitRuntime
import StorageCore
import StorageFiles

/// Durable business data, independent of UI drafts and calling conventions.
public struct ModelResourcePreferences: Codable, Sendable, Equatable {
    public var endpoint: String
    public var allowsCellular: Bool
    public var useSpeechEnhancement: Bool
    public var useKeywordInterrupt: Bool
    public var useCustomRecognition: Bool
    public var useCustomSynthesis: Bool
    public var vadOnsetWindows: Int
    public var vadThreshold: Double
    public var keywordThreshold: Double
    public var useLocalDecision: Bool
    public var speechModels: [String: String]?
    public var synthesisVoice: String?
    private enum CodingKeys: String, CodingKey {
        case endpoint, allowsCellular, useCustomRecognition, useCustomSynthesis, useLocalDecision, vadOnsetWindows,
            vadThreshold, useSpeechEnhancement, useKeywordInterrupt, speechModels, synthesisVoice, keywordThreshold
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        synthesisVoice = try values.decodeIfPresent(String.self, forKey: .synthesisVoice)
        speechModels = try values.decodeIfPresent([String: String].self, forKey: .speechModels)
        useSpeechEnhancement = try values.decodeIfPresent(Bool.self, forKey: .useSpeechEnhancement) ?? false
        useKeywordInterrupt = try values.decodeIfPresent(Bool.self, forKey: .useKeywordInterrupt) ?? false
        vadOnsetWindows = try values.decodeIfPresent(Int.self, forKey: .vadOnsetWindows) ?? 8
        vadThreshold = try values.decodeIfPresent(Double.self, forKey: .vadThreshold) ?? 0.65
        keywordThreshold = try values.decodeIfPresent(Double.self, forKey: .keywordThreshold) ?? 0.25
        endpoint = try values.decode(String.self, forKey: .endpoint)
        allowsCellular = try values.decode(Bool.self, forKey: .allowsCellular)
        useCustomRecognition = try values.decode(Bool.self, forKey: .useCustomRecognition)
        useCustomSynthesis = try values.decode(Bool.self, forKey: .useCustomSynthesis)
        useLocalDecision = try values.decodeIfPresent(Bool.self, forKey: .useLocalDecision) ?? false
    }
    public init(
        endpoint: String = "https://huggingface.co", allowsCellular: Bool = true,
        useCustomRecognition: Bool = false, useCustomSynthesis: Bool = false, useLocalDecision: Bool = false,
        vadOnsetWindows: Int = 8, vadThreshold: Double = 0.65, useSpeechEnhancement: Bool = false,
        useKeywordInterrupt: Bool = false, speechModels: [String: String]? = nil, synthesisVoice: String? = nil,
        keywordThreshold: Double = 0.25
    ) {
        self.useSpeechEnhancement = useSpeechEnhancement
        self.useKeywordInterrupt = useKeywordInterrupt
        self.speechModels = speechModels
        self.synthesisVoice = synthesisVoice
        self.vadOnsetWindows = vadOnsetWindows
        self.vadThreshold = vadThreshold
        self.keywordThreshold = keywordThreshold
        self.endpoint = endpoint
        self.allowsCellular = allowsCellular
        self.useCustomRecognition = useCustomRecognition
        self.useCustomSynthesis = useCustomSynthesis
        self.useLocalDecision = useLocalDecision
    }
    private var legacySpeechModels: [String: String] {
        [
            ProvidedCapability.endpointConfirmation.rawValue: "off",
            ProvidedCapability.voiceActivity.rawValue: "energy-vad",
            ProvidedCapability.recognition.rawValue: useCustomRecognition ? "nemotron-local" : "apple-recognition",
            ProvidedCapability.synthesis.rawValue: useCustomSynthesis ? "moss-tts-nano" : "apple-synthesis",
            ProvidedCapability.enhancement.rawValue: useSpeechEnhancement ? "deepfilternet3" : "off",
            ProvidedCapability.keywordSpotting.rawValue: useKeywordInterrupt ? "zipformer-kws" : "off",
        ]
    }
    static func isValidKeywordThreshold(_ value: Double) -> Bool {
        (0.10...0.60).contains(value) && abs(value * 20 - (value * 20).rounded()) < 0.00001
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.endpoint == rhs.endpoint && lhs.allowsCellular == rhs.allowsCellular
            && lhs.vadOnsetWindows == rhs.vadOnsetWindows && lhs.vadThreshold == rhs.vadThreshold
            && lhs.keywordThreshold == rhs.keywordThreshold
            && lhs.useLocalDecision == rhs.useLocalDecision && lhs.synthesisVoice == rhs.synthesisVoice
            && (lhs.speechModels ?? lhs.legacySpeechModels) == (rhs.speechModels ?? rhs.legacySpeechModels)
    }

    /// Migrate the former per-feature switches once, then validate against the registered choices.
    mutating func resolveSpeechModels(installed: Set<String>, strict: Bool) throws {
        let defaults = SpeechModelOption.catalog.filter {
            SpeechModelOption.defaultOption(for: $0.capability)?.id == $0.id
        }
        if strict, let speechModels, !Set(speechModels.keys).isSubset(of: Set(defaults.map { $0.capability.rawValue }))
        {
            throw ModelResourcePreferenceError.invalidSpeechModel
        }
        var chosen: [String: String] = [:]
        for fallback in defaults {
            let capability = fallback.capability
            let key = capability.rawValue
            let requested = speechModels?[key] ?? legacySpeechModels[key] ?? fallback.id
            guard let selected = SpeechModelOption.option(requested, for: capability) else {
                if strict { throw ModelResourcePreferenceError.invalidSpeechModel }
                chosen[key] = fallback.id
                continue
            }
            if let artifactID = selected.artifactID, !installed.contains(artifactID) {
                if strict {
                    switch capability {
                    case .recognition: throw ModelResourcePreferenceError.recognitionRequired
                    case .synthesis: throw ModelResourcePreferenceError.synthesisRequired
                    case .enhancement: throw ModelResourcePreferenceError.enhancementRequired
                    case .endpointConfirmation: throw ModelResourcePreferenceError.endpointConfirmationRequired
                    case .keywordSpotting: throw ModelResourcePreferenceError.keywordInterruptRequired
                    default: throw ModelResourcePreferenceError.voiceActivityRequired
                    }
                }
                chosen[key] = fallback.id
            } else {
                chosen[key] = selected.id
            }
        }
        if let synthesisVoice, !SpeechModelOption.supportsSynthesisVoice(synthesisVoice) {
            if strict { throw ModelResourcePreferenceError.invalidSpeechModel }
            self.synthesisVoice = nil
        }
        speechModels = chosen
        func downloaded(_ capability: ProvidedCapability) -> Bool {
            guard let id = chosen[capability.rawValue] else { return false }
            return SpeechModelOption.option(id, for: capability)?.artifactID != nil
        }
        useCustomRecognition = downloaded(.recognition)
        useCustomSynthesis = downloaded(.synthesis)
        useSpeechEnhancement = chosen[ProvidedCapability.enhancement.rawValue] != "off"
        useKeywordInterrupt = chosen[ProvidedCapability.keywordSpotting.rawValue] != "off"
    }

    public func encoded() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 2048 else { throw ModelResourcePreferenceError.invalidSource }
        return String(decoding: data, as: UTF8.self)
    }
}
public enum ModelResourcePreferenceError: Error, Sendable, CustomStringConvertible, ActionExecutionFailureProviding {
    case invalidSource, invalidDetection, recognitionRequired, synthesisRequired, enhancementRequired,
        keywordInterruptRequired, endpointConfirmationRequired, voiceActivityRequired, invalidSpeechModel
    public var executionFailureCode: ActionExecutionFailureCode { .init(rawValue: description) }
    public var description: String {
        switch self {
        case .endpointConfirmationRequired: "Download Smart Turn before enabling end-of-turn confirmation."
        case .voiceActivityRequired: "Download the selected voice activity model first."
        case .invalidSpeechModel: "The selected speech model is unavailable for this capability."
        case .keywordInterruptRequired: "resource.selection.keywordInterrupt"
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
    private let beginModelChange: @MainActor @Sendable (ModelSettingsChange) async throws -> Void
    private let endModelChange: @MainActor @Sendable () -> Void
    private var changing = false
    public init(
        store: @escaping @Sendable () throws -> any DocumentStore<ModelResourcePreferences>,
        validate: @escaping @Sendable (ModelResourcePreferences) async throws -> ModelResourcePreferences,
        installed: @escaping @Sendable () async throws -> Set<String>,
        preferredLanguage: @escaping @Sendable () -> String? = { Locale.preferredLanguages.first },
        beginModelChange: @escaping @MainActor @Sendable (ModelSettingsChange) async throws -> Void = { _ in },
        endModelChange: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        makeStore = store
        self.validate = validate
        self.installed = installed
        self.preferredLanguage = preferredLanguage
        self.beginModelChange = beginModelChange
        self.endModelChange = endModelChange
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
    func configuredSource() async throws -> ModelResourcePreferences {
        guard !changing else { throw DocumentStorageError.conflict }
        var selected = try await persistence().load()?.value ?? ModelResourcePreferences()
        let knownArtifacts = Set(SpeechModelOption.catalog.compactMap(\.artifactID))
        try selected.resolveSpeechModels(installed: knownArtifacts, strict: false)
        return selected
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
        try await valid.resolveSpeechModels(installed: installed(), strict: false)
        try Task.checkCancellation()
        // Persist actual preference changes; endpoint canonicalization alone does not force a write.
        if valid.allowsCellular != value.allowsCellular || valid.useCustomRecognition != value.useCustomRecognition
            || valid.useCustomSynthesis != value.useCustomSynthesis
            || valid.useSpeechEnhancement != value.useSpeechEnhancement
            || valid.useKeywordInterrupt != value.useKeywordInterrupt
            || valid.synthesisVoice != value.synthesisVoice
            || (value.speechModels != nil && valid.speechModels != value.speechModels)
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
        let installed = try await installed()
        try value.resolveSpeechModels(installed: installed, strict: true)
        let current = try await persistence().load()
        value.useLocalDecision = current?.value.useLocalDecision ?? false
        var previous = current?.value ?? ModelResourcePreferences()
        try previous.resolveSpeechModels(installed: installed, strict: false)
        let impact = Self.modelChange(from: previous, to: value)
        if !impact.roles.isEmpty { try await beginModelChange(impact) }
        do {
            try Task.checkCancellation()
            try await persistence().save(value, expecting: current?.revision)
        } catch {
            if !impact.roles.isEmpty { await endModelChange() }
            throw error
        }
        if !impact.roles.isEmpty { await endModelChange() }
        return value
    }

    static func modelChange(from previous: ModelResourcePreferences, to value: ModelResourcePreferences)
        -> ModelSettingsChange
    {
        var impact = ModelSettingsChange()
        for (key, selection) in value.speechModels ?? [:] {
            guard previous.speechModels?[key] != selection, let role = ModelSettingsChange.Role(rawValue: key)
            else { continue }
            impact.roles.insert(role)
            if selection != "off" { impact.modelIDs.insert(selection) }
        }
        if previous.vadThreshold != value.vadThreshold || previous.vadOnsetWindows != value.vadOnsetWindows {
            impact.roles.insert(.voiceActivity)
        }
        if previous.keywordThreshold != value.keywordThreshold, value.speechModels?["keywordSpotting"] != "off" {
            impact.roles.insert(.keywordSpotting)
        }
        if previous.synthesisVoice != value.synthesisVoice { impact.roles.insert(.synthesis) }
        return impact
    }
}

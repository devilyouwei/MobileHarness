import Foundation
import ModelKit
import ModelKitKokoro
import ModelKitRuntime

/// A user-selectable implementation. Nil artifact means the implementation ships with the app or the OS.
public struct SpeechModelOption: Sendable {
    public let capability: ProvidedCapability
    public let id: String
    public let title: String
    public let artifactID: String?
    public let voicesByLanguage: [String: [String]]?

    private init(
        _ capability: ProvidedCapability, _ id: String, _ title: String, artifact: String? = nil,
        voicesByLanguage: [String: [String]]? = nil
    ) {
        self.capability = capability
        self.id = id
        self.title = title
        self.artifactID = artifact
        self.voicesByLanguage = voicesByLanguage
    }

    public static let catalog: [Self] = [
        .init(.voiceActivity, "energy-vad", "Energy detection"),
        .init(.voiceActivity, "silero", "Silero VAD", artifact: "silero"),
        .init(.endpointConfirmation, "off", "Off"),
        .init(.endpointConfirmation, "smart-turn", "Smart Turn v3.2", artifact: "smart-turn"),
        .init(.enhancement, "off", "Off"),
        .init(.enhancement, "deepfilternet3", "DeepFilterNet3", artifact: "deepfilternet3"),
        .init(.keywordSpotting, "off", "Off"),
        .init(.keywordSpotting, "zipformer-kws", "Zipformer Keyword Spotting", artifact: "zipformer-kws"),
        .init(.recognition, "apple-recognition", "Apple speech recognition"),
        .init(.recognition, "nemotron-local", "Nemotron", artifact: "nemotron"),
        .init(.synthesis, "apple-synthesis", "Apple system voices"),
        .init(.synthesis, "moss-tts-nano", "MOSS TTS Nano", artifact: "moss-tts-nano"),
        .init(
            .synthesis, KokoroVoiceCatalog.modelID, "Kokoro 82M", artifact: KokoroVoiceCatalog.modelID,
            voicesByLanguage: KokoroVoiceCatalog.voicesByLanguage),
    ]

    public static func supportsSynthesisVoice(_ id: String) -> Bool {
        KokoroVoiceCatalog.contains(id)
    }

    public static func defaultOption(for capability: ProvidedCapability) -> Self? {
        catalog.first { $0.capability == capability }
    }

    public static func option(_ id: String, for capability: ProvidedCapability) -> Self? {
        catalog.first { $0.capability == capability && $0.id == id }
    }
}

/// Policy is shared by lightweight capability facades. Each operation chooses once;
/// the selected concrete provider retains its own managed lease until finish/cancel.
actor SpeechSelection {
    static let appleRecognitionModels: [(locale: String, id: ModelID)] = [
        ("en-US", ModelID("apple-recognition")),
        ("zh-CN", ModelID("apple-recognition-zh-CN")),
    ]
    private let recognitionLocale: @Sendable () -> String
    private var models: [String: String] = [:]
    private var synthesisVoice: String?
    init(recognitionLocale: @escaping @Sendable () -> String = { "en-US" }) {
        self.recognitionLocale = recognitionLocale
    }

    func stateSnapshot() -> (recognition: Bool, synthesis: Bool) {
        (selectedOption(for: .recognition)?.artifactID != nil, selectedOption(for: .synthesis)?.artifactID != nil)
    }

    func configure(recognition: Bool, synthesis: Bool) {
        models[ProvidedCapability.recognition.rawValue] = recognition ? "nemotron-local" : "apple-recognition"
        models[ProvidedCapability.synthesis.rawValue] = synthesis ? "moss-tts-nano" : "apple-synthesis"
    }

    func configure(models: [String: String], synthesisVoice: String? = nil) throws {
        try Task.checkCancellation()
        guard
            models.allSatisfy({ key, id in
                guard let capability = ProvidedCapability(rawValue: key) else { return false }
                return SpeechModelOption.option(id, for: capability) != nil
            })
        else { throw CapabilityError.invalidRequest("Invalid speech model selection") }
        if let synthesisVoice, !SpeechModelOption.supportsSynthesisVoice(synthesisVoice) {
            throw CapabilityError.invalidRequest("Invalid synthesis voice")
        }
        self.models = models
        self.synthesisVoice = synthesisVoice
    }

    func selectedOption(for capability: ProvidedCapability) -> SpeechModelOption? {
        models[capability.rawValue].flatMap { SpeechModelOption.option($0, for: capability) }
            ?? SpeechModelOption.defaultOption(for: capability)
    }

    func resolveRecognition(manager: ModelManager, locale: String = "auto") async throws -> ModelID {
        let requested = locale == "auto" ? recognitionLocale() : locale
        let system = Self.appleRecognitionModels.first { $0.locale == requested }?.id
        let selected = try await resolvedChoice(manager: manager, capability: .recognition)
        if let selected, selected.rawValue != "apple-recognition" { return selected }
        guard let system else { throw CapabilityError.invalidRequest("Unsupported Apple recognition locale") }
        return system
    }

    func configuredResource(_ capability: ProvidedCapability) throws -> (ModelID, String)? {
        guard let option = selectedOption(for: capability), option.id != "off" else { return nil }
        if option.id == "apple-recognition" {
            return try appleRecognitionResource()
        }
        return (ModelID(option.id), option.title)
    }

    func appleRecognitionResource() throws -> (ModelID, String) {
        let locale = recognitionLocale()
        guard let model = Self.appleRecognitionModels.first(where: { $0.locale == locale }) else {
            throw CapabilityError.invalidRequest("Unsupported Apple recognition locale")
        }
        return (model.id, "Apple speech recognition (" + locale + ")")
    }

    func resolvedChoice(manager: ModelManager, capability: ProvidedCapability) async throws -> ModelID? {
        guard let choice = selectedOption(for: capability) else {
            throw CapabilityError.invalidRequest("Not a speech capability")
        }
        guard let artifact = choice.artifactID else { return choice.id == "off" ? nil : ModelID(choice.id) }
        let id = ModelID(choice.id)
        let installed: Bool
        do {
            installed = try await manager.artifactSnapshots().contains {
                $0.artifact.id == artifact && $0.phase == .installed
            }
        } catch ModelArtifactError.missingArtifact { installed = false }
        if installed {
            if capability == .keywordSpotting || capability == .endpointConfirmation { return id }
            if case .available = try await manager.availability(id, for: capability) { return id }
        }
        return SpeechModelOption.defaultOption(for: capability).flatMap { $0.id == "off" ? nil : ModelID($0.id) }
    }

    func resolveSynthesis(manager: ModelManager) async throws -> (id: ModelID, voice: String?) {
        let voice = synthesisVoice
        let id = try await requiredChoice(manager: manager, capability: .synthesis)
        return (id, id.rawValue == KokoroVoiceCatalog.modelID ? voice : nil)
    }

    func requiredChoice(manager: ModelManager, capability: ProvidedCapability) async throws -> ModelID {
        guard let choice = try await resolvedChoice(manager: manager, capability: capability) else {
            throw CapabilityError.unavailable("Speech capability is turned off")
        }
        return choice
    }

}
actor SelectedRecognition: SpeechRecognitionCapability {
    let manager: ModelManager
    let selection: SpeechSelection
    init(manager: ModelManager, selection: SpeechSelection) {
        self.manager = manager
        self.selection = selection
    }
    func selected() async throws -> ModelID {
        try await selection.resolveRecognition(manager: manager)
    }
    var availability: CapabilityAvailability {
        get async {
            do { return try await manager.availability(selected(), for: .recognition) } catch {
                return .unavailable(reason: "Speech resource preparation failed: \(error)")
            }
        }
    }
    func warmup() async throws { try await manager.warmup(selected()) }
    func transcribe(_ request: SpeechRecognitionRequest) async throws -> SpeechRecognitionSession {
        let id = try await selection.resolveRecognition(manager: manager, locale: request.locale)
        let provider = try await manager.get(id, as: .recognition, load: false)
        return try await provider.transcribe(request)
    }
}
actor SelectedSynthesis: SpeechSynthesisCapability {
    let manager: ModelManager
    let selection: SpeechSelection
    init(manager: ModelManager, selection: SpeechSelection) {
        self.manager = manager
        self.selection = selection
    }
    func selected() async throws -> ModelID {
        try await selection.requiredChoice(manager: manager, capability: .synthesis)
    }
    var availability: CapabilityAvailability {
        get async {
            do { return try await manager.availability(selected(), for: .synthesis) } catch {
                return .unavailable(reason: "Speech resource preparation failed: \(error)")
            }
        }
    }
    func warmup() async throws { try await manager.warmup(selected()) }
    func synthesize(_ request: SpeechSynthesisRequest) async throws -> InferenceSession<SynthesisEvent> {
        let choice = try await selection.resolveSynthesis(manager: manager)
        let provider = try await manager.get(choice.id, as: .synthesis, load: false)
        if #available(iOS 27, macOS 27, *), let kokoro = provider as? KokoroSpeechSynthesis {
            return try await kokoro.synthesize(request, preferredVoice: choice.voice)
        }
        return try await provider.synthesize(request)
    }
}
actor SelectedVoiceActivity: VoiceActivityCapability {
    let manager: ModelManager
    let selection: SpeechSelection
    init(manager: ModelManager, selection: SpeechSelection) {
        self.manager = manager
        self.selection = selection
    }
    func selected() async throws -> ModelID {
        try await selection.requiredChoice(manager: manager, capability: .voiceActivity)
    }
    var availability: CapabilityAvailability {
        get async {
            do { return try await manager.availability(selected(), for: .voiceActivity) } catch {
                return .unavailable(reason: "Speech resource preparation failed: \(error)")
            }
        }
    }
    func warmup() async throws { try await manager.load(selected()) }
    func detectVoiceActivity(format: AudioFormat) async throws -> any VoiceActivitySession {
        let provider = try await manager.get(selected(), as: .voiceActivity, load: false)
        return try await provider.detectVoiceActivity(format: format)
    }
}

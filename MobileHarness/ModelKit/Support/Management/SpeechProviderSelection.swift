import Foundation
import ModelKit
import ModelKitRuntime

/// Policy is shared by lightweight capability facades. Each operation chooses once;
/// the selected concrete provider retains its own managed lease until finish/cancel.
actor SpeechSelection {
    private var recognitionEnabled = false
    private var synthesisEnabled = false
    func stateSnapshot() -> (recognition: Bool, synthesis: Bool) { (recognitionEnabled, synthesisEnabled) }
    func configure(recognition: Bool, synthesis: Bool) {
        recognitionEnabled = recognition
        synthesisEnabled = synthesis
    }
    func resolve(
        manager: ModelManager, artifact: String, local: ModelID, system: ModelID, capability: ProvidedCapability
    ) async throws -> ModelID {
        let enabled = capability == .voiceActivity || (capability == .synthesis ? synthesisEnabled : recognitionEnabled)
        guard enabled else { return system }
        let installed: Bool
        do {
            let snapshots = try await manager.artifactSnapshots()
            let required = [artifact]
            installed = required.allSatisfy { id in
                snapshots.contains { $0.artifact.id == id && $0.phase == .installed }
            }
        } catch ModelArtifactError.missingArtifact { installed = false }
        if installed, case .available = try await manager.availability(local, for: capability) { return local }
        return system
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
        try await selection.resolve(
            manager: manager, artifact: "nemotron", local: ModelID("nemotron-local"),
            system: ModelID("apple-recognition"), capability: .recognition)
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
        let provider = try await manager.get(selected(), as: .recognition, load: false)
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
        try await selection.resolve(
            manager: manager, artifact: "moss-tts-nano", local: DefaultModelAssembly.mossNano,
            system: ModelID("apple-synthesis"), capability: .synthesis)
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
        let provider = try await manager.get(selected(), as: .synthesis, load: false)
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
        try await selection.resolve(
            manager: manager, artifact: "silero", local: ModelID("silero"), system: ModelID("energy-vad"),
            capability: .voiceActivity)
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

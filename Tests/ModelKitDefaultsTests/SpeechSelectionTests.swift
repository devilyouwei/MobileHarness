import Foundation
import ModelKit
@_spi(ModelAssembly) import ModelKitRuntime
import Synchronization
import Testing

@testable import ModelKitDefaults

@Test func futureAppleRecognitionUsesTheNewLocaleAndRejectsUnsupportedRequests() async throws {
    let manager = try ModelManager()
    let locale = Mutex("en-US")
    let selection = SpeechSelection(recognitionLocale: { locale.withLock { $0 } })
    let english = try await selection.resolveRecognition(manager: manager)
    locale.withLock { $0 = "zh-CN" }
    let chinese = try await selection.resolveRecognition(manager: manager)
    #expect(english.rawValue == "apple-recognition")
    #expect(chinese.rawValue == "apple-recognition-zh-CN")
    #expect(try await selection.resolveRecognition(manager: manager, locale: "en-US") == english)
    await #expect(throws: CapabilityError.self) {
        try await selection.resolveRecognition(manager: manager, locale: "de-DE")
    }
    await manager.shutdown()
}

/// Selection fixture; does not perform inference or download weights.
private struct SelectionProvider: SpeechSynthesisCapability, SpeechRecognitionCapability, VoiceActivityCapability {
    let availability: CapabilityAvailability
    func detectVoiceActivity(format: AudioFormat) async throws -> any VoiceActivitySession {
        throw CapabilityError.unavailable("Fixture inference failure")
    }
    func transcribe(_ request: SpeechRecognitionRequest) async throws -> SpeechRecognitionSession {
        throw CapabilityError.unavailable("Fixture inference failure")
    }
    func synthesize(_ request: SpeechSynthesisRequest) async throws -> InferenceSession<SynthesisEvent> {
        throw CapabilityError.unavailable("Fixture inference failure")
    }
}
private actor SelectionStorage: ModelArtifactStorage {
    var present = true
    var missing: Set<String> = []
    func setMissing(_ id: String) { missing = [id] }
    func setPresent(_ value: Bool) { present = value }
    func restoreTransfers() -> [ModelArtifactTransferRecord] { [] }
    func saveTransfers(_ records: [ModelArtifactTransferRecord]) {}
    func installed(_ artifact: ModelArtifact) -> Bool { present && !missing.contains(artifact.id) }
    func stage(_ artifact: ModelArtifact, task: String) throws -> URL { throw ModelArtifactError.storage }
    func publish(_ artifact: ModelArtifact, task: String) {}
    func discard(task: String) {}
    func remove(_ artifact: ModelArtifact) { present = false }
}
@Test func speechSelectionRespectsInstallationAvailabilityAndExplicitSystemPreference() async throws {
    let manager = try ModelManager()
    let storage = SelectionStorage()
    let catalog = try ModelArtifactCatalog.decode(
        Data(
            #"{"schemaVersion":2,"packages":[{"id":"speech","name":"Fixture","capability":"synthesis","directory":"Speech","source":{"kind":"huggingface","repoId":"owner/repo","revision":"main","allowPatterns":["config.json"]},"minimumOS":1,"requiresPhysicalDevice":false,"license":"MIT","estimatedBytes":3,"requiredFiles":["config.json"]}]}"#
                .utf8))
    try await manager.configureArtifacts(catalog: catalog, storage: storage)
    let local = ModelID("local")
    let unavailable = ModelID("unavailable")
    let system = ModelID("system")
    for (id, availability) in [
        (local, CapabilityAvailability.available), (unavailable, .unavailable(reason: "Fixture")),
    ] {
        try await manager.register(
            ModelRegistration(id: id, capabilities: [.synthesis]) { _ in
                ProvidedCapabilities(synthesis: SelectionProvider(availability: availability))
            })
    }
    let selection = SpeechSelection()
    await selection.configure(recognition: true, synthesis: true)
    #expect(
        try await selection.resolve(
            manager: manager, artifact: "speech", local: local, system: system, capability: .synthesis) == local)
    #expect(
        try await selection.resolve(
            manager: manager, artifact: "speech", local: unavailable, system: system, capability: .synthesis) == system)
    await selection.configure(recognition: true, synthesis: false)
    #expect(
        try await selection.resolve(
            manager: manager, artifact: "speech", local: local, system: system, capability: .synthesis) == system)
    await selection.configure(recognition: false, synthesis: true)
    await storage.setPresent(false)
    #expect(
        try await selection.resolve(
            manager: manager, artifact: "speech", local: local, system: system, capability: .synthesis) == system)
    await manager.shutdown()
}

@Test func recognitionSelectionIsIndependentOfVADInstallationAndSynthesisChoice() async throws {
    let manager = try ModelManager()
    let storage = SelectionStorage()
    let packages = [("nemotron", "recognition"), ("silero", "voiceActivity"), ("moss-tts-nano", "synthesis")].map {
        id, capability in
        [
            "id": id, "name": id, "capability": capability, "directory": id,
            "source": [
                "kind": "huggingface", "repoId": "owner/repo", "revision": "main", "allowPatterns": ["config.json"],
            ],
            "minimumOS": 1, "requiresPhysicalDevice": false, "license": "MIT", "estimatedBytes": 3,
            "requiredFiles": ["config.json"],
        ] as [String: Any]
    }
    let catalog = try ModelArtifactCatalog.decode(
        JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "packages": packages]))
    try await manager.configureArtifacts(catalog: catalog, storage: storage)
    let local = ModelID("fixture")
    let system = ModelID("system")
    try await manager.register(
        ModelRegistration(id: local, capabilities: [.recognition, .synthesis, .voiceActivity]) { _ in
            let provider = SelectionProvider(availability: .available)
            return ProvidedCapabilities(recognition: provider, synthesis: provider, voiceActivity: provider)
        })
    let selection = SpeechSelection()
    await selection.configure(recognition: true, synthesis: false)
    #expect(
        try await selection.resolve(
            manager: manager, artifact: "nemotron", local: local, system: system, capability: .recognition) == local)
    #expect(
        try await selection.resolve(
            manager: manager, artifact: "moss-tts-nano", local: local, system: system, capability: .synthesis) == system
    )
    let unavailable = ModelID("fixture-unavailable-vad")
    try await manager.register(
        ModelRegistration(id: unavailable, capabilities: [.voiceActivity]) { _ in
            ProvidedCapabilities(voiceActivity: SelectionProvider(availability: .unavailable(reason: "Fixture")))
        })
    #expect(
        try await selection.resolve(
            manager: manager, artifact: "silero", local: unavailable, system: system, capability: .voiceActivity)
            == system)
    // Both ASR choices may use installed Silero; the recognition switch does not control VAD.
    for enabled in [false, true] {
        await selection.configure(recognition: enabled, synthesis: false)
        #expect(
            try await selection.resolve(
                manager: manager, artifact: "silero", local: local, system: system, capability: .voiceActivity) == local
        )
        #expect(
            try await selection.resolve(
                manager: manager, artifact: "nemotron", local: local, system: system, capability: .recognition)
                == (enabled ? local : system))
    }
    await storage.setMissing("silero")
    #expect(
        try await selection.resolve(
            manager: manager, artifact: "nemotron", local: local, system: system, capability: .recognition) == local)
    #expect(
        try await selection.resolve(
            manager: manager, artifact: "silero", local: local, system: system, capability: .voiceActivity) == system)
    await storage.setMissing("nemotron")
    #expect(
        try await selection.resolve(
            manager: manager, artifact: "silero", local: local, system: system, capability: .voiceActivity) == local)
    #expect(
        try await selection.resolve(
            manager: manager, artifact: "nemotron", local: local, system: system, capability: .recognition) == system)
    await selection.configure(recognition: false, synthesis: true)
    #expect(
        try await selection.resolve(
            manager: manager, artifact: "moss-tts-nano", local: local, system: system, capability: .synthesis) == local)
    await manager.shutdown()
}

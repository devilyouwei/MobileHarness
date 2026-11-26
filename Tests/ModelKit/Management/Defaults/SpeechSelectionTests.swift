import Foundation
import ModelKit
import ModelKitHub
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
            #"{"schemaVersion":2,"packages":[{"id":"moss-tts-nano","name":"Fixture","capability":"synthesis","directory":"Speech","source":{"kind":"huggingface","repoId":"owner/repo","revision":"main","allowPatterns":["config.json"]},"minimumOS":1,"requiresPhysicalDevice":false,"license":"MIT","estimatedBytes":3,"requiredFiles":["config.json"]}]}"#
                .utf8))
    try await manager.configureArtifacts(catalog: catalog, storage: storage)
    let local = ModelID("moss-tts-nano")
    let system = ModelID("apple-synthesis")
    try await manager.register(
        ModelRegistration(id: local, capabilities: [.synthesis]) { _ in
            ProvidedCapabilities(synthesis: SelectionProvider(availability: .available))
        })
    let selection = SpeechSelection()
    #expect(try await selection.resolvedChoice(manager: manager, capability: .synthesis) == system)
    try await selection.configure(models: ["synthesis": local.rawValue])
    #expect(try await selection.resolvedChoice(manager: manager, capability: .synthesis) == local)
    await storage.setPresent(false)
    #expect(try await selection.resolvedChoice(manager: manager, capability: .synthesis) == system)
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
    let options: [(String, ProvidedCapability)] = [
        ("nemotron-local", .recognition), ("silero", .voiceActivity), ("moss-tts-nano", .synthesis),
    ]
    for (id, capability) in options {
        try await manager.register(
            ModelRegistration(id: ModelID(id), capabilities: [capability]) { _ in
                let provider = SelectionProvider(availability: .available)
                switch capability {
                case .recognition: return ProvidedCapabilities(recognition: provider)
                case .voiceActivity: return ProvidedCapabilities(voiceActivity: provider)
                default: return ProvidedCapabilities(synthesis: provider)
                }
            })
    }
    let selection = SpeechSelection()
    #expect(try await selection.resolvedChoice(manager: manager, capability: .voiceActivity) == ModelID("energy-vad"))
    #expect(try await selection.resolvedChoice(manager: manager, capability: .enhancement) == nil)
    #expect(try await selection.resolvedChoice(manager: manager, capability: .keywordSpotting) == nil)
    await #expect(throws: CapabilityError.self) {
        try await selection.configure(models: ["voiceActivity": "nemotron-local"])
    }
    try await selection.configure(models: ["recognition": "nemotron-local", "voiceActivity": "silero"])
    #expect(try await selection.resolveRecognition(manager: manager) == ModelID("nemotron-local"))
    #expect(try await selection.resolvedChoice(manager: manager, capability: .voiceActivity) == ModelID("silero"))
    #expect(try await selection.resolvedChoice(manager: manager, capability: .synthesis) == ModelID("apple-synthesis"))
    await storage.setMissing("silero")
    #expect(try await selection.resolvedChoice(manager: manager, capability: .voiceActivity) == ModelID("energy-vad"))
    #expect(try await selection.resolveRecognition(manager: manager) == ModelID("nemotron-local"))
    await manager.shutdown()
}

@Test(
    .enabled(if: ProcessInfo.processInfo.environment["HARNESS_TEST_KOKORO_DOWNLOAD"] == "1"), .timeLimit(.minutes(10)))
@MainActor func downloadedKokoroVoicesAreUsedByTheProductionSynthesisPort() async throws {
    let retainedRoot = ProcessInfo.processInfo.environment["HARNESS_TEST_KOKORO_DOWNLOAD_ROOT"]
    let root =
        retainedRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { if retainedRoot == nil { try? FileManager.default.removeItem(at: root) } }
    let storage = try ModelArtifactDiskStorage(root: root)
    let model = ModelContainer(resources: storage.installedRoot) {
        ModelArtifactConfiguration(
            catalog: try .bundled(), storage: storage, downloader: HuggingFaceArtifactDownloader())
    }
    let id = "kokoro-82m"
    try await model.start()
    try await model.setForeground(true)
    try await model.artifacts.downloadArtifact(id, source: ModelDownloadSource())
    let deadline = ContinuousClock.now + .seconds(480)
    while true {
        let artifact = try #require(try await model.artifacts.artifactSnapshots().first { $0.artifact.id == id })
        if artifact.phase == .installed { break }
        try #require(artifact.phase != .failed, Comment(rawValue: artifact.failure ?? "Download failed"))
        try #require(ContinuousClock.now < deadline, "Timed out installing Kokoro")
        try await Task.sleep(for: .seconds(1))
    }

    func synthesize(_ text: String, voice: String) async throws -> Data {
        try await model.speech.configureSpeechModels(["synthesis": id], synthesisVoice: voice)
        let session = try await model.speech.synthesis.synthesize(
            SpeechSynthesisRequest(text: text, locale: "auto"))
        var pcm = Data()
        var finished = false
        for try await event in session.events {
            switch event {
            case .audio(let frame):
                #expect(frame.format.sampleRate == 24_000)
                pcm.append(frame.data)
            case .finished: finished = true
            }
        }
        #expect(finished)
        try #require(!pcm.isEmpty)
        return pcm
    }

    let text = "The weather is lovely today."
    let defaultVoice = try await synthesize(text, voice: "af_heart")
    let britishVoice = try await synthesize(text, voice: "bf_emma")
    #expect(defaultVoice != britishVoice)
    _ = try await synthesize("你好，今天天气很好。", voice: "zm_100")
    try await model.stop()
}

@Test func smartTurnHasAnIndependentSelectionAndPinnedArtifact() async throws {
    let catalog = try ModelArtifactCatalog.bundled()
    let artifact = try #require(catalog.packages.first { $0.id == "smart-turn" })
    #expect(artifact.capability == ProvidedCapability.endpointConfirmation.rawValue)
    #expect(artifact.source.repoId == "aufklarer/Smart-Turn-v3.2-CoreML")
    #expect(artifact.revision == "75f069717f500947195fa1945c46ddb472559cff")
    #expect(artifact.requiredFiles.contains("smart_turn.mlmodelc/weights/weight.bin"))
    let manager = try ModelManager()
    let storage = SelectionStorage()
    try await manager.configureArtifacts(catalog: catalog, storage: storage)
    let selection = SpeechSelection()
    #expect(try await selection.resolvedChoice(manager: manager, capability: .endpointConfirmation) == nil)
    try await selection.configure(models: ["endpointConfirmation": "smart-turn"])
    #expect(
        try await selection.resolvedChoice(manager: manager, capability: .endpointConfirmation)?.rawValue
            == "smart-turn")
    #expect(try await selection.resolvedChoice(manager: manager, capability: .voiceActivity)?.rawValue == "energy-vad")
    await storage.setMissing("smart-turn")
    #expect(try await selection.resolvedChoice(manager: manager, capability: .endpointConfirmation) == nil)
    await manager.shutdown()
}

@Test(
    .enabled(if: ProcessInfo.processInfo.environment["HARNESS_TEST_SMART_TURN_DOWNLOAD"] == "1"),
    .timeLimit(.minutes(3)))
@MainActor func downloadedSmartTurnPrewarmsAndRunsThroughTheProductionEndpointPort() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try ModelArtifactDiskStorage(root: root)
    let model = ModelContainer(resources: storage.installedRoot) {
        ModelArtifactConfiguration(
            catalog: try .bundled(), storage: storage, downloader: HuggingFaceArtifactDownloader())
    }
    let id = "smart-turn"
    try await model.start()
    try await model.setForeground(true)
    do {
        let endpoint = try #require(model.speech.endpointConfirmation)
        let samples = (0..<16000).map { Float(sin(Double($0) * 0.08) * 0.01) }
        try await model.speech.configureSpeechModels(["endpointConfirmation": id])
        #expect(try await endpoint.completionProbability(for: samples) == nil)
        try await model.artifacts.downloadArtifact(id, source: ModelDownloadSource())
        let deadline = ContinuousClock.now + .seconds(140)
        while await endpoint.availability != .available {
            let artifact = try #require(try await model.artifacts.artifactSnapshots().first { $0.artifact.id == id })
            try #require(artifact.phase != .failed, Comment(rawValue: artifact.failure ?? "Download failed"))
            try #require(ContinuousClock.now < deadline, "Timed out preparing Smart Turn")
            try await Task.sleep(for: .milliseconds(200))
        }
        let probability = try #require(try await endpoint.completionProbability(for: samples))
        #expect((0...1).contains(probability))
        try await model.speech.configureSpeechModels(["endpointConfirmation": "off"])
        #expect(try await endpoint.completionProbability(for: samples) == nil)
    } catch {
        try await model.stop()
        throw error
    }
    try await model.stop()
}

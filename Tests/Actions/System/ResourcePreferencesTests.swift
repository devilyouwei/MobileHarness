import AgentCore
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import PlatformKit
import StorageCore
import StorageFiles
import Testing

@testable import Actions
@testable import Agents
@testable import UI

private actor InstalledPreferenceFixture {
    var ids: Set<String> = []
    func set(_ ids: Set<String>) { self.ids = ids }
}

@Test func speechPreferenceModelImpactIncludesParameterChangesOnlyForTheirModels() {
    let previous = ModelResourcePreferences(
        speechModels: ["voiceActivity": "energy-vad", "keywordSpotting": "zipformer-kws", "synthesis": "kokoro-82m"],
        synthesisVoice: "zf_099")
    var changed = previous
    changed.endpoint = "https://hf-mirror.com"
    #expect(ModelResourcePreferencesService.modelChange(from: previous, to: changed).roles.isEmpty)
    changed.vadThreshold = 0.55
    changed.keywordThreshold = 0.40
    changed.synthesisVoice = "af_heart"
    let parameters = ModelResourcePreferencesService.modelChange(from: previous, to: changed)
    #expect(parameters.roles == [.voiceActivity, .keywordSpotting, .synthesis])
    #expect(parameters.modelIDs.isEmpty)
    changed.speechModels?["voiceActivity"] = "silero"
    changed.speechModels?["keywordSpotting"] = "off"
    #expect(ModelResourcePreferencesService.modelChange(from: previous, to: changed).modelIDs == ["silero"])
}
private func preferencesService(
    _ store: FileDocumentStore<ModelResourcePreferences>, installed: InstalledPreferenceFixture
)
    -> ModelResourcePreferencesService
{
    ModelResourcePreferencesService(
        store: { store },
        validate: { value in
            guard value.endpoint.hasPrefix("https://") else { throw ModelResourcePreferenceError.invalidSource }
            var value = value
            value.allowsCellular = true
            return value
        }, installed: { await installed.ids })
}
private actor PreferenceBindingFixture: ModelResourceCapability {
    var calls: [[Bool]] = []
    var failure = false
    func failNext() { failure = true }
    func configureSpeech(recognition: Bool, synthesis: Bool) async throws {
        calls.append([recognition, synthesis])
        if failure {
            failure = false
            throw ModelResourcePreferenceError.invalidSource
        }
    }
    func download(_ id: String, endpoint: String, allowsCellular: Bool) async throws {}
    func cancel(_ id: String) async throws {}
    func remove(_ id: String) async throws {}
}

private actor SpeechModelBindingFixture: ModelResourceCapability {
    var selected: [String: String] = [:]
    var voice: String?
    func configureSpeechModels(_ models: [String: String], synthesisVoice: String?) {
        selected = models
        voice = synthesisVoice
    }
    func configureSpeech(recognition: Bool, synthesis: Bool) throws { throw ModelResourcePreferenceError.invalidSource }
    func download(_ id: String, endpoint: String, allowsCellular: Bool) {}
    func cancel(_ id: String) {}
    func remove(_ id: String) {}
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func saturatedControlMemoryRestoresPreferencesAcrossRootGatewayAndRetainsBoundedEvidence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let seed = try saturatedEvidenceContext(agent: .applicationControl, state: ApplicationControlContextState())
    let repository = try AgentContextRepository(
        agent: seed.agentID, scope: seed.scopeID, state: seed.state
    )
    try await repository.update { $0 = seed }
    let preferences = try FileDocumentStore<ModelResourcePreferences>(
        url: root.appendingPathComponent("source.json"), maximumBytes: 4096)
    let saved = ModelResourcePreferences(
        endpoint: "https://hf-mirror.com", useCustomRecognition: true, useCustomSynthesis: true)
    try await preferences.save(saved, expecting: nil)
    let installed = InstalledPreferenceFixture()
    await installed.set(["nemotron", "moss-tts-nano"])
    let binding = PreferenceBindingFixture()
    let runtime = try await resourceRuntime(
        binding, preferences: preferencesService(preferences, installed: installed), suppliedContext: repository)
    for _ in 0..<2 {
        let result = try await runtime.preferences(.restoreSource)
        let restored = try JSONDecoder().decode(ModelResourcePreferences.self, from: Data(result.utf8))
        #expect(restored == saved)
    }
    #expect(await binding.calls == [[true, true], [true, true]])
    #expect(await runtime.agent.status().lifecycle == .running)
    await runtime.shutdown()
    let snapshot = try await repository.snapshot()
    #expect(snapshot.records.count == 4096 && snapshot.consumedBatches.count == 4096)
    #expect((snapshot.evictedRecordCount ?? 0) >= 4097 && (snapshot.evictedBatchCount ?? 0) >= 4097)
    let reopened = try AgentContextRepository(
        agent: seed.agentID, scope: seed.scopeID, state: seed.state
    )
    #expect(try await reopened.snapshot().records.isEmpty)
    #expect(try await preferences.refresh()?.value == saved)
}
@Test(.actionCatalog) func preferenceCurrentFormatRejectsRemovedSingleSwitch() throws {
    let raw = Data(#"{"endpoint":"https://hf-mirror.com","allowsCellular":false,"preferDownloadedSpeech":true}"#.utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(ModelResourcePreferences.self, from: raw) }
    let value = ModelResourcePreferences(
        endpoint: "https://hf-mirror.com", allowsCellular: false, useCustomRecognition: true, useCustomSynthesis: true)
    let view = try JSONDecoder().decode(ModelResourceSourceDraft.self, from: JSONEncoder().encode(value))
    #expect(view.endpoint == value.endpoint && view.useCustomSynthesis)
}
@Test(.actionCatalog) func preferenceServiceValidatesBeforeCommitAndRestoreMigratesMissingModels() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try FileDocumentStore<ModelResourcePreferences>(
        url: root.appendingPathComponent("source.json"), maximumBytes: 4096)
    let installed = InstalledPreferenceFixture()
    let service = preferencesService(store, installed: installed)
    await installed.set(["silero"])
    await #expect(throws: ModelResourcePreferenceError.recognitionRequired) {
        _ = try await service.saveSource(.init(useCustomRecognition: true))
    }
    await #expect(throws: ModelResourcePreferenceError.invalidSource) {
        _ = try await service.saveSource(.init(endpoint: "bad"))
    }
    #expect(try await store.refresh() == nil)
    await installed.set(["nemotron", "moss-tts-nano"])
    _ = try await service.saveSource(
        .init(endpoint: "https://hf-mirror.com", useCustomRecognition: true, useCustomSynthesis: true))
    await installed.set(["moss-tts-nano"])
    let restored = try await service.restoreSource()
    #expect(!restored.useCustomRecognition && restored.useCustomSynthesis)
    #expect(restored.endpoint == "https://hf-mirror.com")
    #expect(try await store.refresh()?.value == restored)
}
@Test(.actionCatalog) func preferencePipelineKeepsCommitOnBindingFailureAndExplicitRestoreRetries() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try FileDocumentStore<ModelResourcePreferences>(
        url: root.appendingPathComponent("source.json"), maximumBytes: 4096)
    let installed = InstalledPreferenceFixture()
    await installed.set(["nemotron"])
    let binding = PreferenceBindingFixture()
    let runtime = try await resourceRuntime(binding, preferences: preferencesService(store, installed: installed))
    await binding.failNext()
    await #expect(throws: (any Error).self) {
        _ = try await runtime.preferences(
            .saveSource(endpoint: "https://hf-mirror.com", allowsCellular: false, recognition: true, synthesis: false))
    }
    #expect(try await store.refresh()?.value.useCustomRecognition == true)
    let raw = try await runtime.preferences(.restoreSource)
    let result = try JSONDecoder().decode(ModelResourcePreferences.self, from: Data(raw.utf8))
    #expect(result.endpoint == "https://hf-mirror.com" && result.allowsCellular && result.useCustomRecognition)
    #expect(await binding.calls == [[true, false], [true, false]])
    #expect(await runtime.agent.status().queuedInputs == 0)
    await runtime.shutdown()
}
@Test(.actionCatalog) func preferenceRestoreMigratesNetworkAndFlagsBeforeReturningBinding() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try FileDocumentStore<ModelResourcePreferences>(
        url: root.appendingPathComponent("source.json"), maximumBytes: 4096)
    try await store.save(
        .init(allowsCellular: false, useCustomRecognition: true, useCustomSynthesis: true), expecting: nil)
    let installed = InstalledPreferenceFixture()
    let binding = PreferenceBindingFixture()
    let runtime = try await resourceRuntime(binding, preferences: preferencesService(store, installed: installed))
    _ = try await runtime.preferences(.restoreSource)
    let value = try #require(await store.refresh()?.value)
    #expect(value.allowsCellular && !value.useCustomRecognition && !value.useCustomSynthesis)
    #expect(await binding.calls == [[false, false]])
    await runtime.shutdown()
}

@Test(.actionCatalog) func preferenceAgentRejectsMalformedFeedbackAndRetirementReleasesTransaction() async throws {
    let session = UUID().uuidString
    let agent = try ApplicationControlAgent(
        sessionID: session,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "applicationControl"), scope: UUID().uuidString,
            state: ApplicationControlContextState())
    )
    try await agent.start()
    var outputs = agent.outputs.makeAsyncIterator()
    let request = try ModelResourceIntent.restoreSource.input(sessionID: session)
    try await agent.receive(request)
    let envelope = try #require(await outputs.next())
    guard case .toolCall(let call) = envelope.output else {
        Issue.record("Expected preference read")
        return
    }
    let payload = InputPayload.toolResult(
        ToolResult(
            callID: call.id,
            value:
                #"{"endpoint":"https://example.invalid","allowsCellular":true,"useCustomRecognition":"yes","useCustomSynthesis":false}"#
        ))
    await #expect(throws: (any Error).self) {
        try await agent.receive(
            AgentInput(
                id: UUID().uuidString,
                sessionID: session, payload: payload,
                metadata: InputMetadata(
                    payload: payload, source: "runtime", origin: .runtime, rootID: UUID().uuidString)))
    }
    await #expect(throws: CommunicationError.capacityExceeded) {
        try await agent.receive(ModelResourceIntent.restoreSource.input(sessionID: session))
    }
    try await agent.receive(ModelResourceIntent.retire(request.id).input(sessionID: session))
    try await agent.receive(ModelResourceIntent.restoreSource.input(sessionID: session))
    #expect(await agent.status().queuedInputs == 1)
    await agent.stop()
}

private enum PreferencePresentationError: Error { case preferencePresentation }
private actor PreferencePresentationFixture: ResourcePresentationCapability {
    var reasons: [ResourcePreferenceFailureReason] = []
    var messages: [String] = []
    var fails = false
    var holds = false
    private var release: CheckedContinuation<Void, Never>?
    nonisolated let entered: AsyncStream<ResourcePreferenceFailureReason>
    private let enteredContinuation: AsyncStream<ResourcePreferenceFailureReason>.Continuation
    init() {
        let pair = AsyncStream<ResourcePreferenceFailureReason>.makeStream(bufferingPolicy: .bufferingOldest(8))
        entered = pair.stream
        enteredContinuation = pair.continuation
    }
    func hold() { holds = true }
    func fail() { fails = true }
    func resume() {
        holds = false
        release?.resume()
        release = nil
    }
    func presentResources(_ inventory: ModelResourceInventory, generation: UInt64, invocation: any FunctionInput)
        throws
    { throw CancellationError() }
    func presentResourceFailure(_ message: String, generation: UInt64, invocation: any FunctionInput) throws {
        throw CancellationError()
    }
    func presentResourceOperationFailure(_ message: String, invocation: any FunctionInput) throws {
        throw CancellationError()
    }
    func presentResourcePreferenceFailure(
        _ reason: ResourcePreferenceFailureReason, message: String, invocation: any FunctionInput
    ) async throws {
        reasons.append(reason)
        messages.append(message)
        if holds {
            await withCheckedContinuation { continuation in
                release = continuation
                if case .dropped = enteredContinuation.yield(reason) { Issue.record("Fixture entry queue overflow") }
            }
        }
        try Task.checkCancellation()
        if fails { throw PreferencePresentationError.preferencePresentation }
    }
}
@Test(.actionCatalog) func preferenceFailureCodesSelectRegisteredNoticeReasonsWithoutBindingOrCommit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try FileDocumentStore<ModelResourcePreferences>(
        url: root.appendingPathComponent("source.json"), maximumBytes: 4096)
    let installed = InstalledPreferenceFixture()
    let binding = PreferenceBindingFixture()
    let presentation = PreferencePresentationFixture()
    let runtime = try await resourceRuntime(
        binding, preferences: preferencesService(store, installed: installed), presentation: presentation)
    for intent in [
        ModelResourceIntent.saveSource(endpoint: "bad", allowsCellular: true, recognition: false, synthesis: false),
        .saveSource(endpoint: "https://huggingface.co", allowsCellular: true, recognition: true, synthesis: false),
        .saveSource(endpoint: "https://huggingface.co", allowsCellular: true, recognition: false, synthesis: true),
    ] {
        await #expect(throws: ApplicationControlIntentFailure.self) { _ = try await runtime.preferences(intent) }
    }
    #expect(await presentation.reasons == [.invalidSource, .recognitionRequired, .synthesisRequired])
    #expect(await presentation.messages.count == 3)
    #expect(await binding.calls.isEmpty)
    #expect(try await store.refresh() == nil)
    #expect(await runtime.agent.status().queuedInputs == 0)
    await runtime.shutdown()
}
@Test(.actionCatalog) func bindingFailureUsesThirdPresentationCallAndPreservesDurablePreference() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try FileDocumentStore<ModelResourcePreferences>(
        url: root.appendingPathComponent("source.json"), maximumBytes: 4096)
    let installed = InstalledPreferenceFixture()
    await installed.set(["nemotron"])
    let binding = PreferenceBindingFixture()
    let presentation = PreferencePresentationFixture()
    let runtime = try await resourceRuntime(
        binding, preferences: preferencesService(store, installed: installed), presentation: presentation)
    await binding.failNext()
    do {
        _ = try await runtime.preferences(
            .saveSource(endpoint: "https://hf-mirror.com", allowsCellular: true, recognition: true, synthesis: false))
        Issue.record("Binding failure must remain failed after presentation")
    } catch ApplicationControlIntentFailure.presented(let message) {
        #expect(message.contains("resource.source.invalid"))
    }
    #expect(await presentation.reasons == [.execution])
    #expect(await binding.calls == [[true, false]])
    #expect(try await store.refresh()?.value.useCustomRecognition == true)
    #expect(try await store.refresh()?.value.endpoint == "https://hf-mirror.com")
    #expect(await runtime.agent.status().queuedInputs == 0)
    _ = try await runtime.preferences(.restoreSource)
    #expect(await binding.calls == [[true, false], [true, false]])
    #expect(await presentation.reasons == [.execution])
    await runtime.shutdown()
}
@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: [false, true])
func preferenceGateStaysHeldUntilFailurePresentationCompletes(
    bindingFailure: Bool
) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try FileDocumentStore<ModelResourcePreferences>(
        url: root.appendingPathComponent("source.json"), maximumBytes: 4096)
    let installed = InstalledPreferenceFixture()
    let binding = PreferenceBindingFixture()
    if bindingFailure {
        await installed.set(["nemotron"])
        await binding.failNext()
    }
    let presentation = PreferencePresentationFixture()
    await presentation.hold()
    var entries = presentation.entered.makeAsyncIterator()
    let runtime = try await resourceRuntime(
        binding, preferences: preferencesService(store, installed: installed), presentation: presentation)
    let request = Task {
        try await runtime.preferences(
            .saveSource(endpoint: "https://huggingface.co", allowsCellular: true, recognition: true, synthesis: false))
    }
    #expect(await entries.next() == (bindingFailure ? .execution : .recognitionRequired))
    let queued = Task { try await runtime.preferences(.restoreSource) }
    for _ in 0..<200 {
        if await runtime.resources.requests.outstanding == 2 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await runtime.resources.requests.outstanding == 2)
    queued.cancel()
    await #expect(throws: CancellationError.self) { _ = try await queued.value }
    #expect(await binding.calls == (bindingFailure ? [[true, false]] : []))
    await presentation.resume()
    do {
        _ = try await request.value
        Issue.record("Validation/binding failure must terminate failed")
    } catch ApplicationControlIntentFailure.presented {}
    await installed.set(["nemotron"])
    _ = try await runtime.preferences(
        .saveSource(endpoint: "https://huggingface.co", allowsCellular: true, recognition: true, synthesis: false))
    #expect(await binding.calls == (bindingFailure ? [[true, false], [true, false]] : [[true, false]]))
    #expect(await runtime.agent.status().queuedInputs == 0)
    await runtime.shutdown()
}
@Test(.actionCatalog) func preferencePresentationFailureAndMissingHandlerRetainCausesAndReleaseGate() async throws {
    for missing in [false, true] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileDocumentStore<ModelResourcePreferences>(
            url: root.appendingPathComponent("source.json"), maximumBytes: 4096)
        let installed = InstalledPreferenceFixture()
        let binding = PreferenceBindingFixture()
        let presentation = PreferencePresentationFixture()
        await presentation.fail()
        let runtime = try await resourceRuntime(
            binding, preferences: preferencesService(store, installed: installed), presentation: presentation,
            includePreferenceFailurePresentation: !missing)
        do {
            _ = try await runtime.preferences(
                .saveSource(
                    endpoint: "https://huggingface.co", allowsCellular: true, recognition: true, synthesis: false))
            Issue.record("Missing or failed presentation must not claim accepted state")
        } catch ApplicationControlIntentFailure.execution(let message) {
            #expect(message.contains("resource.selection.recognition"))
            #expect(message.contains(missing ? "Unknown tool" : "preferencePresentation"))
        }
        #expect(await presentation.reasons.count == (missing ? 0 : 1))
        #expect(await runtime.agent.status().queuedInputs == 0)
        await installed.set(["nemotron"])
        _ = try await runtime.preferences(
            .saveSource(endpoint: "https://huggingface.co", allowsCellular: true, recognition: true, synthesis: false))
        #expect(await binding.calls == [[true, false]])
        await runtime.shutdown()
    }
}
private struct SpoofedPreferenceFailure: ModelResourcePreferencesCapability {
    func restoreSource() throws -> ModelResourcePreferences {
        throw ActionExecutionFailure(code: .handlerFailed, message: "resource.selection.recognition")
    }
    func saveSource(_ preferences: ModelResourcePreferences) throws -> ModelResourcePreferences { try restoreSource() }
}
@Test(.actionCatalog) func preferenceFailureTextDoesNotSubstituteForProducerCode() async throws {
    let presentation = PreferencePresentationFixture()
    let runtime = try await resourceRuntime(
        UnusedModelResourceCapability(), preferences: SpoofedPreferenceFailure(), presentation: presentation)
    do {
        _ = try await runtime.preferences(.restoreSource)
        Issue.record("Fixture must fail")
    } catch ApplicationControlIntentFailure.presented {}
    #expect(await presentation.reasons == [.execution])
    await runtime.shutdown()
}
@Test(.actionCatalog) func preferenceFailureFunctionValidatesReasonsAndMessageBeforeEndpoint() async throws {
    let presentation = PreferencePresentationFixture()
    func invocation(_ reason: String, message: String = "fixture failure") -> FunctionInvocation {
        FunctionInvocation(
            call: FunctionRequest(
                actionPath: ActionIdentifier(
                    domain: "UI", module: "ResourcePresentation", function: "showResourcePreferenceFailure"),
                parameters: ["reason": reason, "message": message]),
            context: ActionExecutionContext(
                source: "fixture", sessionID: UUID().uuidString, inputID: UUID().uuidString),
            executionID: UUID().uuidString,
            results: ActionReportStore())
    }
    await #expect(throws: ActionArguments.ValidationError.self) {
        _ = try await UIActions.showResourcePreferenceFailure(invocation: invocation("unknown"), using: presentation)
    }
    await #expect(throws: ActionArguments.ValidationError.self) {
        _ = try await UIActions.showResourcePreferenceFailure(
            invocation: invocation("execution", message: String(repeating: "x", count: 2049)), using: presentation)
    }
    #expect(await presentation.reasons.isEmpty)
    for reason in [ResourcePreferenceFailureReason.recognitionRequired, .synthesisRequired, .invalidSource, .execution]
    {
        try await UIActions.showResourcePreferenceFailure(
            invocation: invocation(reason.rawValue), using: presentation)
    }
    #expect(await presentation.reasons == [.recognitionRequired, .synthesisRequired, .invalidSource, .execution])
}

@Test(.actionCatalog) func resourcePreferencesRestoresOriginalDocumentWithoutReset() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("download-source.json")
    let original = Data(
        #"{"version":1,"revision":"00000000-0000-0000-0000-000000000124","value":{"endpoint":"https://hf-mirror.com","allowsCellular":true,"useCustomRecognition":true,"useCustomSynthesis":true}}"#
            .utf8)
    try original.write(to: url)
    let installed = InstalledPreferenceFixture()
    await installed.set(["nemotron", "moss-tts-nano"])
    let service = preferencesService(try FileDocumentStore(url: url), installed: installed)
    let restored = try await service.restoreSource()
    #expect(restored.endpoint == "https://hf-mirror.com")
    #expect(restored.useCustomRecognition && restored.useCustomSynthesis)
    #expect(try Data(contentsOf: url) == original)
    var updated = restored
    updated.endpoint = "https://huggingface.co"
    _ = try await service.saveSource(updated)
    let reopened = try FileDocumentStore<ModelResourcePreferences>(url: url)
    #expect(try await reopened.load()?.value == updated)
    let envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    #expect(envelope["version"] as? Int == 1)
}

@Test(arguments: ["zh", "zh-Hans-CN", "zh-Hant-TW", "zh_CN", "en-US", "fr-FR", ""])
func resourceSourceDefaultsFollowSystemLanguageAndKeepSavedChoice(language: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try FileDocumentStore<ModelResourcePreferences>(
        url: root.appendingPathComponent("source.json"), maximumBytes: 4096)
    let service = ModelResourcePreferencesService(
        store: { store }, validate: { $0 }, installed: { [] },
        preferredLanguage: { language.isEmpty ? nil : language })
    let expected = language.hasPrefix("zh") ? "https://hf-mirror.com" : "https://huggingface.co"
    #expect(try await service.restoreSource().endpoint == expected)
    let explicit = ModelResourcePreferences(endpoint: "https://custom.example")
    _ = try await service.saveSource(explicit)
    #expect(try await service.restoreSource() == explicit)
}

@Test func speechDetectionPreferencesRoundTripAndLegacyDefaults() throws {
    let old = Data(
        #"{"endpoint":"https://huggingface.co","allowsCellular":true,"useCustomRecognition":false,"useCustomSynthesis":false}"#
            .utf8)
    let defaults = try JSONDecoder().decode(ModelResourcePreferences.self, from: old)
    #expect(defaults.vadOnsetWindows == 8)
    #expect(defaults.vadThreshold == 0.65)
    var changed = defaults
    changed.vadOnsetWindows = 16
    changed.vadThreshold = 0.9
    let draft = try JSONDecoder().decode(ModelResourceSourceDraft.self, from: JSONEncoder().encode(changed))
    let result = try ApplicationControlResourcePolicy.preferenceValue(changed.encoded())
    #expect(result.vadOnsetWindows == 16)
    #expect(result.vadThreshold == 0.9)
    #expect(draft.vadOnsetWindows == 16)
    #expect(draft.vadThreshold == 0.9)
    #expect(try JSONDecoder().decode(ModelResourcePreferences.self, from: JSONEncoder().encode(draft)) == changed)
    #expect(try SettingsModelResourcesAdapter.validatePreferences(changed) == changed)
    changed.vadThreshold = 0.66
    #expect(throws: ModelResourcePreferenceError.invalidDetection) {
        try SettingsModelResourcesAdapter.validatePreferences(changed)
    }
    changed.vadThreshold = 0.65
    changed.vadOnsetWindows = 17
    #expect(throws: ModelResourcePreferenceError.invalidDetection) {
        try SettingsModelResourcesAdapter.validatePreferences(changed)
    }
}

@Test func speechEnhancementPreferenceRequiresInstallationAndDisablesAfterRemoval() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try FileDocumentStore<ModelResourcePreferences>(
        url: root.appendingPathComponent("source.json"), maximumBytes: 4096)
    let installed = InstalledPreferenceFixture()
    let service = preferencesService(store, installed: installed)
    await #expect(throws: ModelResourcePreferenceError.enhancementRequired) {
        try await service.saveSource(.init(useSpeechEnhancement: true))
    }
    await installed.set(["deepfilternet3"])
    let saved = try await service.saveSource(.init(useSpeechEnhancement: true))
    #expect(saved.useSpeechEnhancement && !saved.useCustomRecognition)
    let draft = try JSONDecoder().decode(ModelResourceSourceDraft.self, from: JSONEncoder().encode(saved))
    #expect(draft.useSpeechEnhancement)
    await installed.set([])
    #expect(try await !service.restoreSource().useSpeechEnhancement)
    #expect(try await store.refresh()?.value.useSpeechEnhancement == false)
    let legacy = Data(
        #"{"endpoint":"https://huggingface.co","allowsCellular":true,"useCustomRecognition":false,"useCustomSynthesis":false}"#
            .utf8)
    #expect(try !JSONDecoder().decode(ModelResourcePreferences.self, from: legacy).useSpeechEnhancement)
    #expect(try !JSONDecoder().decode(ModelResourceSourceDraft.self, from: legacy).useSpeechEnhancement)
}

@Test(.actionCatalog) func keywordInterruptPreferenceUsesResourceGatewayAndResetsAfterRemoval() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try FileDocumentStore<ModelResourcePreferences>(
        url: root.appendingPathComponent("source.json"), maximumBytes: 4096)
    let installed = InstalledPreferenceFixture()
    let service = preferencesService(store, installed: installed)
    await #expect(throws: ModelResourcePreferenceError.keywordInterruptRequired) {
        try await service.saveSource(.init(useKeywordInterrupt: true))
    }

    await installed.set(["zipformer-kws"])
    let runtime = try await resourceRuntime(PreferenceBindingFixture(), preferences: service)
    let result = try await runtime.preferences(
        .saveSource(
            endpoint: "https://huggingface.co", allowsCellular: true,
            recognition: false, synthesis: false, keywordInterrupt: true, keywordThreshold: 0.20))
    let saved = try JSONDecoder().decode(ModelResourceSourceDraft.self, from: Data(result.utf8))
    #expect(saved.useKeywordInterrupt)
    #expect(saved.keywordThreshold == 0.20)
    #expect(try await store.refresh()?.value.useKeywordInterrupt == true)
    await installed.set([])
    let restored = try await runtime.preferences(.restoreSource)
    let afterRemoval = try JSONDecoder().decode(ModelResourceSourceDraft.self, from: Data(restored.utf8))
    #expect(!afterRemoval.useKeywordInterrupt)
    #expect(afterRemoval.keywordThreshold == 0.20)
    #expect(try await store.refresh()?.value.useKeywordInterrupt == false)
    await runtime.shutdown()

    let legacy = Data(
        #"{"endpoint":"https://huggingface.co","allowsCellular":true,"useCustomRecognition":false,"useCustomSynthesis":false}"#
            .utf8)
    #expect(try !JSONDecoder().decode(ModelResourcePreferences.self, from: legacy).useKeywordInterrupt)
    #expect(try !JSONDecoder().decode(ModelResourceSourceDraft.self, from: legacy).useKeywordInterrupt)
    #expect(try JSONDecoder().decode(ModelResourcePreferences.self, from: legacy).keywordThreshold == 0.25)
    #expect(try JSONDecoder().decode(ModelResourceSourceDraft.self, from: legacy).keywordThreshold == 0.25)
}

@Test func speechSelectionMigratesPreferencesAndKeepsInstalledSileroOptIn() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try FileDocumentStore<ModelResourcePreferences>(
        url: root.appendingPathComponent("source.json"), maximumBytes: 4096)
    let installed = InstalledPreferenceFixture()
    await installed.set(["silero", "nemotron", "deepfilternet3"])
    let service = preferencesService(store, installed: installed)
    try await store.save(.init(useCustomRecognition: true, useSpeechEnhancement: true), expecting: nil)
    var restored = try await service.restoreSource()
    #expect(restored.speechModels?["voiceActivity"] == "energy-vad")
    #expect(restored.speechModels?["recognition"] == "nemotron-local")
    #expect(restored.speechModels?["enhancement"] == "deepfilternet3")
    #expect(restored.speechModels?["keywordSpotting"] == "off")
    restored.speechModels?["voiceActivity"] = "silero"
    #expect(try await service.saveSource(restored).speechModels?["voiceActivity"] == "silero")
    await installed.set(["nemotron", "deepfilternet3"])
    let afterRemoval = try await service.restoreSource()
    #expect(afterRemoval.speechModels?["voiceActivity"] == "energy-vad")
    #expect(afterRemoval.speechModels?["recognition"] == "nemotron-local")
    #expect(afterRemoval.speechModels?["enhancement"] == "deepfilternet3")
}

@Test func smartTurnSelectionRequiresInstallationAndRestoresOffAfterRemoval() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try FileDocumentStore<ModelResourcePreferences>(
        url: root.appendingPathComponent("source.json"), maximumBytes: 4096)
    let installed = InstalledPreferenceFixture()
    let service = preferencesService(store, installed: installed)
    var source = try await service.restoreSource()
    #expect(source.speechModels?["endpointConfirmation"] == "off")
    source.speechModels?["endpointConfirmation"] = "smart-turn"
    await #expect(throws: ModelResourcePreferenceError.endpointConfirmationRequired) {
        try await service.saveSource(source)
    }
    await installed.set(["smart-turn"])
    #expect(try await service.saveSource(source).speechModels?["endpointConfirmation"] == "smart-turn")
    await installed.set([])
    #expect(try await service.restoreSource().speechModels?["endpointConfirmation"] == "off")
}

@Test(.actionCatalog) func speechSelectionUsesResourceGatewayToBindModelIDs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try FileDocumentStore<ModelResourcePreferences>(
        url: root.appendingPathComponent("source.json"), maximumBytes: 4096)
    let installed = InstalledPreferenceFixture()
    await installed.set(["silero", "zipformer-kws", "smart-turn", "kokoro-82m"])
    let binding = SpeechModelBindingFixture()
    let runtime = try await resourceRuntime(binding, preferences: preferencesService(store, installed: installed))

    let result = try await runtime.preferences(
        .saveSource(
            endpoint: "https://huggingface.co", allowsCellular: true, recognition: false, synthesis: false,
            speechModels: [
                "voiceActivity": "silero", "keywordSpotting": "zipformer-kws", "endpointConfirmation": "smart-turn",
                "synthesis": "kokoro-82m",
            ],
            synthesisVoice: "zf_099"))
    let saved = try JSONDecoder().decode(ModelResourceSourceDraft.self, from: Data(result.utf8))
    #expect(saved.speechModels == (await binding.selected))
    #expect(saved.speechModels?["voiceActivity"] == "silero")
    #expect(saved.speechModels?["keywordSpotting"] == "zipformer-kws")
    #expect(saved.speechModels?["endpointConfirmation"] == "smart-turn")
    #expect(saved.useKeywordInterrupt)
    #expect(saved.synthesisVoice == "zf_099")
    #expect(await binding.voice == saved.synthesisVoice)
    guard case .source(var draft) = try await runtime.resources.requests.submit(.restore) else {
        Issue.record("Expected restored speech settings")
        return
    }
    try #require(draft.speechModels?.count == 6)
    draft.speechModels?["endpointConfirmation"] = "off"
    guard case .source(let updated) = try await runtime.resources.requests.submit(.save(draft)) else {
        Issue.record("Expected saved speech settings")
        return
    }
    #expect(updated.speechModels == draft.speechModels)
    #expect(await binding.selected == draft.speechModels)
    #expect(updated.synthesisVoice == "zf_099")
    var invalid = try #require(try await store.refresh()?.value)
    invalid.synthesisVoice = "jf_alpha"
    await #expect(throws: ModelResourcePreferenceError.invalidSpeechModel) {
        _ = try await preferencesService(store, installed: installed).saveSource(invalid)
    }

    await installed.set(["silero"])
    _ = try await runtime.preferences(.restoreSource)
    let restored = await binding.selected
    #expect(restored["voiceActivity"] == "silero")
    #expect(restored["keywordSpotting"] == "off")
    #expect(restored["endpointConfirmation"] == "off")
    #expect(restored["synthesis"] == "apple-synthesis")
    #expect(await binding.voice == "zf_099")
    await runtime.shutdown()
}

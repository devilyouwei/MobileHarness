import Actions
import AgentCore
import Agents
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import PlatformKit
import StorageCore
import StorageFiles
import Testing

@testable import UI

private actor InstalledPreferenceFixture {
    var ids: Set<String> = []
    func set(_ ids: Set<String>) { self.ids = ids }
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
@Test(.actionCatalog) func preferenceLegacyDocumentAndViewDraftRemainWireCompatible() throws {
    let raw = Data(#"{"endpoint":"https://hf-mirror.com","allowsCellular":false,"preferDownloadedSpeech":true}"#.utf8)
    let value = try JSONDecoder().decode(ModelResourcePreferences.self, from: raw)
    #expect(value.useCustomRecognition && value.useCustomSynthesis && !value.allowsCellular)
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
        let result = try await UIActions.showResourcePreferenceFailure(
            invocation: invocation(reason.rawValue), using: presentation)
        #expect(result == "presented")
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

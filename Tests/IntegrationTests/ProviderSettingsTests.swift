import Actions
import AgentCore
import Foundation
import FunctionContracts
import Gateway
import PlatformKit
import StorageCore
import StorageFiles
import Testing
import UI

@testable import Agents

@MainActor
private final class ProviderTransactionFixture: ProviderSettingsPersistence {
    var value: ProviderSettings? = .init(
        enabled: false, url: "https://example.invalid", key: "fixture-secret", model: "old")
    var events: [String] = []
    var rollbackFails = false
    var applyCancelled = false
    var failApply = true
    func load() async throws -> ProviderSettings? { value }
    func save(_ value: ProviderSettings?) async throws {
        events.append("persist:\(value?.model ?? "nil")")
        #expect(!Task.isCancelled)
        if rollbackFails, value?.model == "old" { throw ProviderSettingsError.persistence }
        self.value = value
    }
    func service() -> ProviderSettingsService {
        ProviderSettingsService(
            store: self,
            runtime: .init(
                initial: .init(enabled: false, url: "https://example.invalid", key: "", model: "default"),
                prepare: { value in
                    self.events.append("prepare:\(value?.model ?? "nil")")
                    if value?.model == "invalid" { throw ProviderSettingsError.invalidConfiguration }
                    return {
                        self.events.append("apply:\(value?.model ?? "nil")")
                        if value?.model == "new", self.applyCancelled {
                            withUnsafeCurrentTask { $0?.cancel() }
                            throw CancellationError()
                        }
                        if value?.model == "new", self.failApply { throw ProviderSettingsError.application }
                    }
                }, beginChange: { self.events.append("begin") }, endChange: { self.events.append("end") }))
    }
}
@Test(.actionCatalog) @MainActor func providerSettingsFailureRollsBackBeforeReleasingChangeBarrier() async throws {
    let fixture = ProviderTransactionFixture()
    let service = fixture.service()
    _ = try await service.restore()
    fixture.events.removeAll()
    await #expect(throws: ProviderSettingsError.self) {
        _ = try await service.save(
            .init(
                enabled: true, url: "https://example.invalid", key: "fixture-secret", model: "new", writerThinking: true
            ))
    }
    #expect(fixture.events == ["prepare:new", "begin", "persist:new", "apply:new", "persist:old", "end"])
    #expect(fixture.value?.model == "old")
    #expect(try await service.restore().model == "old")
    #expect(try await service.restore().writerThinking == false)
}
@Test(.actionCatalog) @MainActor func providerSettingsValidationPrecedesPersistenceAndBarrier() async throws {
    let fixture = ProviderTransactionFixture()
    let service = fixture.service()
    _ = try await service.restore()
    fixture.events.removeAll()
    await #expect(throws: ProviderSettingsError.self) {
        _ = try await service.save(
            .init(enabled: true, url: "https://example.invalid", key: "fixture-secret", model: "invalid"))
    }
    #expect(fixture.events == ["prepare:invalid"])
    #expect(fixture.value?.model == "old")
}

@Test @MainActor func agentBrainDecisionMigratesAndSavesWithoutReconfiguringAssistant() async throws {
    let fixture = ProviderTransactionFixture()
    let initial = try #require(fixture.value)
    let runtime = ProviderSettingsRuntime(
        initial: initial, prepare: { _ in { fixture.events.append("apply") } },
        beginChange: { fixture.events.append("begin") }, endChange: { fixture.events.append("end") })
    let service = ProviderSettingsService(store: fixture, runtime: runtime, legacyDecision: { true })
    var settings = try await service.restore()
    #expect(settings.decisionUsesLocal == true)
    #expect(fixture.value?.decisionUsesLocal == nil)
    fixture.events.removeAll()
    settings.decisionUsesLocal = false
    _ = try await service.save(settings)
    #expect(fixture.events == ["persist:old"])
    #expect(fixture.value?.decisionUsesLocal == false)

    let reopened = ProviderSettingsService(store: fixture, runtime: runtime, legacyDecision: { true })
    #expect(try await reopened.restore().decisionUsesLocal == false)
    settings.decisionUsesLocal = true
    await #expect(throws: ProviderSettingsError.self) { _ = try await reopened.save(settings) }
    #expect(fixture.value?.decisionUsesLocal == false)
}

@Test @MainActor func agentBrainDecisionReadsCommittedSnapshotDuringSave() async throws {
    let fixture = ProviderTransactionFixture()
    let initial = try #require(fixture.value)
    var service: ProviderSettingsService?
    let runtime = ProviderSettingsRuntime(
        initial: initial, prepare: { _ in {} },
        beginChange: {
            do {
                let inFlight = try await service?.decisionSnapshot()
                #expect(inFlight?.decisionUsesLocal == true)
            } catch {
                Issue.record("Expected committed Decision configuration while saving: \(error)")
            }
        }, endChange: {})
    let settings = ProviderSettingsService(store: fixture, runtime: runtime, legacyDecision: { true })
    service = settings
    defer { service = nil }
    _ = try await settings.restore()
    let next = ProviderSettings(
        enabled: true, url: initial.url, key: initial.key, model: initial.model, decisionUsesLocal: false)
    _ = try await settings.save(next)
    #expect(try await settings.decisionSnapshot().decisionUsesLocal == false)
}

@Test(.actionCatalog) @MainActor func providerSettingsReturningPipelineKeepsPrivateResultsAndRollbackCauses()
    async throws
{
    let fixture = ProviderTransactionFixture()
    let requests = ProviderSettingsRequests(service: fixture.service())
    let runtime = try await resourceRuntime(UnusedModelResourceCapability(), providerSettings: requests)
    let restored = try await runtime.restoreSettings()
    #expect(restored.key == "fixture-secret" && restored.model == "old")
    fixture.events.removeAll()
    fixture.rollbackFails = true
    do {
        try await runtime.saveSettings(
            .init(enabled: true, url: "https://example.invalid", key: "fixture-secret", model: "new"))
        Issue.record("Failed rollback must fail the request")
    } catch let error as ProviderIntentFailure {
        #expect(error.failureCode == "provider.rollback")
        #expect(error.message.contains("provider.application") && error.message.contains("provider.persistence"))
        #expect(!error.message.contains("fixture-secret"))
    }
    #expect(fixture.events.last == "end" && fixture.value?.model == "new")
    #expect(await runtime.agent.status().queuedInputs == 0)
    #expect(try await runtime.restoreSettings().model == "old")
    await runtime.shutdown()
}
@Test(.actionCatalog) @MainActor func providerSettingsCancelledApplyStillRollsBackBeforeRelease() async throws {
    let fixture = ProviderTransactionFixture()
    fixture.applyCancelled = true
    let service = fixture.service()
    _ = try await service.restore()
    fixture.events.removeAll()
    let saving = Task {
        try await service.save(
            .init(enabled: true, url: "https://example.invalid", key: "fixture-secret", model: "new"))
    }
    await #expect(throws: ProviderSettingsError.self) { _ = try await saving.value }
    #expect(fixture.events == ["prepare:new", "begin", "persist:new", "apply:new", "persist:old", "end"])
    #expect(fixture.value?.model == "old")
}
@Test(.actionCatalog) func providerSettingsAgentSharesConfigurationGateAndKeepsCallsOpaque() async throws {
    let session = UUID().uuidString
    let agent = try ApplicationControlAgent(
        sessionID: session,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "applicationControl"), scope: UUID().uuidString,
            state: ApplicationControlContextState())
    )
    try await agent.start()
    let intent = ProviderSettingsIntent(operation: .save, requestID: UUID().uuidString)
    let input = try intent.input(sessionID: session)
    try await agent.receive(input)
    var iterator = agent.outputs.makeAsyncIterator()
    guard case .toolCall(let call) = await iterator.next()?.output else {
        Issue.record("Missing save call")
        return
    }
    #expect(call.arguments == ["requestID": intent.requestID])
    #expect(call.toolPath == "System.Provider.saveSettings")
    await #expect(throws: CommunicationError.self) {
        try await agent.receive(
            ModelResourceIntent.configureSpeech(recognition: true, synthesis: false).input(sessionID: session))
    }
    try await agent.receive(ModelResourceIntent.retire(input.id).input(sessionID: session))
    try await agent.receive(
        ModelResourceIntent.configureSpeech(recognition: true, synthesis: false).input(sessionID: session))
    await agent.stop()
}

private final class ProviderSettingsClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.withLock { value } }
    func advance() { lock.withLock { value = value.advanced(by: .seconds(11)) } }
}
@Test(.actionCatalog) @MainActor func providerSettingsPrivateSlotsCheckSessionOperationExpiryAndCompletedCapacity()
    async throws
{
    let fixture = ProviderTransactionFixture()
    let clock = ProviderSettingsClock()
    let requests = ProviderSettingsRequests(service: fixture.service(), clock: { clock.now() })
    let session = UUID().uuidString
    let id = try requests.stageRestore(sessionID: session)
    await #expect(throws: ProviderSettingsError.self) {
        try await requests.saveSettings(requestID: id, sessionID: session)
    }
    await #expect(throws: ProviderSettingsError.self) {
        try await requests.restoreSettings(requestID: id, sessionID: UUID().uuidString)
    }
    try await requests.restoreSettings(requestID: id, sessionID: session)
    #expect(throws: ProviderSettingsError.self) { try requests.take(id, sessionID: UUID().uuidString) }
    for _ in 0..<31 { _ = try requests.stageRestore(sessionID: session) }
    #expect(throws: ProviderSettingsError.self) { try requests.stageRestore(sessionID: session) }
    clock.advance()
    _ = try requests.stageRestore(sessionID: session)
    #expect(try requests.take(id, sessionID: session).key == "fixture-secret")
    #expect(throws: ProviderSettingsError.self) { try requests.take(id, sessionID: session) }
}
private final class ProviderCredentialFixture: ProviderCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: Data] = [:]
    private var actions: [String] = []
    func key(id: String) throws -> Data? {
        lock.withLock {
            actions.append("readKey")
            return keys[id]
        }
    }
    func insertKey(_ data: Data, id: String) throws {
        lock.withLock {
            actions.append("insertKey")
            keys[id] = data
        }
    }
    func removeKey(id: String) throws {
        lock.withLock {
            actions.append("removeKey")
            keys[id] = nil
        }
    }
    var events: [String] { lock.withLock { actions } }
    var keyCount: Int { lock.withLock { keys.count } }
}
@Test(.actionCatalog) func providerSettingsStorePersistsCurrentFormatAndCleansFailedCredentialCommit() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "provider-settings-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let credentials = ProviderCredentialFixture()
    let store = ProviderSettingsStore(
        credentials: credentials, document: { try FileDocumentStore<UserSettingsDocument>(url: url) })
    #expect(try await store.load() == nil)
    let value = ProviderSettings(enabled: true, url: "https://example.invalid", key: "fixture-secret", model: "current")
    try await store.save(value)
    #expect(try await store.load()?.key == "fixture-secret")
    #expect(credentials.events == ["insertKey", "readKey"])
    #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("fixture-secret"))
    // External replacement invalidates the revision; new credential must be removed before returning failure.
    try Data("external replacement".utf8).write(to: url, options: .atomic)
    await #expect(throws: (any Error).self) { try await store.save(value) }
    #expect(credentials.keyCount == 1)
    #expect(credentials.events.suffix(2) == ["insertKey", "removeKey"])
}

@MainActor private final class ProviderResultPresentationFixture: ResourcePresentationCapability {
    let requests: ProviderSettingsRequests
    var ids: [String] = []
    var failures: [String?] = []
    var reject = false
    init(_ requests: ProviderSettingsRequests) { self.requests = requests }
    func presentProviderResult(requestID: String, failureCode: String?, invocation: any FunctionInput) async throws {
        ids.append(requestID)
        failures.append(failureCode)
        #expect(invocation.call.parameters.keys.allSatisfy { ["requestID", "failureCode"].contains($0) })
        if reject { throw ResourcePresentationError.unavailable }
        if failureCode == nil {
            #expect(try requests.result(requestID, sessionID: invocation.context.sessionID).key == "fixture-secret")
        }
    }
    func presentResources(_ inventory: ModelResourceInventory, generation: UInt64, invocation: any FunctionInput)
        async throws
    { throw CancellationError() }
    func presentResourcePreferenceFailure(
        _ reason: ResourcePreferenceFailureReason, message: String, invocation: any FunctionInput
    ) async throws { throw CancellationError() }
    func presentResourceOperationFailure(_ message: String, invocation: any FunctionInput) async throws {
        throw CancellationError()
    }
    func presentResourceFailure(_ message: String, generation: UInt64, invocation: any FunctionInput) async throws {
        throw CancellationError()
    }
}
@Test(.actionCatalog) @MainActor func providerPresentationPipelineCommitsOneEffectAndKeepsOriginalFailure() async throws
{
    let fixture = ProviderTransactionFixture()
    let requests = ProviderSettingsRequests(service: fixture.service())
    let presenter = ProviderResultPresentationFixture(requests)
    let runtime = try await resourceRuntime(
        UnusedModelResourceCapability(), presentation: presenter, providerSettings: requests)
    #expect(try await runtime.restoreSettings().model == "old")
    #expect(presenter.ids.count == 1)
    do {
        try await runtime.saveSettings(
            .init(enabled: true, url: "https://example.invalid", key: "fixture-secret", model: "new"))
        Issue.record("Expected failure")
    } catch let error as ProviderIntentFailure {
        #expect(error.presented && error.failureCode == "provider.application")
    }
    #expect(presenter.ids.count == 2 && presenter.failures.last == "provider.application")
    presenter.reject = true
    do {
        try await runtime.saveSettings(
            .init(enabled: true, url: "https://example.invalid", key: "fixture-secret", model: "new"))
        Issue.record("Expected failure")
    } catch let error as ProviderIntentFailure {
        #expect(!error.presented && error.failureCode == "provider.application")
        #expect(error.message.contains("presentation"))
    }
    #expect(presenter.ids.count == 3)
    #expect(await runtime.agent.status().queuedInputs == 0)
    await runtime.shutdown()
}
@Test(.actionCatalog) func providerEligibilityBelongsToActionsAndPreservesOrder() throws {
    let values = ["gpt-4o-mini", "embedding-model", "my-deployment", "gpt-5-pro", "gpt-4o-mini", "whisper-1"]
    #expect(try ProviderModelList.eligible(values) == ["gpt-4o-mini", "my-deployment"])
    #expect(!ProviderModelList.isLikelyChatModel("GPT-5-Pro-2026"))
    #expect(throws: ProviderDiscoveryError.self) { try ProviderModelList.eligible([""]) }
}

@Test(.actionCatalog) @MainActor func providerSettingsRejectsOldShapeAndRoundTripsCurrentDocument() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Settings/settings.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data(
        #"{"version":1,"revision":"00000000-0000-0000-0000-000000000123","value":{"version":1,"cloud":{"enabled":true,"url":"https://example.invalid/v1","model":"configured-model","credentialID":"existing-credential"}}}"#
            .utf8)
    try original.write(to: url)
    let credentials = ProviderCredentialFixture()
    try credentials.insertKey(Data("fixture-secret".utf8), id: "existing-credential")
    let store = ProviderSettingsStore(
        credentials: credentials, document: { try FileDocumentStore<UserSettingsDocument>(url: url) })
    await #expect(throws: (any Error).self) { try await store.load() }
    #expect(try Data(contentsOf: url) == original)
    #expect(credentials.events == ["insertKey"])
    try FileManager.default.removeItem(at: url)
    let current = ProviderSettingsStore(
        credentials: credentials, document: { try FileDocumentStore<UserSettingsDocument>(url: url) })
    #expect(try await current.load() == nil)
    let value = ProviderSettings(
        enabled: true, url: "https://example.invalid/v1", key: "fixture-secret", model: "current-model")
    try await current.save(value)
    let reopened = ProviderSettingsStore(
        credentials: credentials, document: { try FileDocumentStore<UserSettingsDocument>(url: url) })
    #expect(try await reopened.load() == value)
    #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("fixture-secret"))

}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func settingsContainerRunsInItsAgentWithPrivateStagingAndActualPresentation() async throws {
    let ui = UIContainer()
    try ui.start()
    let fixture = ProviderTransactionFixture()
    let requests = ProviderSettingsRequests(service: fixture.service())
    let discovery = ProviderDiscoveryRequests { _ in ["fixture-model"] }
    let session = UUID().uuidString
    let providerPresentation = ProviderPresentationAdapter(
        state: ui.settings.presentation, sessionID: session, settings: requests)
    let presentation = ResourcePresentationAdapter(
        state: ui.modelResources.presentation, sessionID: session, provider: providerPresentation,
        navigation: ui.navigation.presentation, acknowledge: {})
    let host = try await resourceRuntime(
        UnusedModelResourceCapability(), presentation: presentation,
        providerDiscovery: discovery, providerSettings: requests,
        uiSettings: ui.settings, uiProviderSettings: requests, uiProviderDiscovery: discovery,
        uiProviderPresentation: providerPresentation, sessionID: session)
    try await host.prepareForInteraction()
    guard case .draft(let restored) = try await ui.settings.requests.submit(.restore) else {
        Issue.record("Restore must return the actual private result")
        await host.shutdown()
        return
    }
    #expect(restored.key == "fixture-secret" && restored.model == "old")
    #expect(ui.settings.state.key == "fixture-secret")
    let previousModels = ui.settings.state.modelCatalogs
    guard case .models(let models) = try await ui.settings.requests.submit(.discover(restored)) else {
        Issue.record("Discovery must return actual models")
        await host.shutdown()
        return
    }
    #expect(models == ["fixture-model"] && ui.settings.state.modelCatalogs == previousModels)
    fixture.rollbackFails = true
    do {
        _ = try await ui.settings.requests.submit(
            .save(
                .init(
                    enabled: true, url: "https://example.invalid", key: "fixture-secret", model: "new")))
        Issue.record("Rollback failure must fail the UI receipt")
    } catch let error as ProviderIntentFailure {
        #expect(error.failureCode == "provider.rollback")
        #expect(error.presented)
        #expect(!error.message.contains("fixture-secret"))
    }
    #expect(ui.settings.state.error != nil)
    await host.shutdown()
    await ui.stop()
}

@Test(.actionCatalog) func multipleProvidersSurviveReopenAndDeletionWithoutPlaintextKeys() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("providers-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let credentials = ProviderCredentialFixture()
    let store = ProviderSettingsStore(
        credentials: credentials, document: { try FileDocumentStore<UserSettingsDocument>(url: url) })
    _ = try await store.load()
    let first = ProviderSettings(
        enabled: false, url: "https://first.invalid/v1", key: "first-private-key", model: "first",
        name: "First Provider")
    let second = ProviderSettings(
        enabled: false, url: "https://second.invalid/v1", key: "second-private-key", model: "second",
        name: "Second Provider")
    let selected = ProviderSettings(
        enabled: true, url: second.url, key: second.key, model: second.model, providers: [first, second])
    try await store.save(selected)
    let reopened = ProviderSettingsStore(
        credentials: credentials, document: { try FileDocumentStore<UserSettingsDocument>(url: url) })
    #expect(try await reopened.load() == selected)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(!text.contains(first.key) && !text.contains(second.key))
    try await reopened.save(.init(enabled: false, url: "", key: "", model: "", providers: [first]))
    let final = ProviderSettingsStore(
        credentials: credentials, document: { try FileDocumentStore<UserSettingsDocument>(url: url) })
    let restored = try #require(try await final.load())
    #expect(!restored.enabled && restored.providers == [first])
    #expect(credentials.keyCount == 2)
}

@Test(.actionCatalog) @MainActor func providerSettingsStagesHTTPIPConfiguration() async throws {
    let fixture = ProviderTransactionFixture()
    let service = fixture.service()
    _ = try await service.restore()
    let requests = ProviderSettingsRequests(service: service)
    for url in ["http://192.168.1.20:11434/v1", "https://192.168.1.20:8443/v1"] {
        let provider = ProviderSettings(enabled: false, url: url, key: "", model: "test-model")
        let id = try requests.stageSave(
            .init(enabled: true, url: url, key: "", model: "test-model", providers: [provider]), sessionID: "http-test")
        requests.discard(id, sessionID: "http-test")
    }
}

@Test(.actionCatalog) @MainActor func writerModelSelectionIsIndependentAndPersistsStableProviderIdentity() async throws
{
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("settings.json")
    let credentials = ProviderCredentialFixture()
    let store = ProviderSettingsStore(
        credentials: credentials, document: { try FileDocumentStore<UserSettingsDocument>(url: url) })
    let provider = ProviderSettings(
        enabled: false, url: "https://writer.example.invalid", key: "fixture-writer-key", model: "assistant-choice",
        id: "stable-provider")
    let settings = ProviderSettings(
        enabled: false, url: provider.url, key: provider.key, model: "assistant-choice", providers: [provider],
        writerProviderID: provider.id, writerModel: "writer-choice", writerThinking: true)
    _ = try await store.load()
    try await store.save(settings)
    let restored = try #require(await store.load())
    #expect(restored.writerProviderID == "stable-provider")
    #expect(restored.writerModel == "writer-choice" && restored.writerThinking)
    #expect(restored.providers.first?.id == "stable-provider")
    let service = ProviderSettingsService(
        store: store, runtime: .init(initial: settings, prepare: { _ in {} }, beginChange: {}, endChange: {}))
    let selected = try await service.writerConfiguration()
    #expect(selected.model == "writer-choice" && selected.writerThinking)
    #expect(selected.key == "fixture-writer-key")
    #expect(try await service.restore().model == "assistant-choice")
    #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("fixture-writer-key"))
}

@Test(.actionCatalog) @MainActor func writerLocalSelectionDoesNotInheritAssistantCloud() async throws {
    let fixture = ProviderTransactionFixture()
    let service = fixture.service()
    _ = try await service.restore()
    let value = ProviderSettings(enabled: true, url: "https://assistant.test/v1", key: "fixture", model: "assistant")
    _ = try await service.save(value)
    let writer = try await service.writerConfiguration()
    #expect(!writer.enabled && writer.url.isEmpty && writer.key.isEmpty && writer.model.isEmpty)
    #expect(try await service.restore().model == "assistant")
}

@Test(.actionCatalog) @MainActor func writerThinkingDefaultsLowAndExplicitChoiceSurvivesReopen() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("settings.json")
    let credentials = ProviderCredentialFixture()
    let store = ProviderSettingsStore(
        credentials: credentials, document: { try FileDocumentStore<UserSettingsDocument>(url: url) })
    let provider = ProviderSettings(
        enabled: false, url: "https://writer.test", key: "fixture", model: "assistant", id: "p")
    func value(_ thinking: Bool = false) -> ProviderSettings {
        .init(
            enabled: false, url: provider.url, key: provider.key, model: "assistant", providers: [provider],
            writerProviderID: provider.id, writerModel: "writer", writerThinking: thinking)
    }
    #expect(!value().writerThinking)
    _ = try await store.load()
    try await store.save(value())
    #expect(try await store.load()?.writerThinking == false)
    try await store.save(value(true))
    let reopened = ProviderSettingsStore(
        credentials: credentials, document: { try FileDocumentStore<UserSettingsDocument>(url: url) })
    let restored = try #require(await reopened.load())
    #expect(restored.writerThinking)
    let service = ProviderSettingsService(
        store: reopened, runtime: .init(initial: value(), prepare: { _ in {} }, beginChange: {}, endChange: {}))
    #expect(try await service.writerConfiguration().writerThinking)
    _ = try await service.save(value(false))
    #expect(try await service.writerConfiguration().writerThinking == false)
    #expect(try await service.restore().model == "assistant")
}

@Test(.actionCatalog) @MainActor func decisionSelectionPersistsIndependentlyAndMissingFieldsStayUnconfigured()
    async throws
{
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "decision-providers-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let credentials = ProviderCredentialFixture()
    func makeStore() -> ProviderSettingsStore {
        ProviderSettingsStore(
            credentials: credentials, document: { try FileDocumentStore<UserSettingsDocument>(url: url) })
    }
    let store = makeStore()
    _ = try await store.load()
    let provider = ProviderSettings(
        enabled: false, url: "https://decision.invalid/v1", key: "decision-fixture-secret", model: "catalog-default",
        id: "decision-provider")
    let settings = ProviderSettings(
        enabled: true, url: "https://assistant.invalid/v1", key: "assistant-fixture-secret", model: "assistant-model",
        providers: [provider], writerProviderID: provider.id, writerModel: "writer-model",
        decisionProviderID: provider.id, decisionModel: "decision-model", decisionUsesLocal: true)
    try await store.save(settings)
    let reopened = makeStore()
    #expect(try await reopened.load() == settings)
    let service = ProviderSettingsService(
        store: reopened, runtime: .init(initial: settings, prepare: { _ in {} }, beginChange: {}, endChange: {}))
    let selected = try await service.decisionConfiguration()
    #expect(selected.id == provider.id && selected.model == "decision-model" && selected.url == provider.url)
    #expect(selected.key == provider.key && !selected.writerThinking)
    #expect(try await service.writerConfiguration().model == "writer-model")
    #expect(try await service.restore().model == "assistant-model")
    let data = try Data(contentsOf: url)
    #expect(!String(decoding: data, as: UTF8.self).contains("fixture-secret"))
    // The immediately preceding document format remains readable, without implicit Assistant inheritance.
    var envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var value = try #require(envelope["value"] as? [String: Any])
    value.removeValue(forKey: "decisionProviderID")
    value.removeValue(forKey: "decisionModel")
    value.removeValue(forKey: "decisionUsesLocal")
    envelope["value"] = value
    try JSONSerialization.data(withJSONObject: envelope).write(to: url)
    let legacy = makeStore()
    let restored = try #require(await legacy.load())
    #expect(restored.decisionProviderID == nil && restored.decisionModel.isEmpty)
    #expect(restored.decisionUsesLocal == nil)
    #expect(restored.writerModel == "writer-model" && restored.model == "assistant-model")
    let legacyService = ProviderSettingsService(
        store: legacy, runtime: .init(initial: settings, prepare: { _ in {} }, beginChange: {}, endChange: {}))
    await #expect(throws: ProviderSettingsError.self) { try await legacyService.decisionConfiguration() }
}

@Test(.actionCatalog) @MainActor func decisionSelectionRejectsDanglingProviderAndRoundTripsPrivateUITransport()
    async throws
{
    let ui = UIContainer()
    try ui.start()
    let fixture = ProviderTransactionFixture()
    fixture.failApply = false
    let service = fixture.service()
    let requests = ProviderSettingsRequests(service: service)
    let discovery = ProviderDiscoveryRequests { _ in ["decision-model"] }
    let session = UUID().uuidString
    let providerPresentation = ProviderPresentationAdapter(
        state: ui.settings.presentation, sessionID: session, settings: requests)
    let presentation = ResourcePresentationAdapter(
        state: ui.modelResources.presentation, sessionID: session, provider: providerPresentation,
        navigation: ui.navigation.presentation, acknowledge: {})
    let host = try await resourceRuntime(
        UnusedModelResourceCapability(), presentation: presentation, providerDiscovery: discovery,
        providerSettings: requests, uiSettings: ui.settings, uiProviderSettings: requests,
        uiProviderDiscovery: discovery, uiProviderPresentation: providerPresentation, sessionID: session)
    try await host.prepareForInteraction()
    _ = try await ui.settings.requests.submit(.restore)
    let provider = CloudSettingsDraft(
        enabled: false, url: "https://decision.invalid/v1", key: "decision-fixture", model: "catalog-default",
        id: "decision")
    let draft = CloudSettingsDraft(
        enabled: true, url: "https://assistant.invalid/v1", key: "assistant-fixture", model: "assistant-model",
        providers: [provider], decisionProviderID: provider.id, decisionModel: "decision-model")
    _ = try await ui.settings.requests.submit(.save(draft))
    let selected = try await service.decisionConfiguration()
    #expect(selected.id == "decision" && selected.model == "decision-model" && selected.key == "decision-fixture")
    guard case .draft(let restored) = try await ui.settings.requests.submit(.restore) else {
        Issue.record("Missing settings restore")
        await host.shutdown()
        await ui.stop()
        return
    }
    #expect(restored.decisionProviderID == "decision" && restored.decisionModel == "decision-model")
    #expect(ui.settings.state.decisionProviderID == "decision" && ui.settings.state.decisionModel == "decision-model")
    #expect(restored.model == "assistant-model")
    for (id, model) in [("missing", "model"), ("decision", " "), ("decision", String(repeating: "x", count: 513))] {
        #expect(throws: ProviderSettingsError.self) {
            try requests.stageSave(
                .init(
                    enabled: false, url: "", key: "", model: "", providers: [selected], decisionProviderID: id,
                    decisionModel: model), sessionID: session)
        }
    }
    _ = try await service.save(.init(enabled: true, url: draft.url, key: draft.key, model: draft.model))
    await #expect(throws: ProviderSettingsError.self) { try await service.decisionConfiguration() }
    #expect(try await service.restore().model == "assistant-model")
    await host.shutdown()
    await ui.stop()
}

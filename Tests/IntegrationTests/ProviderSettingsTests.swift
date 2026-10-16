import ActionBindings
import Actions
import AgentBindings
import AgentCore
import Agents
import Foundation
import FunctionContracts
import Gateway
import PlatformKit
import StorageCore
import StorageFiles
import StorageState
import Testing

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
            .init(enabled: true, url: "https://example.invalid", key: "fixture-secret", model: "new"))
    }
    #expect(fixture.events == ["prepare:new", "begin", "persist:new", "apply:new", "persist:old", "end"])
    #expect(fixture.value?.model == "old")
    #expect(try await service.restore().model == "old")
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
@Test(.actionCatalog) @MainActor func providerSettingsReturningPipelineKeepsPrivateResultsAndRollbackCauses()
    async throws
{
    let fixture = ProviderTransactionFixture()
    let requests = ProviderSettingsRequests(service: fixture.service())
    let session = UUID().uuidString
    let runtime = try resourceRuntime(UnusedModelResourceCapability(), providerSettings: requests, sessionID: session)
    let restoreID = try requests.stageRestore(sessionID: session)
    try await runtime.configureProvider(.init(operation: .restore, requestID: restoreID))
    #expect(try requests.take(restoreID, sessionID: session).key == "fixture-secret")
    #expect(throws: ProviderSettingsError.self) { try requests.take(restoreID, sessionID: session) }
    fixture.events.removeAll()
    fixture.rollbackFails = true
    let id = try requests.stageSave(
        .init(enabled: true, url: "https://example.invalid", key: "fixture-secret", model: "new"), sessionID: session)
    do {
        try await runtime.configureProvider(.init(operation: .save, requestID: id))
        Issue.record("Failed rollback must fail the request")
    } catch let error as ProviderIntentFailure {
        #expect(error.failureCode == "provider.rollback")
        #expect(error.message.contains("provider.application"))
        #expect(error.message.contains("provider.persistence"))
        #expect(!error.message.contains("fixture-secret"))
    }
    #expect(fixture.events.last == "end")
    #expect(fixture.value?.model == "new")
    #expect(throws: ProviderSettingsError.self) { try requests.take(id, sessionID: session) }
    #expect(await runtime.agent.status().queuedInputs == 0)
    let again = try requests.stageRestore(sessionID: session)
    try await runtime.configureProvider(.init(operation: .restore, requestID: again))
    #expect(try requests.take(again, sessionID: session).model == "old")
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
            state: ApplicationControlContextState(), stateScope: StateContainer().makeScope())
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
    private var old: Data?
    private var keys: [String: Data] = [:]
    private var actions: [String] = []
    init() throws {
        old = try JSONSerialization.data(withJSONObject: [
            "url": "https://example.invalid", "key": "fixture-secret", "model": "legacy",
        ])
    }
    func legacy() throws -> Data? { lock.withLock { old } }
    func removeLegacy() throws {
        lock.withLock {
            actions.append("removeLegacy")
            old = nil
        }
    }
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
@Test(.actionCatalog) func providerSettingsStoreVerifiesLegacyMigrationAndCleansFailedCredentialCommit() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "provider-settings-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let credentials = try ProviderCredentialFixture()
    let store = ProviderSettingsStore(
        credentials: credentials, document: { try FileDocumentStore<UserSettingsDocument>(url: url) })
    let value = try #require(try await store.load())
    #expect(value.enabled)
    #expect(value.key == "fixture-secret")
    #expect(credentials.events == ["insertKey", "readKey", "removeLegacy"])
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
    let session = UUID().uuidString
    let runtime = try resourceRuntime(
        UnusedModelResourceCapability(), presentation: presenter, providerSettings: requests, sessionID: session)
    let restore = try requests.stageRestore(sessionID: session)
    try await runtime.configureProvider(.init(operation: .restore, requestID: restore, presentation: true))
    #expect(presenter.ids == [restore])
    #expect(try requests.take(restore, sessionID: session).model == "old")
    let save = try requests.stageSave(
        .init(enabled: true, url: "https://example.invalid", key: "fixture-secret", model: "new"), sessionID: session)
    do {
        try await runtime.configureProvider(.init(operation: .save, requestID: save, presentation: true))
        Issue.record("Expected failure")
    } catch let error as ProviderIntentFailure {
        #expect(error.presented)
        #expect(error.failureCode == "provider.application")
    }
    #expect(presenter.ids == [restore, save])
    #expect(presenter.failures.last == "provider.application")
    presenter.reject = true
    let another = try requests.stageSave(
        .init(enabled: true, url: "https://example.invalid", key: "fixture-secret", model: "new"), sessionID: session)
    do {
        try await runtime.configureProvider(.init(operation: .save, requestID: another, presentation: true))
        Issue.record("Expected failure")
    } catch let error as ProviderIntentFailure {
        #expect(!error.presented)
        #expect(error.failureCode == "provider.application")
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

@Test(.actionCatalog) @MainActor func providerSettingsRestoresOriginalDocumentAndCredentialWithoutReset() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Settings/settings.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data(
        #"{"version":1,"revision":"00000000-0000-0000-0000-000000000123","value":{"version":1,"cloud":{"enabled":true,"url":"https://example.invalid/v1","model":"configured-model","credentialID":"existing-credential"}}}"#
            .utf8)
    try original.write(to: url)
    let credentials = try ProviderCredentialFixture()
    try credentials.insertKey(Data("fixture-secret".utf8), id: "existing-credential")
    let store = ProviderSettingsStore(
        credentials: credentials, document: { try FileDocumentStore<UserSettingsDocument>(url: url) })
    var applied: ProviderSettings?
    let service = ProviderSettingsService(
        store: store,
        runtime: .init(
            initial: .init(enabled: false, url: "https://default.invalid", key: "", model: "default"),
            prepare: { value in { applied = value } }, beginChange: {}, endChange: {}))
    let restored = try await service.restore()
    #expect(restored.enabled && restored.model == "configured-model")
    #expect(restored.url == "https://example.invalid/v1" && restored.key == "fixture-secret")
    #expect(applied == restored)
    #expect(credentials.events == ["insertKey", "readKey"])
    #expect(try Data(contentsOf: url) == original)
    let updated = ProviderSettings(
        enabled: restored.enabled, url: restored.url, key: restored.key, model: "updated-model")
    _ = try await service.save(updated)
    let reopened = ProviderSettingsStore(
        credentials: credentials, document: { try FileDocumentStore<UserSettingsDocument>(url: url) })
    #expect(try await reopened.load() == updated)
    let output = try Data(contentsOf: url)
    let envelope = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
    #expect(envelope["version"] as? Int == 1)
    #expect(!String(decoding: output, as: UTF8.self).contains("fixture-secret"))
}

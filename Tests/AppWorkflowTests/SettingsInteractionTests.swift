import Actions
import Agents
import Foundation
import Gateway
import PlatformKit
import Testing

@testable import UI

@MainActor
private final class ControlledSettings: SettingsOperating {
    let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var pending: CheckedContinuation<Void, any Error>?
    var saves: [CloudSettingsDraft] = []
    let original = CloudSettingsDraft(enabled: true, url: "https://example.test/v1", key: "test", model: "test-model")
    func restore() async throws -> CloudSettingsDraft { original }
    func discover(_ draft: CloudSettingsDraft) async throws -> [String] { [draft.model] }
    func save(_ draft: CloudSettingsDraft) async throws {
        saves.append(draft)
        try await withCheckedThrowingContinuation {
            pending = $0
            started.continuation.yield(())
        }
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func settingsSaveKeepsOneOperationAcrossPageLifetimeAndCanRetryAfterFailure() async throws {
    let operation = ControlledSettings()
    let state = SettingsState(initial: operation.original)
    #expect(!state.writerThinking)
    let beforeThinking = state.revision
    state.writerThinking = true
    #expect(state.revision > beforeThinking)
    let controls = SettingsFormController(
        state: state, operations: operation, defaultModel: operation.original.model)
    var started = operation.started.stream.makeAsyncIterator()
    state.url = "  https://example.test/v2  "
    let save = Task { await controls.save() }
    await started.next()
    #expect(state.isSaving && !state.canSave && !state.canLoad)
    #expect(await controls.save() == false)
    #expect(operation.saves.count == 1 && operation.saves[0].writerThinking)
    #expect(operation.saves[0].url == "https://example.test/v2")
    // View disappearance cancels only discovery, never an admitted configuration transaction.
    controls.cancelDiscovery()
    #expect(state.isSaving)
    operation.pending?.resume(throwing: CancellationError())
    #expect(await save.value == false)
    #expect(!state.isSaving && state.error != nil)
    let retry = Task { await controls.save() }
    await started.next()
    operation.pending?.resume()
    #expect(await retry.value)
    #expect(state.error == nil && operation.saves.count == 2)
}

@Test @MainActor
func restoringSettingsAgainPreservesUnsavedFormEdits() async throws {
    let operation = ControlledSettings()
    let state = SettingsState(initial: .init(enabled: false, url: "", key: "", model: "default"))
    let controls = SettingsFormController(state: state, operations: operation, defaultModel: "default")
    try await controls.restore()
    #expect(state.selectedModel == operation.original.model)
    state.url = "https://new.example.test"
    state.selectedModel = "unsaved-selection"
    try await controls.restore()
    #expect(state.selectedModel == "unsaved-selection")
    #expect(state.url == "https://new.example.test")
}

@MainActor private final class DiscoveryCleanupFixture: SettingsOperating {
    let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var release: CheckedContinuation<Void, Never>?
    var ended = false
    func restore() async throws -> CloudSettingsDraft {
        .init(
            enabled: true, url: "https://example.test", key: "test", model: "test",
            providers: [
                .init(
                    enabled: true, url: "https://example.test", key: "test", model: "test", name: "Test",
                    id: "test-provider")
            ])
    }
    func save(_ draft: CloudSettingsDraft) async throws {}
    func discover(_ draft: CloudSettingsDraft) async throws -> [String] {
        await withCheckedContinuation {
            release = $0
            started.continuation.yield(())
        }
        ended = true
        try Task.checkCancellation()
        return ["late"]
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor func settingsShutdownJoinsCancelledDiscoveryAndRejectsNewWork() async throws {
    let fixture = DiscoveryCleanupFixture()
    let state = SettingsState(initial: try await fixture.restore())
    let controls = SettingsFormController(state: state, operations: fixture, defaultModel: "test")
    controls.loadModels(providerID: try #require(state.providers.first).id)
    var started = fixture.started.stream.makeAsyncIterator()
    await started.next()
    controls.cancelDiscovery()
    let stop = Task { await controls.shutdown() }
    await Task.yield()
    #expect(!fixture.ended)
    fixture.release?.resume()
    await stop.value
    #expect(fixture.ended && !state.modelCatalogs.values.contains(["late"]))
    await #expect(throws: CancellationError.self) { try await controls.restore() }
    #expect(await controls.save() == false)
}

@MainActor private final class BrainDiscoveryFixture: SettingsOperating {
    var pending: [(CloudSettingsDraft, CheckedContinuation<[String], any Error>)] = []
    func restore() async throws -> CloudSettingsDraft { .init(enabled: false, url: "", key: "", model: "") }
    func discover(_ draft: CloudSettingsDraft) async throws -> [String] {
        try await withCheckedThrowingContinuation { pending.append((draft, $0)) }
    }
    func save(_ draft: CloudSettingsDraft) async throws {}
}
@Test(.timeLimit(.minutes(1))) @MainActor func brainModelListsAreIndependentAndFenceEditedCredentials() async throws {
    let a = CloudSettingsDraft(enabled: false, url: "https://a.test", key: "a", model: "", name: "A", id: "a")
    let b = CloudSettingsDraft(enabled: false, url: "https://b.test", key: "b", model: "", name: "B", id: "b")
    let state = SettingsState(
        initial: .init(
            enabled: true, url: a.url, key: a.key, model: "saved-a",
            providers: [a, b], writerProviderID: b.id, writerModel: "saved-b",
            decisionProviderID: b.id, decisionModel: "decision-b"))
    let fixture = BrainDiscoveryFixture()
    let controls = SettingsFormController(state: state, operations: fixture, defaultModel: "unused")
    controls.refreshModels()
    while fixture.pending.count < 2 { await Task.yield() }
    #expect(Set(fixture.pending.map { $0.0.id }) == ["a", "b"])
    for (draft, result) in fixture.pending { result.resume(returning: ["loaded-" + draft.id]) }
    while !state.loadingProviderIDs.isEmpty { await Task.yield() }
    #expect(state.modelCatalogs["a"] == ["loaded-a"] && state.modelCatalogs["b"] == ["loaded-b"])
    #expect(state.selectedModel == "saved-a" && state.writerModel == "saved-b")
    fixture.pending.removeAll()
    controls.loadModels(providerID: "a")
    while fixture.pending.count < 1 { await Task.yield() }
    var changed = a
    changed.key = "replacement"
    state.upsertProvider(changed)
    controls.loadModels(providerID: "a")
    while fixture.pending.count < 2 { await Task.yield() }
    fixture.pending[1].1.resume(returning: ["current"])
    fixture.pending[0].1.resume(returning: ["stale"])
    while !state.loadingProviderIDs.isEmpty { await Task.yield() }
    #expect(state.modelCatalogs["a"] == ["current"])
    #expect(state.writerModel == "saved-b" && state.decisionModel == "decision-b")
    state.removeProvider("a")
    #expect(state.assistantProviderID == nil && !state.isEnabled)
    #expect(state.writerProviderID == "b")
    state.removeProvider("b")
    #expect(state.writerProviderID == nil && state.writerModel.isEmpty)
    #expect(state.decisionProviderID == nil && state.decisionModel.isEmpty)
    await controls.shutdown()
}

@MainActor private final class WelcomeSettingsFixture: SettingsOperating {
    var stored = CloudSettingsDraft(enabled: false, url: "https://api.openai.com/v1", key: "", model: "default")
    var failsRestore = false
    var failsSave = false
    var saves = 0
    var pending: CheckedContinuation<Void, Never>?
    var holdsSave = false
    func restore() async throws -> CloudSettingsDraft {
        if failsRestore { throw WelcomeFixtureError.failed }
        return stored
    }
    func discover(_ draft: CloudSettingsDraft) async throws -> [String] { [] }
    func save(_ draft: CloudSettingsDraft) async throws {
        saves += 1
        if holdsSave { await withCheckedContinuation { pending = $0 } }
        if failsSave { throw WelcomeFixtureError.failed }
        stored = draft
    }
}
private enum WelcomeFixtureError: Error { case failed }

@Test @MainActor func agentBrainPagesCommitOnlyTheirOwnSettings() async throws {
    let fixture = WelcomeSettingsFixture()
    let provider = CloudSettingsDraft(
        enabled: false, url: "https://shared.test/v1", key: "fixture", model: "", name: "Shared", id: "shared")
    fixture.stored = .init(
        enabled: true, url: provider.url, key: provider.key, model: "assistant-model", providers: [provider],
        writerProviderID: provider.id, writerModel: "writer-model", decisionProviderID: provider.id,
        decisionModel: "decision-model")
    let state = SettingsState(initial: fixture.stored)
    let controls = SettingsFormController(state: state, operations: fixture, defaultModel: "default")
    try await controls.restore()
    var decision = state.brainDraft(.decision)
    decision.usesLocal = true
    decision.model = "fallback-model"
    var writer = state.brainDraft(.writer)
    writer.writerThinking = true
    #expect(await controls.save(.brain(.decision, decision)))
    #expect(fixture.stored.decisionUsesLocal && fixture.stored.decisionModel == "fallback-model")
    #expect(fixture.stored.model == "assistant-model" && !fixture.stored.writerThinking)
    #expect(await controls.save(.brain(.writer, writer)))
    #expect(fixture.stored.writerThinking && fixture.stored.decisionUsesLocal)
    #expect(state.brainDraft(.decision) == decision)

    fixture.failsSave = true
    #expect(await !controls.save(.providers([])))
    #expect(state.providers == [provider] && state.brainDraft(.writer) == writer)
    fixture.failsSave = false
    #expect(await controls.save(.providers([])))
    #expect(state.providers.isEmpty && state.brainDraft(.assistant).usesLocal)
    #expect(state.brainDraft(.writer).providerID == nil)
    #expect(state.brainDraft(.decision).usesLocal && state.brainDraft(.decision).providerID == nil)
}

@Test @MainActor func agentBrainNavigationKeepsTheSharedParent() {
    let navigation = NavigationState()
    navigation.show(.assistantBrain)
    #expect(navigation.path == [.settings, .language, .assistantBrain])
    navigation.show(.writerBrain)
    #expect(navigation.path == [.settings, .language, .writerBrain])
    navigation.show(.decision)
    #expect(navigation.path == [.settings, .language, .decision])
}

@Test @MainActor func welcomeRequiresSuccessfulRestoreAndDoesNotReplaceAnExistingProvider() async throws {
    let fixture = WelcomeSettingsFixture()
    let state = SettingsState(initial: fixture.stored)
    let controls = SettingsFormController(state: state, operations: fixture, defaultModel: "default")
    #expect(!controls.needsWelcome)
    #expect(await !controls.saveWelcomeProvider(url: "", key: "fixture-key"))
    fixture.failsRestore = true
    await #expect(throws: WelcomeFixtureError.self) { try await controls.restore() }
    #expect(!controls.needsWelcome && fixture.saves == 0)
    fixture.failsRestore = false
    fixture.stored.providers = [
        .init(enabled: false, url: "https://existing.test/v1", key: "fixture-key", model: "", name: "Existing")
    ]
    try await controls.restore()
    #expect(!controls.needsWelcome)
    #expect(await !controls.saveWelcomeProvider(url: "", key: "another-fixture-key"))
    #expect(state.providers == fixture.stored.providers && fixture.saves == 0)
}

@Test(arguments: ["  \n", "  https://custom.test/v1  "])
@MainActor func welcomeSavesProviderAndSurvivesASettingsRestart(url: String) async throws {
    let fixture = WelcomeSettingsFixture()
    let state = SettingsState(initial: fixture.stored)
    let controls = SettingsFormController(state: state, operations: fixture, defaultModel: "default")
    try await controls.restore()
    #expect(controls.needsWelcome)
    #expect(await controls.saveWelcomeProvider(url: url, key: "  fixture-key\n"))
    let saved = try #require(fixture.stored.providers.first)
    #expect(saved.url == (url.contains("custom") ? "https://custom.test/v1" : "https://api.openai.com/v1"))
    #expect(saved.key == "fixture-key" && !saved.id.isEmpty)
    #expect(!state.isEnabled && state.writerProviderID == nil)
    #expect(saved.model.isEmpty && !controls.needsWelcome)
    let reloaded = SettingsState(initial: .init(enabled: false, url: "", key: "", model: ""))
    let restarted = SettingsFormController(state: reloaded, operations: fixture, defaultModel: "default")
    try await restarted.restore()
    #expect(!restarted.needsWelcome && reloaded.providers == [saved])
}

@Test @MainActor func welcomeRejectsInvalidInputAndKeepsItsDraftRetryableAfterSaveFailure() async throws {
    let fixture = WelcomeSettingsFixture()
    let state = SettingsState(initial: fixture.stored)
    let controls = SettingsFormController(state: state, operations: fixture, defaultModel: "default")
    try await controls.restore()
    for (url, key) in [("", " \n"), ("not a URL", "fixture-key"), ("", String(repeating: "x", count: 4097))] {
        #expect(await !controls.saveWelcomeProvider(url: url, key: key))
        #expect(state.error != nil && state.providers.isEmpty && fixture.saves == 0)
    }
    fixture.failsSave = true
    #expect(await !controls.saveWelcomeProvider(url: "", key: "fixture-key"))
    #expect(controls.needsWelcome && state.providers.isEmpty && !state.isSaving && state.error != nil)
    fixture.failsSave = false
    #expect(await controls.saveWelcomeProvider(url: "", key: "fixture-key"))
    #expect(!controls.needsWelcome && state.error == nil && fixture.saves == 2)
}

@Test(.timeLimit(.minutes(1))) @MainActor func welcomeAdmitsOnlyOneSaveAndDoesNotPublishAfterShutdown() async throws {
    let fixture = WelcomeSettingsFixture()
    fixture.holdsSave = true
    let state = SettingsState(initial: fixture.stored)
    let controls = SettingsFormController(state: state, operations: fixture, defaultModel: "default")
    try await controls.restore()
    let save = Task { await controls.saveWelcomeProvider(url: "", key: "fixture-key") }
    while fixture.pending == nil { await Task.yield() }
    #expect(state.isSaving && state.providers.isEmpty)
    #expect(await !controls.saveWelcomeProvider(url: "", key: "other-fixture-key"))
    #expect(await !controls.save())
    #expect(fixture.saves == 1)
    await controls.shutdown()
    fixture.pending?.resume()
    #expect(await save.value)
    #expect(state.providers.isEmpty && !controls.needsWelcome)
    #expect(fixture.stored.providers.first?.key == "fixture-key")
}

@Test @MainActor func welcomeProviderKeepsItsKeyWhenOnlyWriterUsesCloud() async throws {
    let fixture = WelcomeSettingsFixture()
    let state = SettingsState(initial: fixture.stored)
    let controls = SettingsFormController(state: state, operations: fixture, defaultModel: "default")
    try await controls.restore()
    #expect(await controls.saveWelcomeProvider(url: "", key: "fixture-key"))
    let provider = try #require(state.providers.first)
    // The disabled Assistant retains the default URL and empty key; Writer selects independently.
    #expect(state.url == provider.url && state.key.isEmpty && !state.isEnabled)
    state.selectWriterProvider(provider.id)
    state.writerModel = "writer-model"
    #expect(await controls.save())
    #expect(!fixture.stored.enabled && fixture.stored.writerProviderID == provider.id)
    #expect(fixture.stored.writerModel == "writer-model")
    #expect(fixture.stored.providers.first?.key == "fixture-key")
    let restored = SettingsState(initial: .init(enabled: false, url: "", key: "", model: ""))
    let restarted = SettingsFormController(state: restored, operations: fixture, defaultModel: "default")
    try await restarted.restore()
    #expect(!restarted.needsWelcome && restored.providers.first?.key == "fixture-key")
    #expect(restored.writerProviderID == provider.id && restored.writerModel == "writer-model")
}

@Test @MainActor func decisionFormSelectionSavesRestoresAndKeepsOtherBrainsIndependent() async throws {
    let fixture = WelcomeSettingsFixture()
    let a = CloudSettingsDraft(enabled: false, url: "https://a.invalid", key: "fixture-a", model: "default", id: "a")
    let b = CloudSettingsDraft(enabled: false, url: "https://b.invalid", key: "fixture-b", model: "default", id: "b")
    fixture.stored = .init(
        enabled: true, url: a.url, key: a.key, model: "assistant", providers: [a, b], writerProviderID: a.id,
        writerModel: "writer")
    let state = SettingsState(initial: fixture.stored)
    let controls = SettingsFormController(state: state, operations: fixture, defaultModel: "default")
    try await controls.restore()
    let revision = state.revision
    state.selectDecisionProvider(b.id)
    #expect(!state.canSave)
    state.decisionModel = "decision"
    #expect(state.canSave && state.revision > revision)
    #expect(await controls.save())
    #expect(fixture.stored.decisionProviderID == "b" && fixture.stored.decisionModel == "decision")
    #expect(fixture.stored.model == "assistant" && fixture.stored.writerModel == "writer")
    let restored = SettingsState(initial: .init(enabled: false, url: "", key: "", model: ""))
    let restarted = SettingsFormController(state: restored, operations: fixture, defaultModel: "default")
    try await restarted.restore()
    #expect(restored.decisionProviderID == "b" && restored.decisionModel == "decision")
    restored.selectAssistantProvider("b")
    restored.selectedModel = "other-assistant"
    #expect(restored.decisionModel == "decision")
    restored.selectDecisionProvider("a")
    #expect(restored.decisionModel.isEmpty && !restored.canSave)
    restored.decisionModel = "new-decision"
    restored.removeProvider("a")
    #expect(restored.decisionProviderID == nil && restored.decisionModel.isEmpty)
    #expect(restored.assistantProviderID == "b" && restored.selectedModel == "other-assistant")
    #expect(await restarted.save())
    #expect(fixture.stored.decisionProviderID == nil && fixture.stored.decisionModel.isEmpty)
    await controls.shutdown()
    await restarted.shutdown()
}

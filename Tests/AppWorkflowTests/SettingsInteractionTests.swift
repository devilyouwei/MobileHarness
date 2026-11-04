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
            providers: [a, b], writerProviderID: b.id, writerModel: "saved-b"))
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
    #expect(state.writerModel == "saved-b")
    state.removeProvider("a")
    #expect(state.assistantProviderID == nil && !state.isEnabled)
    #expect(state.writerProviderID == "b")
    state.removeProvider("b")
    #expect(state.writerProviderID == nil && state.writerModel.isEmpty)
    await controls.shutdown()
}

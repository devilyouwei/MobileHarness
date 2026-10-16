import ActionBindings
import Actions
import AgentBindings
import Foundation
import Gateway
import PlatformKit
import Testing
import UI

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
    let controls = SettingsInteractionWorkflow(
        state: state, operations: operation, defaultModel: operation.original.model)
    var started = operation.started.stream.makeAsyncIterator()
    state.url = "  https://example.test/v2  "
    let save = Task { await controls.save() }
    await started.next()
    #expect(state.isSaving && !state.canSave && !state.canLoad)
    #expect(await controls.save() == false)
    #expect(operation.saves.count == 1)
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
    let controls = SettingsInteractionWorkflow(state: state, operations: operation, defaultModel: "default")
    try await controls.restore()
    #expect(state.selectedModel == operation.original.model)
    state.url = "https://new.example.test"
    state.selectedModel = "unsaved-selection"
    try await controls.restore()
    #expect(state.selectedModel == "unsaved-selection")
    #expect(state.url == "https://new.example.test")
}

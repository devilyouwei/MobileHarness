import AppSettingsWorkflow
import Foundation
import Testing
import UI

@MainActor private final class ResourceOperationsFixture: ModelResourcesOperating {
    let state: ModelResourcesState
    init(state: ModelResourcesState) { self.state = state }
    var downloads = 0
    var cancellations = 0
    var removals = 0
    var admission: CheckedContinuation<Void, Error>?
    var cancellation: CheckedContinuation<Void, Error>?
    var blockAdmission = false
    var blockCancellation = false
    var active = false
    var commandFailurePresented = false
    var failDownload = false
    var failRefresh = false
    var refreshErrorPresented = false
    var preferenceFailurePresented = false
    var restoreFailurePresented = false
    var failSave = false
    var missingGroup: ModelResourceGroup?
    var storedSource = ModelResourceSourceDraft()
    func refresh(generation: UInt64?) throws -> ModelResourceViewSnapshot {
        if failRefresh {
            if refreshErrorPresented, let generation {
                _ = state.applyRefreshFailure("primary refresh failure", generation: generation)
                throw ApplicationControlIntentFailure.presented("primary refresh failure")
            }
            throw CocoaError(.fileReadUnknown)
        }
        let snapshot = ModelResourceViewSnapshot(items: [
            .init(
                id: "model", name: "Model", status: active ? "正在下载" : "未下载", bytes: 100,
                progress: 0.42, installed: false, active: active, failure: "previous failure",
                activity: active ? .downloading : nil)
        ])
        if let generation { _ = state.applySnapshot(snapshot, generation: generation) }
        return snapshot
    }
    var restoreCalls = 0
    func restoreSource() throws -> ModelResourceSourceDraft {
        restoreCalls += 1
        if restoreFailurePresented {
            state.error = "accepted restore failure"
            throw ApplicationControlIntentFailure.presented("restore chain details")
        }
        return storedSource
    }
    func saveSource(_ source: ModelResourceSourceDraft) throws {
        if let missingGroup {
            if preferenceFailurePresented {
                state.installationNotice = missingGroup.installationMessage
                state.error = nil
                throw ApplicationControlIntentFailure.presented("selection chain details")
            }
            throw ModelResourceSelectionError(group: missingGroup)
        }
        if failSave, preferenceFailurePresented {
            state.error = "accepted preference failure"
            throw ApplicationControlIntentFailure.presented("preference chain details")
        }
        if failSave { throw CocoaError(.fileWriteUnknown) }
        storedSource = source
    }
    func download(_ id: String) async throws {
        downloads += 1
        if blockAdmission { try await withCheckedThrowingContinuation { admission = $0 } }
        try Task.checkCancellation()
        if failDownload { throw CocoaError(.fileReadUnknown) }
        if commandFailurePresented {
            state.error = "accepted operation error"
            throw ApplicationControlIntentFailure.presented("accepted operation error; downstream details")
        }
        active = true
    }
    func cancel(_ id: String) async throws {
        cancellations += 1
        if blockCancellation { try await withCheckedThrowingContinuation { cancellation = $0 } }
        active = false
    }
    func remove(_ id: String) { removals += 1 }
}

@MainActor @Test(.timeLimit(.minutes(1))) func immediateAdmissionBlocksDuplicateDownloadAndOrdersCancellation() async {
    let state = ModelResourcesState()
    let operations = ResourceOperationsFixture(state: state)
    operations.blockAdmission = true
    operations.blockCancellation = true
    let workflow = ModelResourceInteractionWorkflow(state: state, operations: operations)
    await workflow.restore()
    let download = Task { await workflow.perform("model", operation: .download) }
    while operations.admission == nil { await Task.yield() }
    let item = state.items[0]
    #expect(state.isDownloading(item))
    #expect(state.status(item) == "正在提交下载…")
    await workflow.perform("model", operation: .download)
    await workflow.perform("model", operation: .remove)
    #expect(operations.downloads == 1)
    #expect(operations.removals == 0)
    let cancel = Task { await workflow.perform("model", operation: .cancel) }
    while !state.isCancelling("model") { await Task.yield() }
    await workflow.perform("model", operation: .cancel)
    #expect(operations.cancellations == 0)
    operations.admission?.resume()
    operations.admission = nil
    while operations.cancellation == nil { await Task.yield() }
    await workflow.perform("model", operation: .cancel)
    await workflow.perform("model", operation: .download)
    #expect(operations.cancellations == 1)
    #expect(state.status(item) == "正在取消…")
    operations.cancellation?.resume()
    operations.cancellation = nil
    await cancel.value
    await download.value
    #expect(!state.isBusy(state.items[0]))
    #expect(!operations.active)
}

@MainActor @Test func activeDownloadAllowsCancellationAndFailureReleasesSubmission() async {
    let state = ModelResourcesState()
    let operations = ResourceOperationsFixture(state: state)
    operations.active = true
    let workflow = ModelResourceInteractionWorkflow(state: state, operations: operations)
    await workflow.restore()
    await workflow.perform("model", operation: .download)
    await workflow.perform("model", operation: .remove)
    #expect(operations.downloads == 0)
    #expect(operations.removals == 0)
    #expect(state.items[0].progress == 0.42)
    await workflow.perform("model", operation: .cancel)
    #expect(operations.cancellations == 1)
    operations.failDownload = true
    await workflow.perform("model", operation: .download)
    #expect(state.error != nil)
    #expect(!state.isBusy(state.items[0]))
    operations.failDownload = false
    await workflow.perform("model", operation: .download)
    #expect(operations.downloads == 2)
    #expect(state.items[0].active)
}

@MainActor @Test func failedStatusRefreshKeepsAdmittedDownloadLockedUntilCancellation() async {
    let state = ModelResourcesState()
    let operations = ResourceOperationsFixture(state: state)
    let workflow = ModelResourceInteractionWorkflow(state: state, operations: operations)
    await workflow.restore()
    operations.failRefresh = true
    await workflow.perform("model", operation: .download)
    #expect(state.isDownloading(state.items[0]))
    #expect(state.error != nil)
    await workflow.perform("model", operation: .download)
    await workflow.perform("model", operation: .remove)
    #expect(operations.downloads == 1)
    #expect(operations.removals == 0)
    operations.failRefresh = false
    await workflow.perform("model", operation: .cancel)
    #expect(operations.cancellations == 1)
    #expect(!state.isBusy(state.items[0]))
}

@Test func olderDownloadPreferencesDefaultToDownloadedSpeech() throws {
    let value = try JSONDecoder().decode(
        ModelResourceSourceDraft.self,
        from: Data("{\"endpoint\":\"https://huggingface.co\",\"allowsCellular\":false}".utf8))
    #expect(value.useCustomRecognition)
    let system = ModelResourceSourceDraft(useCustomRecognition: false, useCustomSynthesis: false)
    #expect(
        try JSONDecoder().decode(ModelResourceSourceDraft.self, from: JSONEncoder().encode(system))
            .useCustomRecognition == false)
}

@MainActor @Test func failedSpeechPreferenceSaveRestoresActivePolicy() async {
    let state = ModelResourcesState()
    let operations = ResourceOperationsFixture(state: state)
    operations.failSave = true
    let workflow = ModelResourceInteractionWorkflow(state: state, operations: operations)
    await workflow.restore()
    state.source.useCustomRecognition = true
    await workflow.saveSource()
    #expect(!state.source.useCustomRecognition)
    #expect(state.error != nil)
    #expect(!state.saving)
}

@Test func speechPreferencesMigrateLegacySwitchAndRoundTripIndependentModes() throws {
    let legacy = try JSONDecoder().decode(
        ModelResourceSourceDraft.self,
        from: Data(#"{"endpoint":"https://hf-mirror.com","allowsCellular":true,"preferDownloadedSpeech":false}"#.utf8))
    #expect(!legacy.useCustomRecognition && !legacy.useCustomSynthesis)
    let draft = ModelResourceSourceDraft(useCustomRecognition: true, useCustomSynthesis: false)
    let data = try JSONEncoder().encode(draft)
    let restored = try JSONDecoder().decode(ModelResourceSourceDraft.self, from: data)
    #expect(restored.useCustomRecognition && !restored.useCustomSynthesis)
    #expect(!String(decoding: data, as: UTF8.self).contains("preferDownloadedSpeech"))
    #expect(ModelResourceGroup.recognition.modelIDs == ["nemotron", "silero"])
    #expect(ModelResourceGroup.synthesis.modelIDs == ["moss-tts-nano"])
    #expect(ModelResourceGroup.language.modelIDs == ["gemma4-e2b"])
    #expect(ModelResourceGroup.vision.modelIDs == ["yolo26n-pose"])
}

@MainActor @Test func missingRecognitionResourcesBounceSwitchAndPresentInstallNotice() async {
    let state = ModelResourcesState()
    let operations = ResourceOperationsFixture(state: state)
    operations.missingGroup = .recognition
    let workflow = ModelResourceInteractionWorkflow(state: state, operations: operations)
    await workflow.restore()
    await workflow.setCustomModel(.recognition, enabled: true)
    #expect(!state.source.useCustomRecognition)
    #expect(!state.source.useCustomSynthesis)
    #expect(state.installationNotice == ModelResourceGroup.recognition.installationMessage)
    #expect(state.error == nil)
    #expect(!state.saving)
}

@MainActor @Test func speechSwitchPreservesUnsavedDownloadSourceEdits() async {
    let state = ModelResourcesState()
    let operations = ResourceOperationsFixture(state: state)
    let workflow = ModelResourceInteractionWorkflow(state: state, operations: operations)
    await workflow.restore()
    state.source.endpoint = "unfinished-domain-edit"
    state.source.allowsCellular = true
    await workflow.setCustomModel(.synthesis, enabled: true)
    #expect(state.source.endpoint == "unfinished-domain-edit")
    #expect(state.source.allowsCellular)
    #expect(state.source.useCustomSynthesis)
    #expect(!state.source.useCustomRecognition)
    #expect(operations.storedSource.endpoint == "https://huggingface.co")
    #expect(operations.storedSource.allowsCellular)
    #expect(operations.storedSource.useCustomSynthesis)
}

@MainActor @Test func automaticDownloadSourceSavePreservesVoiceModesAndPrecedesAdmission() async {
    let state = ModelResourcesState()
    let operations = ResourceOperationsFixture(state: state)
    operations.storedSource.useCustomSynthesis = true
    operations.storedSource.allowsCellular = false
    let workflow = ModelResourceInteractionWorkflow(state: state, operations: operations)
    await workflow.restore()
    state.source.endpoint = "https://hf-mirror.com"
    state.source.useCustomRecognition = true  // Unsaved switch draft must not leak into endpoint persistence.
    await workflow.perform("model", operation: .download)
    #expect(operations.downloads == 1)
    #expect(operations.storedSource.endpoint == "https://hf-mirror.com")
    #expect(operations.storedSource.allowsCellular)
    #expect(!operations.storedSource.useCustomRecognition)
    #expect(operations.storedSource.useCustomSynthesis)
}

@MainActor @Test func failedAutomaticSourceSavePreventsDownloadAndRetainsRetryDraft() async {
    let state = ModelResourcesState()
    let operations = ResourceOperationsFixture(state: state)
    let workflow = ModelResourceInteractionWorkflow(state: state, operations: operations)
    await workflow.restore()
    operations.failSave = true
    state.source.endpoint = "https://hf-mirror.com"
    await workflow.perform("model", operation: .download)
    #expect(operations.downloads == 0)
    #expect(state.source.endpoint == "https://hf-mirror.com")
    #expect(operations.storedSource.endpoint == "https://huggingface.co")
    #expect(state.error != nil)
    operations.failSave = false
    await workflow.perform("model", operation: .download)
    #expect(operations.downloads == 1)
    #expect(operations.storedSource.endpoint == "https://hf-mirror.com")
}

@MainActor @Test(.timeLimit(.minutes(1))) func modelResourceAdmissionSurvivesCancelledPageCaller() async throws {
    let state = ModelResourcesState()
    let operations = ResourceOperationsFixture(state: state)
    operations.blockAdmission = true
    let workflow = ModelResourceInteractionWorkflow(state: state, operations: operations)
    await workflow.restore()
    let page = Task { await workflow.perform("model", operation: .download) }
    while operations.admission == nil { await Task.yield() }
    page.cancel()
    #expect(state.isDownloading(state.items[0]))
    operations.admission?.resume()
    operations.admission = nil
    await page.value
    #expect(operations.active)
    #expect(state.isDownloading(state.items[0]))
    await workflow.perform("model", operation: .cancel)
    #expect(!state.isBusy(state.items[0]))
}

@MainActor @Test func preferenceFailureDoesNotRetryEffectfulRestoreDuringRollbackOrStatusPolling() async {
    let state = ModelResourcesState()
    let operations = ResourceOperationsFixture(state: state)
    let workflow = ModelResourceInteractionWorkflow(state: state, operations: operations)
    await workflow.restore()
    let baseline = operations.restoreCalls
    operations.failSave = true
    state.source.useCustomRecognition = true
    await workflow.saveSource()
    await workflow.refresh()
    #expect(operations.restoreCalls == baseline)
    #expect(!state.source.useCustomRecognition)
    #expect(state.error != nil)
    operations.failSave = false
    await workflow.restore()
    #expect(operations.restoreCalls > baseline)
}

@MainActor @Test func resourceSnapshotAndFailureRejectSupersededRefreshRevisions() {
    let state = ModelResourcesState()
    let old = state.beginRefresh()
    let current = state.beginRefresh()
    let snapshot = ModelResourceViewSnapshot(items: [], installedGroups: [.recognition])
    #expect(!state.applySnapshot(snapshot, generation: old))
    #expect(!state.applyRefreshFailure("old error", generation: old))
    #expect(state.installedGroups.isEmpty && state.error == nil)
    #expect(state.applySnapshot(snapshot, generation: current))
    #expect(state.applyRefreshFailure("current error", generation: current))
    #expect(state.installedGroups == [.recognition] && state.error == "current error")
    state.beginRefresh()  // A mutation admission invalidates any in-flight refresh.
    #expect(!state.applySnapshot(.init(items: []), generation: current))
}

@MainActor @Test func alreadyPresentedRefreshFailureIsNotOverwrittenByWorkflowErrorProjection() async {
    let state = ModelResourcesState()
    let operations = ResourceOperationsFixture(state: state)
    let workflow = ModelResourceInteractionWorkflow(state: state, operations: operations)
    await workflow.restore()
    operations.failRefresh = true
    operations.refreshErrorPresented = true
    await workflow.refresh()
    #expect(state.error == "primary refresh failure")
    #expect(state.items.count == 1)
}

@MainActor @Test func acknowledgedRecoverySnapshotReleasesAdmittedDownloadLock() async {
    let state = ModelResourcesState()
    let operations = ResourceOperationsFixture(state: state)
    let workflow = ModelResourceInteractionWorkflow(state: state, operations: operations)
    await workflow.restore()
    operations.failRefresh = true
    await workflow.perform("model", operation: .download)
    #expect(state.isBusy(state.items[0]))
    operations.active = false
    operations.failRefresh = false
    let generation = state.beginRefresh()
    _ = try? operations.refresh(generation: generation)
    #expect(state.isBusy(state.items[0]))
    workflow.acceptPresentedSnapshot()
    #expect(!state.isBusy(state.items[0]))
    await workflow.perform("model", operation: .remove)
    #expect(operations.removals == 1)
}

@MainActor @Test func alreadyPresentedCommandFailurePreservesAcceptedErrorAndReleasesAdmissionLocks() async {
    let state = ModelResourcesState()
    let operations = ResourceOperationsFixture(state: state)
    let workflow = ModelResourceInteractionWorkflow(state: state, operations: operations)
    await workflow.restore()
    operations.commandFailurePresented = true
    await workflow.perform("model", operation: .download)
    #expect(state.error == "accepted operation error")
    #expect(!state.isBusy(state.items[0]))
    operations.commandFailurePresented = false
    await workflow.perform("model", operation: .download)
    #expect(operations.downloads == 2)
}

@MainActor @Test func acceptedPreferenceNoticePreservesPresentationAndRollsBackOnlyVisibleFlags() async {
    let state = ModelResourcesState()
    let operations = ResourceOperationsFixture(state: state)
    let workflow = ModelResourceInteractionWorkflow(state: state, operations: operations)
    await workflow.restore()
    operations.missingGroup = .recognition
    operations.preferenceFailurePresented = true
    await workflow.setCustomModel(.recognition, enabled: true)
    #expect(state.installationNotice == ModelResourceGroup.recognition.installationMessage)
    #expect(state.error == nil)
    #expect(!state.source.useCustomRecognition && !state.saving)
    #expect(!operations.storedSource.useCustomRecognition)
    let restores = operations.restoreCalls
    await workflow.refresh()
    #expect(operations.restoreCalls == restores)
}
@MainActor @Test func acceptedPreferenceErrorSurvivesRollbackAndProgressWithoutImplicitRestore() async {
    let state = ModelResourcesState()
    let operations = ResourceOperationsFixture(state: state)
    let workflow = ModelResourceInteractionWorkflow(state: state, operations: operations)
    await workflow.restore()
    state.source.useCustomRecognition = true
    operations.failSave = true
    operations.preferenceFailurePresented = true
    await workflow.saveSource()
    #expect(state.error == "accepted preference failure")
    #expect(!state.source.useCustomRecognition && !state.saving)
    let restores = operations.restoreCalls
    await workflow.refresh()
    #expect(operations.restoreCalls == restores)
    #expect(state.error == "accepted preference failure")
}
@MainActor @Test func acceptedRestoreAndDownloadSourceErrorsAreNotOverwrittenByLocalProjection() async {
    let state = ModelResourcesState()
    let operations = ResourceOperationsFixture(state: state)
    let workflow = ModelResourceInteractionWorkflow(state: state, operations: operations)
    operations.restoreFailurePresented = true
    await workflow.restore()
    #expect(state.error == "accepted restore failure" && !state.hasRestored)
    operations.restoreFailurePresented = false
    await workflow.restore()
    state.source.endpoint = "https://new.example"
    operations.failSave = true
    operations.preferenceFailurePresented = true
    #expect(!(await workflow.saveDownloadSource()))
    #expect(state.error == "accepted preference failure" && !state.saving)
    #expect(state.source.endpoint == "https://new.example")
}

import AppSettingsWorkflow
import Foundation
import Testing
import UI

@MainActor private final class ResourceOperationsFixture: ModelResourcesOperating {
    var downloads = 0
    var cancellations = 0
    var removals = 0
    var admission: CheckedContinuation<Void, Error>?
    var cancellation: CheckedContinuation<Void, Error>?
    var blockAdmission = false
    var blockCancellation = false
    var active = false
    var failDownload = false
    var failRefresh = false
    var failSave = false
    var missingGroup: ModelResourceGroup?
    var storedSource = ModelResourceSourceDraft()
    func refresh() throws -> [ModelResourceItem] {
        if failRefresh { throw CocoaError(.fileReadUnknown) }
        return [
            .init(
                id: "model", name: "Model", status: active ? "正在下载" : "未下载", bytes: 100,
                progress: 0.42, installed: false, active: active, failure: "previous failure",
                activity: active ? .downloading : nil)
        ]
    }
    func restoreSource() -> ModelResourceSourceDraft { storedSource }
    func saveSource(_ source: ModelResourceSourceDraft) throws {
        if let missingGroup { throw ModelResourceSelectionError(group: missingGroup) }
        if failSave { throw CocoaError(.fileWriteUnknown) }
        storedSource = source
    }
    func download(_ id: String) async throws {
        downloads += 1
        if blockAdmission { try await withCheckedThrowingContinuation { admission = $0 } }
        try Task.checkCancellation()
        if failDownload { throw CocoaError(.fileReadUnknown) }
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
    let operations = ResourceOperationsFixture()
    operations.blockAdmission = true
    operations.blockCancellation = true
    let state = ModelResourcesState()
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
    let operations = ResourceOperationsFixture()
    operations.active = true
    let state = ModelResourcesState()
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
    let operations = ResourceOperationsFixture()
    let state = ModelResourcesState()
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
    let operations = ResourceOperationsFixture()
    operations.failSave = true
    let state = ModelResourcesState()
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
    let nemotron = ModelResourceItem(
        id: "nemotron", name: "ASR", status: "Installed", bytes: 1,
        progress: 1, installed: true, active: false, failure: nil)
    let silero = ModelResourceItem(
        id: "silero", name: "VAD", status: "Installed", bytes: 1,
        progress: 1, installed: true, active: false, failure: nil)
    #expect(ModelResourcePolicy.isInstalled(.recognition, in: [nemotron]))
    #expect(!ModelResourcePolicy.isInstalled(.recognition, in: [silero]))
    #expect(ModelResourceGroup.synthesis.modelIDs == ["moss-tts-nano"])
    #expect(ModelResourceGroup.language.modelIDs == ["gemma4-e2b"])
    #expect(ModelResourceGroup.vision.modelIDs == ["yolo26n-pose"])
}

@MainActor @Test func missingRecognitionResourcesBounceSwitchAndPresentInstallNotice() async {
    let operations = ResourceOperationsFixture()
    operations.missingGroup = .recognition
    let state = ModelResourcesState()
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
    let operations = ResourceOperationsFixture()
    let state = ModelResourcesState()
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
    let operations = ResourceOperationsFixture()
    operations.storedSource.useCustomSynthesis = true
    operations.storedSource.allowsCellular = false
    let state = ModelResourcesState()
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
    let operations = ResourceOperationsFixture()
    let state = ModelResourcesState()
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
    let operations = ResourceOperationsFixture()
    operations.blockAdmission = true
    let state = ModelResourcesState()
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

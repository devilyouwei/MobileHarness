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
    func refresh() throws -> [ModelResourceItem] {
        if failRefresh { throw CocoaError(.fileReadUnknown) }
        return [
            .init(
                id: "model", name: "Model", status: active ? "正在下载" : "未下载", bytes: 100,
                progress: 0.42, installed: false, active: active, failure: "previous failure",
                activity: active ? .downloading : nil)
        ]
    }
    func restoreSource() -> ModelResourceSourceDraft { .init() }
    func saveSource(_ source: ModelResourceSourceDraft) {}
    func download(_ id: String) async throws {
        downloads += 1
        if blockAdmission { try await withCheckedThrowingContinuation { admission = $0 } }
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
    let state = ModelResourcesState(operations: operations)
    await state.restore()
    let download = Task { await state.perform("model", operation: "download") }
    while operations.admission == nil { await Task.yield() }
    let item = state.items[0]
    #expect(state.isDownloading(item))
    #expect(state.status(item) == "正在提交下载…")
    await state.perform("model", operation: "download")
    await state.perform("model", operation: "remove")
    #expect(operations.downloads == 1)
    #expect(operations.removals == 0)
    let cancel = Task { await state.perform("model", operation: "cancel") }
    while !state.isCancelling("model") { await Task.yield() }
    await state.perform("model", operation: "cancel")
    #expect(operations.cancellations == 0)
    operations.admission?.resume()
    operations.admission = nil
    while operations.cancellation == nil { await Task.yield() }
    await state.perform("model", operation: "cancel")
    await state.perform("model", operation: "download")
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
    let state = ModelResourcesState(operations: operations)
    await state.restore()
    await state.perform("model", operation: "download")
    await state.perform("model", operation: "remove")
    #expect(operations.downloads == 0)
    #expect(operations.removals == 0)
    #expect(state.items[0].progress == 0.42)
    await state.perform("model", operation: "cancel")
    #expect(operations.cancellations == 1)
    operations.failDownload = true
    await state.perform("model", operation: "download")
    #expect(state.error != nil)
    #expect(!state.isBusy(state.items[0]))
    operations.failDownload = false
    await state.perform("model", operation: "download")
    #expect(operations.downloads == 2)
    #expect(state.items[0].active)
}

@MainActor @Test func failedStatusRefreshKeepsAdmittedDownloadLockedUntilCancellation() async {
    let operations = ResourceOperationsFixture()
    let state = ModelResourcesState(operations: operations)
    await state.restore()
    operations.failRefresh = true
    await state.perform("model", operation: "download")
    #expect(state.isDownloading(state.items[0]))
    #expect(state.error != nil)
    await state.perform("model", operation: "download")
    await state.perform("model", operation: "remove")
    #expect(operations.downloads == 1)
    #expect(operations.removals == 0)
    operations.failRefresh = false
    await state.perform("model", operation: "cancel")
    #expect(operations.cancellations == 1)
    #expect(!state.isBusy(state.items[0]))
}

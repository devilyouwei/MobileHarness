import AppSettingsWorkflow
import Foundation
import Storage
import Testing
import UI

@MainActor private final class PreferenceFacadeFixture {
    var value = ModelResourceSourceDraft()
    var restores = 0
    var fail = false
    var downloads: [String] = []
    func restore() async throws -> ModelResourceSourceDraft {
        restores += 1
        return value
    }
    func save(_ draft: ModelResourceSourceDraft) async throws -> ModelResourceSourceDraft {
        value = draft
        if fail { throw CocoaError(.coderInvalidValue) }
        return value
    }
    func workflow() -> ModelResourcesWorkflow {
        ModelResourcesWorkflow(
            read: { _ in .init(items: []) }, restore: { try await self.restore() }, save: { try await self.save($0) },
            download: { _, source in self.downloads.append(source.endpoint) }, cancel: { _ in }, remove: { _ in })
    }
}
@MainActor @Test func preferenceFacadeCachesSuccessfulAgentResultsAndDownloadsUseSavedSource() async throws {
    let fixture = PreferenceFacadeFixture()
    let workflow = fixture.workflow()
    _ = try await workflow.restoreSource()
    _ = try await workflow.restoreSource()
    #expect(fixture.restores == 1)
    try await workflow.saveSource(.init(endpoint: "https://example.invalid"))
    try await workflow.download("fixture")
    #expect(fixture.downloads == ["https://example.invalid"])
}
@MainActor @Test func committedSpeechPreferenceApplicationFailureInvalidatesCacheAndRetriesDurableValue() async throws {
    let fixture = PreferenceFacadeFixture()
    let workflow = fixture.workflow()
    _ = try await workflow.restoreSource()
    fixture.fail = true
    await #expect(throws: CocoaError.self) { try await workflow.saveSource(.init(useCustomRecognition: true)) }
    #expect(try await workflow.restoreSource().useCustomRecognition)
    #expect(fixture.restores == 2)
}
@MainActor @Test func preferenceFacadeRefreshAndRemovalReloadAgentReconciliation() async throws {
    let fixture = PreferenceFacadeFixture()
    let workflow = fixture.workflow()
    _ = try await workflow.restoreSource()
    fixture.value.useCustomSynthesis = true
    _ = try await workflow.refresh()
    #expect(try await workflow.restoreSource().useCustomSynthesis)
    fixture.value.useCustomSynthesis = false
    try await workflow.remove("fixture")
    #expect(try await workflow.restoreSource().useCustomSynthesis == false)
    #expect(fixture.restores == 3)
}

@MainActor private final class HeldPreferenceFacadeFixture {
    nonisolated let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private var continuation: CheckedContinuation<Void, Never>?
    var restores = 0
    func restore() async -> ModelResourceSourceDraft {
        restores += 1
        await withCheckedContinuation {
            continuation = $0
            started.continuation.yield(())
        }
        return .init(endpoint: "https://example.invalid")
    }
    func finish() {
        continuation?.resume()
        continuation = nil
    }
}
@MainActor @Test func concurrentPreferenceRestoreSharesAgentRequestAndPageCancellationDoesNotOwnIt() async throws {
    let fixture = HeldPreferenceFacadeFixture()
    let workflow = ModelResourcesWorkflow(
        read: { _ in .init(items: []) }, restore: { await fixture.restore() }, save: { $0 },
        download: { _, _ in }, cancel: { _ in }, remove: { _ in })
    var started = fixture.started.stream.makeAsyncIterator()
    let first = Task { try await workflow.restoreSource() }
    await started.next()
    let second = Task { try await workflow.restoreSource() }
    await Task.yield()
    first.cancel()
    fixture.finish()
    let values = try await [first.value, second.value]
    #expect(values.allSatisfy { $0.endpoint == "https://example.invalid" })
    #expect(fixture.restores == 1)
}

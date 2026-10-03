import AppSettingsWorkflow
import Foundation
import Storage
import Testing
import UI

@MainActor @Test func modelDownloadSourcePersistsBeforeNewDownloadAndRejectsInvalidEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalDocumentStore<ModelResourceSourceDraft>(
        url: root.appendingPathComponent("source.json"), maximumBytes: 4096)
    var downloads: [String] = []
    var applied: [Bool] = []
    let workflow = ModelResourcesWorkflow(
        store: { store }, read: { [] },
        validate: { source in
            guard source.endpoint.hasPrefix("https://") else { throw CocoaError(.fileReadInvalidFileName) }
            return source
        }, download: { _, source in downloads.append(source.endpoint) }, cancel: { _ in }, remove: { _ in },
        apply: { applied.append($0.useCustomRecognition) })
    #expect(try await workflow.restoreSource().endpoint == "https://huggingface.co")
    try await workflow.saveSource(
        ModelResourceSourceDraft(endpoint: "https://hf-mirror.com", allowsCellular: true, useCustomRecognition: false)
    )
    try await workflow.download("fixture")
    #expect(downloads == ["https://hf-mirror.com"])
    await #expect(throws: CocoaError.self) { try await workflow.saveSource(ModelResourceSourceDraft(endpoint: "bad")) }
    #expect(try await workflow.restoreSource().endpoint == "https://hf-mirror.com")
    let persisted = try await store.refresh()?.value
    #expect(persisted?.endpoint == "https://hf-mirror.com")
    #expect(persisted?.allowsCellular == true)
    #expect(persisted?.useCustomRecognition == false)
    #expect(applied == [false, false])
}

@MainActor private func modelItem(_ id: String) -> ModelResourceItem {
    .init(id: id, name: id, status: "已安装", bytes: 1, progress: 1, installed: true, active: false, failure: nil)
}

@MainActor @Test func customSpeechRequiresCompleteResourcesAndRemovalDisablesOnlyOwningFeature() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalDocumentStore<ModelResourceSourceDraft>(
        url: root.appendingPathComponent("source.json"), maximumBytes: 4096)
    var installed: Set<String> = ["silero"]
    var applied: [[Bool]] = []
    let workflow = ModelResourcesWorkflow(
        store: { store }, read: { installed.sorted().map(modelItem) }, validate: { $0 },
        download: { _, _ in }, cancel: { _ in }, remove: { installed.remove($0) },
        apply: { applied.append([$0.useCustomRecognition, $0.useCustomSynthesis]) })
    _ = try await workflow.restoreSource()
    await #expect(throws: ModelResourceSelectionError.self) {
        try await workflow.saveSource(.init(useCustomRecognition: true))
    }
    #expect(try await workflow.restoreSource().useCustomRecognition == false)
    #expect(try await store.refresh() == nil)
    installed.insert("nemotron")
    try await workflow.saveSource(.init(useCustomRecognition: true))
    #expect(try await workflow.restoreSource().useCustomRecognition)
    #expect(try await workflow.restoreSource().useCustomSynthesis == false)
    await #expect(throws: ModelResourceSelectionError.self) {
        try await workflow.saveSource(.init(useCustomRecognition: true, useCustomSynthesis: true))
    }
    installed.insert("moss-tts-nano")
    try await workflow.saveSource(.init(useCustomRecognition: true, useCustomSynthesis: true))
    try await workflow.remove("silero")
    #expect(try await workflow.restoreSource().useCustomRecognition)
    try await workflow.remove("nemotron")
    let saved = try await workflow.restoreSource()
    #expect(!saved.useCustomRecognition)
    #expect(saved.useCustomSynthesis)
    #expect(applied == [[false, false], [true, false], [true, true], [false, true]])
    #expect(try await store.refresh()?.value.useCustomRecognition == false)
}

@MainActor @Test func restoredSpeechPolicyClearsMissingModelsBeforeApplyingAndPreservesDownloadSource() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalDocumentStore<ModelResourceSourceDraft>(
        url: root.appendingPathComponent("source.json"), maximumBytes: 4096)
    try await store.save(
        .init(
            endpoint: "https://hf-mirror.com", allowsCellular: true, useCustomRecognition: true,
            useCustomSynthesis: true), expecting: nil)
    var applied: [[Bool]] = []
    let workflow = ModelResourcesWorkflow(
        store: { store }, read: { [modelItem("silero"), modelItem("moss-tts-nano")] }, validate: { $0 },
        download: { _, _ in }, cancel: { _ in }, remove: { _ in },
        apply: { applied.append([$0.useCustomRecognition, $0.useCustomSynthesis]) })
    let source = try await workflow.restoreSource()
    #expect(source.endpoint == "https://hf-mirror.com")
    #expect(source.allowsCellular)
    #expect(!source.useCustomRecognition && source.useCustomSynthesis)
    #expect(applied == [[false, true]])
    #expect(try await store.refresh()?.value.useCustomRecognition == false)
}

@MainActor @Test func concurrentPreferenceRestoreSharesMigrationAndAppliesOnce() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalDocumentStore<ModelResourceSourceDraft>(
        url: root.appendingPathComponent("source.json"), maximumBytes: 4096)
    try await store.save(.init(useCustomRecognition: true, useCustomSynthesis: true), expecting: nil)
    var applies = 0
    let workflow = ModelResourcesWorkflow(
        store: { store }, read: { [] }, validate: { $0 }, download: { _, _ in }, cancel: { _ in }, remove: { _ in },
        apply: { _ in applies += 1 })
    async let first = workflow.restoreSource()
    async let second = workflow.restoreSource()
    let sources = try await [first, second]
    #expect(sources.allSatisfy { !$0.useCustomRecognition && !$0.useCustomSynthesis })
    #expect(applies == 1)
}

@MainActor @Test func restoredNetworkRestrictionIsMigratedBeforeDownload() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalDocumentStore<ModelResourceSourceDraft>(
        url: root.appendingPathComponent("source.json"), maximumBytes: 4096)
    try await store.save(.init(allowsCellular: false), expecting: nil)
    var permitted = false
    let workflow = ModelResourcesWorkflow(
        store: { store }, read: { [] },
        validate: { draft in
            var value = draft
            value.allowsCellular = true
            return value
        }, download: { _, draft in permitted = draft.allowsCellular }, cancel: { _ in }, remove: { _ in })
    #expect(try await workflow.restoreSource().allowsCellular)
    #expect(try await store.refresh()?.value.allowsCellular == true)
    try await workflow.download("fixture")
    #expect(permitted)
}

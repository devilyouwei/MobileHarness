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
    let workflow = ModelResourcesWorkflow(
        store: { store }, read: { [] },
        validate: { source in
            guard source.endpoint.hasPrefix("https://") else { throw CocoaError(.fileReadInvalidFileName) }
            return source
        }, download: { _, source in downloads.append(source.endpoint) }, cancel: { _ in }, remove: { _ in })
    #expect(try await workflow.restoreSource().endpoint == "https://huggingface.co")
    try await workflow.saveSource(ModelResourceSourceDraft(endpoint: "https://hf-mirror.com", allowsCellular: true))
    try await workflow.download("fixture")
    #expect(downloads == ["https://hf-mirror.com"])
    await #expect(throws: CocoaError.self) { try await workflow.saveSource(ModelResourceSourceDraft(endpoint: "bad")) }
    #expect(try await workflow.restoreSource().endpoint == "https://hf-mirror.com")
    let persisted = try await store.refresh()?.value
    #expect(persisted?.endpoint == "https://hf-mirror.com")
    #expect(persisted?.allowsCellular == true)
}

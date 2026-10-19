import Foundation
import ModelKit
import ModelKitDefaults
import ModelKitRuntime
import Testing

@Test @MainActor func modelRootsAreIsolatedLazyAndTerminal() async throws {
    guard #available(macOS 27, iOS 27, *) else { return }
    let resources = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let first = ModelContainer(resources: resources)
    let second = ModelContainer(resources: resources)
    #expect(first.language !== second.language)
    #expect(first.speech !== second.speech)
    #expect(first.vision !== second.vision)
    #expect(first.artifacts !== second.artifacts)
    await #expect(throws: InferenceAdmissionError.self) { try await first.language.warmup() }
    try await first.start()
    try await second.start()
    #expect(try await first.language.status() == .registered)
    #expect(try await first.vision.status() == .registered)
    #expect(try await first.speech.status(.recognition) == .registered)
    try await first.speech.unload(.synthesis)
    try await first.setForeground(true)
    try await second.setForeground(true)
    // Registering defaults does not require any model artifact directory or device permission.
    #expect(!FileManager.default.fileExists(atPath: resources.path))
    first.invalidate()
    await #expect(throws: InferenceAdmissionError.self) { try await first.speech.warmup(.synthesis) }
    try await first.setForeground(false)
    try await first.setForeground(true)
    let oldLanguage = first.language
    try await first.stop()
    try await first.stop()
    await #expect(throws: InferenceAdmissionError.self) { try await oldLanguage.warmup() }
    await #expect(throws: InferenceAdmissionError.self) { try await first.start() }
    // Another root with the same resource path is independent and remains usable.
    try await second.speech.configure(recognition: false, synthesis: false)
    try await second.stop()
}

@Test @MainActor func stoppedModelRootCannotPrepareArtifactsOrReopenPorts() async throws {
    guard #available(macOS 27, iOS 27, *) else { return }
    let root = ModelContainer(resources: URL(fileURLWithPath: "/missing/models"))
    let port = root.artifacts
    try await root.stop()
    await #expect(throws: InferenceAdmissionError.self) { try await port.prepare() }
    await #expect(throws: InferenceAdmissionError.self) { try await root.setForeground(true) }
}

@Test @MainActor func modelChatConfigurationIsRootLocalAndUpdatesRetainedPort() async throws {
    guard #available(macOS 27, iOS 27, *) else { return }
    let path = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let first = ModelContainer(resources: path)
    let second = ModelContainer(resources: path)
    try await first.start()
    try await second.start()
    try await first.setForeground(true)
    try await second.setForeground(true)
    let port = first.language
    #expect(await !port.supportsToolCalls)
    try await port.configure(
        .init(baseURL: URL(string: "https://models.example.invalid/v1")!, apiKey: "", model: "fixture"))
    #expect(await port.supportsToolCalls)
    #expect(await !second.language.supportsToolCalls)
    try await port.configure(nil)
    #expect(await !port.supportsToolCalls)
    #expect(!FileManager.default.fileExists(atPath: path.path))
    try await first.stop()
    try await second.stop()
}

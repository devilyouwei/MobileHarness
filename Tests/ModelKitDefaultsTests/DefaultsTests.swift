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
    await #expect(throws: ModelFailure.self) { try await first.start() }
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
    await #expect(throws: ModelFailure.self) { try await root.setForeground(true) }
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
    let fixedLocal = try await port.chatModel(configuration: nil)
    #if targetEnvironment(simulator)
        let localTools = false
    #else
        let localTools = true
    #endif
    #expect(await port.supportsToolCalls == localTools)
    #expect(await !port.supportsImages)
    try await port.configure(
        .init(baseURL: URL(string: "https://models.example.invalid/v1")!, apiKey: "", model: "fixture"))
    #expect(await port.supportsToolCalls)
    #expect(await port.supportsImages)
    #expect(await fixedLocal.capability.supportsToolCalls == localTools)
    #expect(await !fixedLocal.capability.supportsImages)
    #expect(await second.language.supportsToolCalls == localTools)
    #expect(await !second.language.supportsImages)
    try await port.configure(nil)
    #expect(await port.supportsToolCalls == localTools)
    #expect(await !port.supportsImages)
    #expect(!FileManager.default.fileExists(atPath: path.path))
    try await first.stop()
    try await second.stop()
}

@Test @MainActor func modelPreparationStepsPreserveDemandAndRejectStoppedScope() async throws {
    let root = ModelContainer(resources: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let steps = root.preparationSteps(for: [.vision, .language, .vision])
    #expect(steps.map(\.id) == ["vision", "language"])
    try await root.start()
    #expect(try await !steps[0].isReady())
    #expect(try await !steps[1].isReady())
    try await root.stop()
    await #expect(throws: InferenceAdmissionError.self) { try await steps[0].prepare { _ in } }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["APPLE_APP_CHAT_SMOKE"] == "1"))
@MainActor func appleAppChatSelectionUsesSystemModelWithTextOnlyHistory() async throws {
    guard #available(macOS 27, iOS 27, *) else { return }
    let root = ModelContainer(resources: FileManager.default.temporaryDirectory)
    try await root.start()
    do {
        try await root.setForeground(true)
        let apple = try await root.language.localChatModel("apple-system")
        #expect(await apple.capability.availability == .available)
        #expect(await !apple.capability.supportsToolCalls)
        try await root.language.configure(nil, localModelID: "apple-system")
        #expect(await !root.language.supportsToolCalls)
        let request = try ChatRequest(
            messages: [
                .init(role: .user, content: "Check the status."),
                .init(
                    role: .assistant, content: "", toolCalls: [.init(id: "status", name: "status", argumentsJSON: "{}")]
                ),
                .init(role: .tool, content: "Ready.", toolCallID: "status"),
                .init(role: .system, content: "Reply with a short English phrase."),
                .init(role: .user, content: "What did the status check say?"),
            ], maximumOutputTokens: 24, temperature: 0)
        let inference = try await root.language.chat(request)
        let result = try await inference.withCleanup {
            var output = ""
            for try await event in inference.events {
                if case .text(let text) = event { output += text }
            }
            return output
        }
        #expect(!result.isEmpty)
    } catch {
        try await root.stop()
        throw error
    }
    try await root.stop()
}

@Test @MainActor func optionalLocalPreparationSkipsUnselectedAndPropagatesSelectionFailure() async throws {
    let root = ModelContainer(resources: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let empty = root.localModelPreparationStep(id: "decision") { nil }
    #expect(try await empty.isReady())
    try await empty.prepare { _ in Issue.record("Unselected model must not report loading") }
    let failed = root.localModelPreparationStep(id: "decision") { throw CancellationError() }
    await #expect(throws: CancellationError.self) { try await failed.isReady() }
    await #expect(throws: CancellationError.self) { try await failed.prepare { _ in } }
    let unknown = root.localModelPreparationStep(id: "decision") { "unknown" }
    await #expect(throws: CapabilityError.self) { try await unknown.isReady() }
}

@Test @MainActor
func localPreparationUsesSelectedResourceAndRejectsStoppedScope() async throws {
    let root = ModelContainer(resources: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    try await root.start()
    for id in ["d3-edge", "vela3-fast", "vela3.1-fast", "laya-multilingual", "gemma4-e2b", "apple-system"] {
        let step = root.localModelPreparationStep(id: "decision") { id }
        #expect(step.id == "decision")
        #expect(try await !step.isReady())
    }
    for id in ["d3-edge", "vela3-fast", "vela3.1-fast", "laya-multilingual"] {
        #expect(root.language.decisionModel(id) != nil)
    }
    #expect(root.language.decisionModel("d3-lite") == nil)
    let removed = root.localModelPreparationStep(id: "decision") { "d3-lite" }
    await #expect(throws: CapabilityError.self) { try await removed.isReady() }
    let selected = root.localModelPreparationStep(id: "decision") { "d3-edge" }
    try await root.stop()
    await #expect(throws: InferenceAdmissionError.self) { try await selected.isReady() }
    await #expect(throws: InferenceAdmissionError.self) { try await selected.prepare { _ in } }
}

@Test @MainActor func deepFilterDefaultIsLazyAndExplicit() async throws {
    guard #available(macOS 27, iOS 27, *) else { return }
    let root = ModelContainer(resources: URL(fileURLWithPath: "/missing/deepfilter-default"))
    try await root.start()
    try await root.setForeground(true)
    #expect(try await root.speech.status(.enhancement) == .registered)
    #expect(await root.speech.enhancement.availability != .available)
    await #expect(throws: (any Error).self) { try await root.speech.load(.enhancement) }
    try await root.speech.unload(.enhancement)
    try await root.stop()
}

@Test @MainActor func speechEnhancementOptionalPreparationSkipsMissingSelection() async throws {
    guard #available(macOS 27, iOS 27, *) else { return }
    let root = ModelContainer(resources: URL(fileURLWithPath: "/missing/enhancement-preload"))
    try await root.start()
    try await root.setForeground(true)
    let absent = root.localModelPreparationStep(id: "enhancement") { nil }
    #expect(try await absent.isReady())
    try await absent.prepare { _ in Issue.record("Missing optional model must not load") }
    #expect(try await root.speech.status(.enhancement) == .registered)
    let selected = root.localModelPreparationStep(id: "enhancement") { "deepfilternet3" }
    #expect(try await !selected.isReady())
    await #expect(throws: (any Error).self) { try await selected.prepare { _ in } }
    try await root.stop()
}

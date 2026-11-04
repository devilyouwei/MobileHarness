import Foundation
import ModelKit
import ModelKitOpenAI
import Testing

@testable import ModelKitDefaults

private actor LocalChatProbe: ChatCapability {
    nonisolated let availability: CapabilityAvailability = .available
    var starts: [String] = []
    var emitters: [String: InferenceEmitter<ChatEvent>] = [:]
    var cleaning = false
    var release: CheckedContinuation<Void, Never>?
    var released = false
    func chat(_ request: ChatRequest) throws -> InferenceSession<ChatEvent> {
        let id = request.messages[0].content
        starts.append(id)
        let pair = InferenceSession<ChatEvent>.make(
            limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes },
            waitForCompletion: { await self.cleanup(id) })
        emitters[id] = pair.emitter
        return pair.session
    }
    func cleanup(_ id: String) async {
        guard id == "held", !released else { return }
        cleaning = true
        await withCheckedContinuation { release = $0 }
    }
    func releaseCleanup() {
        released = true
        release?.resume()
        release = nil
    }
    func complete(_ id: String, failed: Bool = false) {
        if failed { emitters[id]?.fail(CapabilityError.unavailable("fixture failure")) } else { emitters[id]?.finish() }
    }
}
private func chatEventually(_ condition: @Sendable () async -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(10)
    while !(await condition()) {
        guard ContinuousClock.now < end else { throw CapabilityError.unavailable("Chat fixture timed out") }
        try await Task.sleep(for: .milliseconds(5))
    }
}
private func localRequest(_ id: String) throws -> ChatRequest {
    try ChatRequest(messages: [.init(role: .user, content: id)])
}

@Test func localChatCapacityCancellationAndNativeCleanupAreIndependent() async throws {
    let probe = LocalChatProbe()
    let queue = try SerialChat(maximumPending: 8, model: { probe })
    let held = try await queue.chat(localRequest("held"))
    try await chatEventually { await probe.starts == ["held"] }
    #expect(held.phase == .running)
    var waiting: [InferenceSession<ChatEvent>] = []
    for id in 0..<8 { waiting.append(try await queue.chat(localRequest("wait-\(id)"))) }
    #expect(waiting.allSatisfy { $0.phase == .queued })
    await #expect(throws: CapabilityError.inputBusy) { try await queue.chat(localRequest("overflow")) }
    waiting[0].cancel()
    let replacement = try await queue.chat(localRequest("replacement"))
    #expect(replacement.phase == .queued)
    held.cancel()
    try await chatEventually { await probe.cleaning }
    #expect(await probe.starts == ["held"])
    await probe.releaseCleanup()
    try await chatEventually { await probe.starts == ["held", "wait-1"] }
    #expect(waiting[0].phase == .cancelled)
    await queue.cancelAll()
    #expect(waiting.allSatisfy { $0.phase == .cancelled })
    #expect(replacement.phase == .cancelled)
    #expect(await probe.starts.count == 2)
}

@Test func localChatFIFOAdvancesOnSuccessAndFailureAndFinishedHandlesDoNotOccupySlots() async throws {
    let probe = LocalChatProbe()
    let queue = try SerialChat(maximumPending: 1, model: { probe })
    let a = try await queue.chat(localRequest("a"))
    let b = try await queue.chat(localRequest("b"))
    try await chatEventually { await probe.starts == ["a"] }
    await probe.complete("a")
    try await chatEventually { await probe.starts == ["a", "b"] }
    let c = try await queue.chat(localRequest("c"))
    await probe.complete("b", failed: true)
    try await chatEventually { await probe.starts == ["a", "b", "c"] }
    await probe.complete("c")
    try await chatEventually { c.phase == .finished }
    #expect(a.phase == .finished && b.phase == .failed)
    let next = try await queue.chat(localRequest("next"))
    try await chatEventually { await probe.starts.last == "next" }
    await queue.cancelAll()
    #expect(next.phase == .cancelled)
}

@Test @MainActor func configuredChatHandlesKeepSelectionAndAreRetiredWithRoot() async throws {
    let root = ModelContainer(resources: .temporaryDirectory)
    try await root.start()
    try await root.setForeground(true)
    // Cloud configuration setup creates no HTTP request.
    let a = try OpenAIChatConfiguration(
        baseURL: #require(URL(string: "https://example.test/v1")), apiKey: "fixture", model: "a")
    let b = try OpenAIChatConfiguration(baseURL: a.baseURL, apiKey: "fixture", model: "b")
    let held = try await root.language.chatModel(configuration: a)
    try await root.language.configure(a)
    try await root.language.configure(b)
    #expect(held.modelName == "a")
    #expect(await root.language.supportsToolCalls)
    try await root.language.configure(a)
    let snapshot = try await root.language.stateSnapshot()
    #expect(snapshot.children.filter { $0.path.contains("cloud-chat-") }.count == 2)
    try await root.stop()
    await #expect(throws: (any Error).self) { try await held.capability.chat(localRequest("closed")) }
}

@Test func localConsumerFailureJoinsNativeCleanupBeforeReturningOrStartingNext() async throws {
    let probe = LocalChatProbe()
    let queue = try SerialChat(maximumPending: 8, model: { probe })
    let held = try await queue.chat(localRequest("held"))
    try await chatEventually { await probe.starts == ["held"] }
    let next = try await queue.chat(localRequest("next"))
    let consumer = Task {
        try await held.withCleanup { () async throws -> Void in
            throw CapabilityError.invalidRequest("consumer rejected output")
        }
    }
    try await chatEventually { await probe.cleaning }
    #expect(await probe.starts == ["held"])
    #expect(next.phase == .queued)
    await probe.releaseCleanup()
    await #expect(throws: CapabilityError.invalidRequest("consumer rejected output")) { try await consumer.value }
    try await chatEventually { await probe.starts == ["held", "next"] }
    await queue.cancelAll()
}

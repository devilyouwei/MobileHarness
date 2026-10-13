import ModelKit
@_spi(ModelAssembly) import ModelKitRuntime
import Testing

/// Test-only implementation: no model inference and no audio device access.
private struct FixtureProvider: ChatCapability, SpeechRecognitionCapability, SpeechSynthesisCapability {
    let reply: String
    var availability: CapabilityAvailability { .available }
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        let pair = InferenceSession<ChatEvent>.make(
            context: request.context, limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        try pair.emitter.yield(.text(reply))
        try pair.emitter.yield(.finished(.stop))
        pair.emitter.finish()
        return pair.session
    }
    func transcribe(_ request: SpeechRecognitionRequest) async throws -> SpeechRecognitionSession {
        let pair = InferenceSession<TranscriptionEvent>.make(
            context: request.context, limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        return SpeechRecognitionSession(
            output: pair.session, format: request.format,
            sendAudio: { _ in }, finishInput: { pair.emitter.finish() })
    }
    func synthesize(_ request: SpeechSynthesisRequest) async throws -> InferenceSession<SynthesisEvent> {
        let pair = InferenceSession<SynthesisEvent>.make(
            context: request.context, limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        try pair.emitter.yield(.finished)
        pair.emitter.finish()
        return pair.session
    }
}

private actor Counter {
    var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}

// This consumer uses only capability abstractions; changing the binding does not change its code.
private func reply(using capability: any ChatCapability) async throws -> String {
    let session = try await capability.chat(ChatRequest(messages: [ChatMessage(role: .user, content: "hello")]))
    defer { session.cancel() }
    var text = ""
    for try await event in session.events {
        if case .text(let delta) = event { text += delta }
    }
    return text
}

@Test func swappingModelsDoesNotChangeConsumer() async throws {
    let manager = try ModelManager()
    for name in ["first", "second"] {
        try await manager.register(
            ModelRegistration(id: ModelID(name), capabilities: [.chat]) { _ in
                ProvidedCapabilities(chat: FixtureProvider(reply: name))
            })
    }
    #expect(try await reply(using: manager.get(ModelID("first"), as: .chat)) == "first")
    #expect(try await reply(using: manager.get(ModelID("second"), as: .chat)) == "second")
}

@Test func oneProviderSupportsCompositionAndConstructsOnce() async throws {
    let manager = try ModelManager()
    let counter = Counter()
    let id = ModelID("multimodal-fixture")
    try await manager.register(
        ModelRegistration(id: id, capabilities: [.chat, .recognition, .synthesis]) { _ in
            _ = await counter.increment()
            let provider = FixtureProvider(reply: "shared")
            return ProvidedCapabilities(chat: provider, recognition: provider, synthesis: provider)
        })
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<10 {
            group.addTask {
                let voice = (
                    chat: try await manager.get(id, as: .chat),
                    recognition: try await manager.get(id, as: .recognition),
                    synthesis: try await manager.get(id, as: .synthesis)
                )
                #expect(await voice.recognition.availability == .available)
                #expect(try await reply(using: voice.chat) == "shared")
            }
        }
        try await group.waitForAll()
    }
    #expect(await counter.count == 1)
}

@Test func failedFactoryCanRetry() async throws {
    let manager = try ModelManager()
    let counter = Counter()
    let id = ModelID("retry")
    try await manager.register(
        ModelRegistration(id: id, capabilities: [.chat]) { _ in
            if await counter.increment() == 1 { throw CapabilityError.unavailable("fixture failure") }
            return ProvidedCapabilities(chat: FixtureProvider(reply: "recovered"))
        })
    await #expect(throws: CapabilityError.unavailable("fixture failure")) { _ = try await manager.get(id, as: .chat) }
    #expect(try await reply(using: manager.get(id, as: .chat)) == "recovered")
    #expect(await counter.count == 2)
}

@Test func registrationAndAcquisitionErrorsAreExplicit() async throws {
    let manager = try ModelManager()
    let id = ModelID("fixture")
    let registration = try ModelRegistration(id: id, capabilities: [.chat]) { _ in ProvidedCapabilities() }
    try await manager.register(registration)
    await #expect(throws: ModelRegistrationError.duplicateModel(id)) { try await manager.register(registration) }
    await #expect(throws: ModelRegistrationError.factoryContractMismatch) { _ = try await manager.get(id, as: .chat) }
    await #expect(throws: ModelRegistrationError.unsupportedCapability(.synthesis)) {
        _ = try await manager.get(id, as: .synthesis)
    }
    let unknownID = ModelID("unknown")
    await #expect(throws: ModelRegistrationError.unknownModel(unknownID)) {
        _ = try await manager.get(unknownID, as: .chat)
    }
}

private actor FactoryGate {
    private var open = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        open = true
        waiter?.resume()
        waiter = nil
    }
}

@Test func cancelledGetDoesNotCancelSharedConstruction() async throws {
    let manager = try ModelManager()
    let id = ModelID("shared-construction")
    let gate = FactoryGate()
    let counter = Counter()
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    try await manager.register(
        ModelRegistration(id: id, capabilities: [.chat]) { _ in
            _ = await counter.increment()
            entered.continuation.yield(())
            await gate.wait()
            return ProvidedCapabilities(chat: FixtureProvider(reply: "ready"))
        })
    let first = Task { try await manager.get(id, as: .chat) }
    var readiness = entered.stream.makeAsyncIterator()
    _ = await readiness.next()
    first.cancel()
    let second = Task { try await manager.get(id, as: .chat) }
    await gate.release()
    await #expect(throws: CancellationError.self) { _ = try await first.value }
    #expect(try await reply(using: second.value) == "ready")
    #expect(await counter.count == 1)
    entered.continuation.finish()
}

private struct FixtureVAD: VoiceActivityCapability {
    var availability: CapabilityAvailability { .available }
    func detectVoiceActivity(format: AudioFormat) async throws -> any VoiceActivitySession {
        throw CapabilityError.unavailable("Registration fixture only")
    }
}

@Test func voiceActivityCanBeRetrievedWithoutConcreteModelDependency() async throws {
    let manager = try ModelManager()
    let id = ModelID("test-vad")
    try await manager.register(
        ModelRegistration(id: id, capabilities: [.voiceActivity]) { _ in
            ProvidedCapabilities(voiceActivity: FixtureVAD())
        })
    let capability = try await manager.get(id, as: .voiceActivity)
    #expect(await capability.availability == .available)
}

@Test func defaultsAreUniqueAtomicAndReuseExplicitInstances() async throws {
    let manager = try ModelManager()
    let id = ModelID("default")
    try await manager.register(
        ModelRegistration(id: id, capabilities: [.chat]) { _ in
            ProvidedCapabilities(chat: FixtureProvider(reply: "default"))
        }, defaults: [.chat])
    #expect(try await reply(using: manager.get(.chat)) == "default")
    #expect(try await reply(using: manager.get(id, as: .chat)) == "default")
    await #expect(throws: ModelRegistrationError.missingDefault(.judge)) { _ = try await manager.get(.judge) }
    let other = ModelID("other")
    let registration = try ModelRegistration(id: other, capabilities: [.chat]) { _ in
        ProvidedCapabilities(chat: FixtureProvider(reply: "other"))
    }
    await #expect(throws: ModelRegistrationError.duplicateDefault(.chat)) {
        try await manager.register(registration, defaults: [.chat])
    }
    await #expect(throws: ModelRegistrationError.unknownModel(other)) { _ = try await manager.get(other, as: .chat) }
    await #expect(throws: ModelRegistrationError.invalidRegistration) {
        try await manager.register(registration, defaults: [.synthesis])
    }
    try await manager.register(registration)
    #expect(try await reply(using: manager.get(.chat)) == "default")
    try await manager.load(.chat)
    try await manager.warmup(.chat)
    try await manager.unload(.chat)
    #expect(try await manager.availability(.chat) == .available)
    #expect(try await manager.status(.chat) == .unmanaged)
    await manager.shutdown()
    await #expect(throws: CapabilityError.sessionClosed) { _ = try await manager.get(.chat) }
}

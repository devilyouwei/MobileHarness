import ActionRuntime
import Actions
import AgentCore
import Agents
import Foundation
import Gateway
import ModelKit
import StorageAudio
import Testing
import ToolRuntime

private func pcm(_ sequence: UInt64 = 0) throws -> AudioFrame {
    try AudioFrame(
        data: Data(repeating: 0, count: 16), format: AudioFormat(sampleRate: 24000, channels: 1, encoding: .float32),
        sequence: sequence, timestamp: 0)
}
private actor PlaybackSynthesisFixture: SpeechSynthesisCapability {
    nonisolated let availability: CapabilityAvailability = .available
    private(set) var texts: [String] = []
    func synthesize(_ request: SpeechSynthesisRequest) throws -> InferenceSession<SynthesisEvent> {
        texts.append(request.text)
        let pair = InferenceSession<SynthesisEvent>.make(
            context: request.context, limits: try StreamLimits(capacity: 3), estimatedBytes: { $0.estimatedBytes })
        try pair.emitter.yield(.audio(pcm()))
        try pair.emitter.yield(.audio(pcm(1)))
        try pair.emitter.yield(.finished)
        pair.emitter.finish()
        return pair.session
    }
}
private func admit(_ text: String, agent: SpeechSynthesisAgent, source: String = "assistant", session: UUID = UUID())
    async throws -> (UUID, SpeechAudioStore.Owner, ActionInvocation)
{
    let parent = AgentInput(sessionID: session, payload: .text(text))
    let request = try SpeechSynthesisInput(text: text)
    let payload = InputPayload.observation(.speechSynthesis(request))
    try await agent.receive(
        AgentInput(
            sessionID: session, payload: payload,
            metadata: InputMetadata(payload: payload, source: source, parentID: parent.id)))
    let call = ActionCall(
        actionPath: ActionPath(module: "Speech", function: "speak"), channel: "Speech",
        parameters: ["audioID": request.audioID.uuidString])
    return (
        request.audioID, .init(source: AgentID(rawValue: source), session: session, input: parent.id),
        ActionInvocation(
            envelope: OutputEnvelope(
                source: AgentID(rawValue: source), input: parent, output: .actionCall(call), sequence: 1), call: call)
    )
}
@Test(.timeLimit(.minutes(1))) func synthesisFIFOIsIndependentOfPlaybackAndSupportsMultipleAgents() async throws {
    let store = SpeechAudioStore()
    let model = PlaybackSynthesisFixture()
    let agent = try SpeechSynthesisAgent(synthesis: model, store: store)
    try await agent.start()
    let one = try await admit("one", agent: agent)
    let two = try await admit("two", agent: agent, source: "narrator")
    let three = try await admit("three", agent: agent)
    let playback = SpeechPlayback(store: store)
    for job in [three, one, two] {
        try await playback.play(job.2) { audio, _ in
            var frames: [UInt64] = []
            while let frame = try await audio.next() { frames.append(frame.sequence) }
            #expect(frames == [0, 1])
        }
    }
    #expect(await model.texts == ["one", "two", "three"])
    await agent.stop()
    await store.shutdown()
}
@Test func cacheOverflowFailsExplicitlyAndDoesNotBlockFollowingSynthesis() async throws {
    let store = SpeechAudioStore(audioBytes: 16)
    let model = PlaybackSynthesisFixture()
    let agent = try SpeechSynthesisAgent(synthesis: model, store: store)
    try await agent.start()
    let one = try await admit("one", agent: agent)
    let two = try await admit("two", agent: agent)
    for _ in 0..<100 where await agent.status().processedInputs < 2 { try await Task.sleep(for: .milliseconds(2)) }
    for job in [one, two] {
        await #expect(throws: SpeechAudioError.capacityExceeded) { try await store.validate(job.0, owner: job.1) }
    }
    #expect(await model.texts == ["one", "two"])
    await agent.stop()
    await store.shutdown()
}
@Test func cacheExpirationLeaseOwnershipAndCapacity() async throws {
    let store = SpeechAudioStore(capacity: 1, queueTTL: .milliseconds(20), readyTTL: .milliseconds(20))
    let owner = SpeechAudioStore.Owner(source: .assistant, session: UUID(), input: UUID())
    let queued = UUID()
    try await store.register(queued, owner: owner, cancel: {})
    await #expect(throws: SpeechAudioError.capacityExceeded) {
        try await store.register(UUID(), owner: owner, cancel: {})
    }
    try await Task.sleep(for: .milliseconds(40))
    await #expect(throws: SpeechAudioError.expired) { try await store.validate(queued, owner: owner) }
    let id = UUID()
    try await store.register(id, owner: owner, cancel: {})
    let audio = try await store.begin(id)
    try await audio.append(pcm())
    await store.complete(id)
    await #expect(throws: SpeechAudioError.forbidden) {
        _ = try await store.checkout(
            id, owner: .init(source: AgentID(rawValue: "other"), session: owner.session, input: owner.input))
    }
    _ = try await store.checkout(id, owner: owner)
    try await Task.sleep(for: .milliseconds(40))
    #expect(try await audio.next()?.sequence == 0)
    #expect(try await audio.next() == nil)
    try await store.release(id, owner: owner)
    await #expect(throws: SpeechAudioError.missingAudio) { _ = try await store.checkout(id, owner: owner) }
    let ready = UUID()
    try await store.register(ready, owner: owner, cancel: {})
    _ = try await store.begin(ready)
    await store.complete(ready)
    try await Task.sleep(for: .milliseconds(40))
    await #expect(throws: SpeechAudioError.expired) { try await store.validate(ready, owner: owner) }
    await store.shutdown()
}
private struct NeverCompletingSpeech: SpeechSynthesisCapability {
    let availability: CapabilityAvailability = .available
    func synthesize(_ request: SpeechSynthesisRequest) async throws -> InferenceSession<SynthesisEvent> {
        try await Task.sleep(for: .seconds(60))
        throw SpeechAudioError.closed
    }
}
@Test(.timeLimit(.minutes(1))) func playbackTimeoutCancelsSynthesisAndMidstreamStarvationFails() async throws {
    let store = SpeechAudioStore(waitTimeout: .milliseconds(20))
    let agent = try SpeechSynthesisAgent(synthesis: NeverCompletingSpeech(), store: store)
    try await agent.start()
    let job = try await admit("wait", agent: agent)
    let playback = SpeechPlayback(store: store)
    await #expect(throws: SpeechAudioError.timedOut) {
        try await playback.play(job.2) { audio, _ in _ = try await audio.next() }
    }
    await agent.stop()
    await store.shutdown()
    let audio = SpeechAudio(waitTimeout: .milliseconds(20))
    try await audio.append(pcm())
    _ = try await audio.next()
    await #expect(throws: SpeechAudioError.timedOut) { _ = try await audio.next() }
}
@Test func cancellationIsScopedToOriginatingAgent() async throws {
    let store = SpeechAudioStore()
    let session = UUID()
    let input = UUID()
    let one = SpeechAudioStore.Owner(source: .assistant, session: session, input: input)
    let two = SpeechAudioStore.Owner(source: AgentID(rawValue: "other"), session: session, input: input)
    let a = UUID()
    let b = UUID()
    try await store.register(a, owner: one, cancel: {})
    try await store.register(b, owner: two, cancel: {})
    await store.cancel(inputID: input, source: .assistant)
    await #expect(throws: CancellationError.self) { try await store.validate(a, owner: one) }
    try await store.validate(b, owner: two)
    await store.shutdown()
}

private actor SynthesisClient: Agent {
    nonisolated let descriptor: AgentDescriptor
    nonisolated let outputs = AsyncStream<OutputEnvelope> { $0.finish() }
    init(_ config: AgentConfiguration) {
        descriptor = AgentDescriptor(
            id: config.agentID, name: "Test sender", inputs: [], outputs: [], capabilities: config.capabilities)
    }
    func start() {}
    func pause() {}
    func resume() {}
    func stop() {}
    func status() -> AgentStatus { AgentStatus(lifecycle: .running, queuedInputs: 0, processedInputs: 0) }
    func receive(_ input: AgentInput) throws { throw HarnessError.unsupportedInput }
}
private func synthesisClientConfiguration(_ name: String, permitted: Bool) throws -> AgentConfiguration {
    try AgentConfiguration(
        data: JSONSerialization.data(withJSONObject: [
            "version": 5, "id": name, "actions": [String: [String]](), "tools": [],
            "communication": [
                "inputs": [], "subscriptions": [], "publications": [],
                "sends": permitted ? [["contract": "speech.synthesize", "target": "speechSynthesis"]] : [],
            ],
        ]))
}
@Test func directedSynthesisPermissionsSupportIndependentSenders() async throws {
    let configs = try [
        synthesisClientConfiguration("alpha", permitted: true), synthesisClientConfiguration("beta", permitted: true),
        synthesisClientConfiguration("denied", permitted: false), AgentConfigurations.load(named: "SpeechSynthesis"),
    ]
    let policy = try CommunicationPolicy(configurations: configs)
    let manager = AgentManager()
    let store = SpeechAudioStore()
    let model = PlaybackSynthesisFixture()
    let synthesizer = try SpeechSynthesisAgent(synthesis: model, store: store)
    try await manager.register(synthesizer)
    try await synthesizer.start()
    let gateway = OutputGateway(
        manager: manager, requests: InputGateway(manager: manager, policy: policy), tools: ToolRegistry(),
        policy: policy, sink: { _ in })
    for config in configs.prefix(3) {
        let client = SynthesisClient(config)
        try await manager.register(client)
        try await manager.start(config.agentID)
        let port = try await gateway.messaging(for: config.agentID)
        // A segment generated after the originating input's admission TTL is still fresh work.
        let payload = InputPayload.text("test")
        let parent = AgentInput(
            sessionID: UUID(), payload: payload,
            metadata: InputMetadata(payload: payload, deadline: .now.advanced(by: .seconds(-1))))
        let request = try SpeechSynthesisInput(text: config.agentID.rawValue)
        if config.agentID.rawValue == "denied" {
            await #expect(throws: CommunicationError.unauthorized) {
                _ = try await port.send(.speechSynthesis(request), parent: parent, to: synthesizer.descriptor.id)
            }
        } else {
            let report = try await port.send(.speechSynthesis(request), parent: parent, to: synthesizer.descriptor.id)
            #expect(report.delivered == [synthesizer.descriptor.id])
            let owner = SpeechAudioStore.Owner(source: config.agentID, session: parent.sessionID, input: parent.id)
            let audio = try await store.checkout(request.audioID, owner: owner)
            var count = 0
            while try await audio.next() != nil { count += 1 }
            #expect(count == 2)
            try await store.release(request.audioID, owner: owner)
        }
    }
    #expect(await model.texts == ["alpha", "beta"])
    await manager.stopAll()
    await store.shutdown()
}
private struct UnusedPlaybackChat: ChatCapability {
    let availability: CapabilityAvailability = .available
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> { throw SpeechAudioError.closed }
}
@Test func rejectedPlaybackAdmissionLetsCallerReleaseSynthesizedHandle() async throws {
    let store = SpeechAudioStore()
    let synth = try SpeechSynthesisAgent(synthesis: PlaybackSynthesisFixture(), store: store)
    try await synth.start()
    let job = try await admit("rejected", agent: synth)
    let manager = AgentManager()
    try await manager.register(AssistantAgent(chat: UnusedPlaybackChat()))
    let gateway = OutputGateway(
        manager: manager, requests: InputGateway(manager: manager), tools: ToolRegistry(),
        sink: { _ in })
    await #expect(throws: ActionExecutionError.missingHandler(job.2.call.actionPath)) {
        try await gateway.dispatch(job.2.envelope)
    }
    // Gateway reports admission failure; the owning output consumer releases its input resources.
    try await store.validate(job.0, owner: job.1)
    await store.cancel(inputID: job.2.envelope.inputID, source: job.2.envelope.source)
    await #expect(throws: CancellationError.self) { try await store.validate(job.0, owner: job.1) }
    await synth.stop()
    await gateway.shutdown()
    await manager.stopAll()
}
@Test(.timeLimit(.minutes(1))) func synthesisExecutionDeadlineIsIndependentOfPlaybackDeadline() async throws {
    let store = SpeechAudioStore()
    let agent = try SpeechSynthesisAgent(
        synthesis: NeverCompletingSpeech(), store: store, executionTimeout: .milliseconds(20))
    try await agent.start()
    let job = try await admit("wait", agent: agent)
    let audio = try await store.checkout(job.0, owner: job.1)
    await #expect(throws: SpeechAudioError.synthesisTimedOut) { _ = try await audio.next() }
    await agent.stop()
    await store.shutdown()
}

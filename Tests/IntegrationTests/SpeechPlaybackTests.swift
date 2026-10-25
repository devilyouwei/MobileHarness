import Actions
import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import ModelKit
import PlatformKit
import StorageCache
import StorageCore
import Synchronization
import Testing

@testable import Agents

private func pcm(_ sequence: UInt64 = 0) throws -> ModelKit.AudioFrame {
    try ModelKit.AudioFrame(
        data: Data(repeating: 0, count: 16),
        format: ModelKit.AudioFormat(sampleRate: 24000, channels: 1, encoding: .float32),
        sequence: sequence, timestamp: 0)
}
private func storedPCM() throws -> StorageCache.AudioFrame {
    let frame = try pcm()
    return try StorageCache.AudioFrame(
        data: frame.data,
        format: StorageCache.AudioFormat(
            sampleRate: frame.format.sampleRate, channels: frame.format.channels, encoding: .float32),
        sequence: frame.sequence, timestamp: frame.timestamp)
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
private func admit(
    _ text: String, agent: SpeechSynthesisAgent, source: String = "assistant",
    session: String = UUID().uuidString
)
    async throws -> (String, AudioCache.Owner, any FunctionInput)
{
    let parent = AgentInput(id: UUID().uuidString, sessionID: session, payload: .text(text))
    let request = try SpeechSynthesisInput(text: text)
    let payload = InputPayload.observation(.speechSynthesis(request))
    try await agent.receive(
        AgentInput(
            id: UUID().uuidString,
            sessionID: session, payload: payload,
            metadata: InputMetadata(
                payload: payload, source: source, rootID: UUID().uuidString, parentID: parent.id)))
    let call = ActionCall(
        actionPath: ActionPath(domain: "Speech", module: "Playback", function: "speak"), channel: "Speech",
        parameters: ["audioID": request.audioID])
    return (
        request.audioID, .init(source: source, session: session, input: parent.id),
        ActionInvocation(source: AgentID(rawValue: source), input: parent, call: call, sequence: 1)
    )
}
@Test(.actionCatalog, .timeLimit(.minutes(1))) func synthesisFIFOIsIndependentOfPlaybackAndSupportsMultipleAgents()
    async throws
{
    let store = AudioCache()
    let model = PlaybackSynthesisFixture()
    let agent = try SpeechSynthesisAgent(
        synthesis: model, store: store,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "speechSynthesis"), scope: UUID().uuidString, state: SpeechSynthesisContextState())
    )
    try await agent.start()
    let one = try await admit("one", agent: agent)
    let two = try await admit("two", agent: agent, source: "narrator")
    let three = try await admit("three", agent: agent)
    let playback = SpeechPlayback(store: store)
    for job in [three, one, two] {
        try await playback.play(job.2) { audio, _ in
            var frames: [UInt64] = []
            while let frame = try await audio.next() {
                frames.append(frame.sequence)
                #expect(
                    frame.format.sampleRate == 24000 && frame.format.channels == 1 && frame.format.encoding == .float32)
                #expect(frame.data == Data(repeating: 0, count: 16) && frame.timestamp == 0)
            }
            #expect(frames == [0, 1])
        }
    }
    #expect(await model.texts == ["one", "two", "three"])
    await agent.stop()
    await store.shutdown()
}
@Test(.actionCatalog) func cacheOverflowFailsExplicitlyAndDoesNotBlockFollowingSynthesis() async throws {
    let store = AudioCache(audioBytes: 16)
    let model = PlaybackSynthesisFixture()
    let agent = try SpeechSynthesisAgent(
        synthesis: model, store: store,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "speechSynthesis"), scope: UUID().uuidString, state: SpeechSynthesisContextState())
    )
    try await agent.start()
    let one = try await admit("one", agent: agent)
    let two = try await admit("two", agent: agent)
    for _ in 0..<100 where await agent.status().processedInputs < 2 { try await Task.sleep(for: .milliseconds(2)) }
    for job in [one, two] {
        await #expect(throws: AudioCacheError.capacityExceeded) { try await store.validate(job.0, owner: job.1) }
    }
    #expect(await model.texts == ["one", "two"])
    await agent.stop()
    await store.shutdown()
}
@Test(.actionCatalog) func cacheOwnershipCapacityAndExplicitRelease() async throws {
    let store = AudioCache(capacity: 1)
    let owner = AudioCache.Owner(
        source: "assistant", session: UUID().uuidString, input: UUID().uuidString)
    let id = UUID().uuidString
    try await store.register(id, owner: owner, cancel: {})
    await #expect(throws: AudioCacheError.capacityExceeded) {
        try await store.register(UUID().uuidString, owner: owner, cancel: {})
    }
    let audio = try await store.begin(id)
    try await audio.append(storedPCM())
    await store.complete(id)
    await #expect(throws: AudioCacheError.forbidden) {
        _ = try await store.checkout(
            id, owner: .init(source: "other", session: owner.session, input: owner.input))
    }
    _ = try await store.checkout(id, owner: owner)
    #expect(try await audio.next()?.sequence == 0)
    #expect(try await audio.next() == nil)
    try await store.release(id, owner: owner)
    await #expect(throws: AudioCacheError.missingAudio) { _ = try await store.checkout(id, owner: owner) }
    // Releasing one played segment immediately restores capacity for the next segment.
    let next = UUID().uuidString
    try await store.register(next, owner: owner, cancel: {})
    await store.cancel(inputID: owner.input, source: owner.source)
    await #expect(throws: AudioCacheError.missingAudio) { try await store.validate(next, owner: owner) }
    await store.shutdown()
}

@Test(.actionCatalog, .timeLimit(.minutes(2))) func queuedAndCompletedSpeechSurviveOldSixtySecondExpiry() async throws {
    let store = AudioCache()
    let owner = AudioCache.Owner(
        source: "assistant", session: UUID().uuidString, input: UUID().uuidString)
    let queued = UUID().uuidString
    let ready = UUID().uuidString
    try await store.register(queued, owner: owner, cancel: {})
    try await store.register(ready, owner: owner, cancel: {})
    let audio = try await store.begin(ready)
    try await audio.append(storedPCM())
    await store.complete(ready)
    // Exercise production defaults beyond the removed TTL, without an injected shorter policy.
    try await Task.sleep(for: .seconds(61))
    try await store.validate(queued, owner: owner)
    try await store.validate(ready, owner: owner)
    let retained = try await store.checkout(ready, owner: owner)
    #expect(try await retained.next()?.sequence == 0)
    #expect(try await retained.next() == nil)
    try await store.release(ready, owner: owner)
    await store.cancel(inputID: owner.input, source: owner.source)
    await #expect(throws: AudioCacheError.missingAudio) { try await store.validate(queued, owner: owner) }
    await store.shutdown()
}

@Test(.actionCatalog) func replyCleanupPreservesOtherRepliesAndSessionInterruptionClearsRemainder() async throws {
    let store = AudioCache()
    let session = UUID().uuidString
    let owners = [
        AudioCache.Owner(source: "assistant", session: session, input: UUID().uuidString),
        AudioCache.Owner(source: "assistant", session: session, input: UUID().uuidString),
        AudioCache.Owner(
            source: "assistant", session: UUID().uuidString, input: UUID().uuidString),
    ]
    let ids = [UUID().uuidString, UUID().uuidString, UUID().uuidString]
    for (id, owner) in zip(ids, owners) {
        try await store.register(id, owner: owner, cancel: {})
        let audio = try await store.begin(id)
        try await audio.append(storedPCM())
        await store.complete(id)
    }
    await store.cancel(inputID: owners[0].input, source: owners[0].source)
    await #expect(throws: AudioCacheError.missingAudio) { try await store.validate(ids[0], owner: owners[0]) }
    try await store.validate(ids[1], owner: owners[1])
    try await store.validate(ids[2], owner: owners[2])
    await store.cancel(sessionID: session)
    await #expect(throws: AudioCacheError.missingAudio) { try await store.validate(ids[1], owner: owners[1]) }
    try await store.validate(ids[2], owner: owners[2])
    await store.shutdown()
    await #expect(throws: (any Error).self) { try await store.validate(ids[2], owner: owners[2]) }
}

private struct NeverCompletingSpeech: SpeechSynthesisCapability {
    let availability: CapabilityAvailability = .available
    func synthesize(_ request: SpeechSynthesisRequest) async throws -> InferenceSession<SynthesisEvent> {
        try await Task.sleep(for: .seconds(60))
        throw AudioCacheError.closed
    }
}
@Test(.actionCatalog, .timeLimit(.minutes(1))) func audioReadWaitsUntilExplicitCancellation() async throws {
    let audio = AudioStream(id: UUID().uuidString)
    let read = Task { try await audio.next() }
    try await Task.sleep(for: .milliseconds(40))
    read.cancel()
    await #expect(throws: CancellationError.self) { _ = try await read.value }
}
@Test(.actionCatalog) func cancellationIsScopedToOriginatingAgent() async throws {
    let store = AudioCache()
    let session = UUID().uuidString
    let input = UUID().uuidString
    let one = AudioCache.Owner(source: "assistant", session: session, input: input)
    let two = AudioCache.Owner(source: "other", session: session, input: input)
    let a = UUID().uuidString
    let b = UUID().uuidString
    try await store.register(a, owner: one, cancel: {})
    try await store.register(b, owner: two, cancel: {})
    await store.cancel(inputID: input, source: "assistant")
    await #expect(throws: AudioCacheError.missingAudio) { try await store.validate(a, owner: one) }
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
        contracts: AgentContracts.communication,
        data: JSONSerialization.data(withJSONObject: [
            "version": 6, "id": name, "actions": [String: [String]](), "tools": [],
            "communication": [
                "inputs": [], "subscriptions": [], "publications": [],
                "sends": permitted ? [["contract": "speech.synthesize", "target": "speechSynthesis"]] : [],
            ],
        ]))
}
@Test(.actionCatalog) func directedSynthesisPermissionsSupportIndependentSenders() async throws {
    let configs = try [
        synthesisClientConfiguration("alpha", permitted: true), synthesisClientConfiguration("beta", permitted: true),
        synthesisClientConfiguration("denied", permitted: false), AgentConfigurations.load(named: "SpeechSynthesis"),
    ]
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, configurations: configs)
    let manager = AgentManager()
    let store = AudioCache()
    let model = PlaybackSynthesisFixture()
    let synthesizer = try SpeechSynthesisAgent(
        synthesis: model, store: store,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "speechSynthesis"), scope: UUID().uuidString, state: SpeechSynthesisContextState())
    )
    try await manager.register(synthesizer)
    try await synthesizer.start()
    let gateway = await OutputGateway(
        manager: manager, requests: InputGateway(manager: manager, policy: policy),
        tools: ToolRegistry(),
        policy: policy, sink: { _ in })
    for config in configs.prefix(3) {
        let client = SynthesisClient(config)
        try await manager.register(client)
        try await manager.start(config.agentID)
        let port = try await gateway.messaging(for: config.agentID)
        // A segment generated after the originating input's admission TTL is still fresh work.
        let payload = InputPayload.text("test")
        let parent = AgentInput(
            id: UUID().uuidString,
            sessionID: UUID().uuidString, payload: payload,
            metadata: InputMetadata(
                payload: payload, rootID: UUID().uuidString, deadline: .now.advanced(by: .seconds(-1))))
        let request = try SpeechSynthesisInput(text: config.agentID.rawValue)
        if config.agentID.rawValue == "denied" {
            await #expect(throws: CommunicationError.unauthorized) {
                _ = try await port.send(.speechSynthesis(request), parent: parent, to: synthesizer.descriptor.id)
            }
        } else {
            let report = try await port.send(.speechSynthesis(request), parent: parent, to: synthesizer.descriptor.id)
            #expect(report.delivered == [synthesizer.descriptor.id])
            let owner = AudioCache.Owner(
                source: config.agentID.rawValue, session: parent.sessionID, input: parent.id)
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
    func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> { throw AudioCacheError.closed }
}

private actor ReplyCompletionGate {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func open() {
        opened = true
        waiter?.resume()
        waiter = nil
    }
}

private enum ReplyInterruptionFailure: Error, Equatable { case unavailable }

@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: ["completed", "failed", "cancelled"])
@MainActor func voiceReplyCancellationJoinsPlaybackBeforeRetiringSessionAudio(outcome: String) async throws {
    let failures = Mutex<[any Error]>([])
    let cache = CacheContainer(
        failures: StorageFailureReporter { component, operation, error in
            failures.withLock { $0.append(error) }
        })
    let session = UUID().uuidString
    let store = try await cache.audioScope(session)
    let input = AgentInput(id: UUID().uuidString, sessionID: session, payload: .text("speak"))
    let owner = AudioCache.Owner(source: "assistant", session: session, input: input.id)
    let id = UUID().uuidString
    let queued = UUID().uuidString
    try await store.register(id, owner: owner, cancel: {})
    try await store.register(queued, owner: owner, cancel: {})
    let audio = try await store.begin(id)
    try await audio.append(storedPCM())
    await store.complete(id)
    let invocation = ActionInvocation(
        source: .assistant, input: input,
        call: ActionCall(
            actionPath: .init(domain: "Speech", module: "Playback", function: "speak"), channel: "Speech",
            parameters: ["audioID": id]), sequence: 1)
    let playbackEntered = ReplyCompletionGate()
    let playbackCancelled = ReplyCompletionGate()
    let releasePlayback = ReplyCompletionGate()
    let nativeStopEntered = ReplyCompletionGate()
    let releaseNativeStop = ReplyCompletionGate()
    let player = SpeechPlayback(store: store)
    let playback = Task {
        try await player.play(audioID: id, invocation: invocation) { stream, _ in
            #expect(try await stream.next() != nil)
            await playbackEntered.open()
            do { try await Task.sleep(for: .seconds(60)) } catch {
                // Model a player that still owns its PCM while joining cancellation cleanup.
                await playbackCancelled.open()
                await releasePlayback.wait()
                throw error
            }
        }
    }
    await playbackEntered.wait()
    let interruption = Task {
        try await VoiceReplyCancellation.run(
            cancelReply: {
                playback.cancel()
                await #expect(throws: CancellationError.self) { try await playback.value }
                if outcome == "failed" { throw ReplyInterruptionFailure.unavailable }
                if outcome == "cancelled" { throw CancellationError() }
            },
            waitForPlaybackStop: {
                await nativeStopEntered.open()
                await releaseNativeStop.wait()
            },
            cleanupAudio: { await store.cancel(sessionID: session) })
    }
    await playbackCancelled.wait()
    // Session cleanup cannot retire unplayed audio while a playback task is still exiting.
    try await store.validate(queued, owner: owner)
    await releasePlayback.open()
    await nativeStopEntered.wait()
    // Joining the Swift action alone is insufficient: the native graph must also have stopped.
    try await store.validate(queued, owner: owner)
    await releaseNativeStop.open()
    if outcome == "failed" {
        await #expect(throws: ReplyInterruptionFailure.unavailable) { try await interruption.value }
    } else if outcome == "cancelled" {
        await #expect(throws: CancellationError.self) { try await interruption.value }
    } else {
        try await interruption.value
    }
    #expect(
        failures.withLock {
            $0.allSatisfy { ($0 as? StorageFailure)?.isCancellation == true || $0 is CancellationError }
        })
    await #expect(throws: AudioCacheError.missingAudio) { try await store.validate(queued, owner: owner) }
    await cache.close()
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) func replyFinishJoinsActionsBeforeCleaningRemainingAudio() async throws {
    let store = AudioCache()
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("perform then speak"))
    let owner = AudioCache.Owner(source: "assistant", session: input.sessionID, input: input.id)
    let id = UUID().uuidString
    try await store.register(id, owner: owner, cancel: {})
    let audio = try await store.begin(id)
    try await audio.append(storedPCM())
    await store.complete(id)
    let started = ReplyCompletionGate()
    let release = ReplyCompletionGate()
    let path = ActionPath(domain: "UI", module: "Expression", function: "express")
    let scheduler = ChannelScheduler(
        registry: try testActionRegistry(handlers: [
            path: { _ in
                await started.open()
                await release.wait()
                try await store.validate(id, owner: owner)
            }
        ]))
    let manager = AgentManager()
    try await manager.register(
        FixtureNativeAgent(
            chat: UnusedPlaybackChat(),
            context: try AgentContextRepository(
                agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState())
        ))
    try await manager.start(.assistant)
    let gateway = await OutputGateway(
        manager: manager, requests: InputGateway(manager: manager), tools: ToolRegistry(),
        actions: scheduler, sink: { _ in })
    try await gateway.dispatch(
        OutputEnvelope(
            source: .assistant, context: input.context,
            output: .actionCall(ActionCall(actionPath: path, channel: "Display", parameters: ["emotion": "smile"])),
            taskScope: input.taskScope))
    await started.wait()
    let finishing = Task {
        try await gateway.dispatch(
            OutputEnvelope(
                source: .assistant, context: input.context, output: .control("agent.finished"),
                taskScope: input.taskScope))
        await store.cancel(inputID: input.id, source: "assistant")
    }
    try await store.validate(id, owner: owner)
    await release.open()
    try await finishing.value
    await #expect(throws: AudioCacheError.missingAudio) { try await store.validate(id, owner: owner) }
    await gateway.shutdown()
    await manager.stopAll()
    await store.shutdown()
}
@Test(.actionCatalog) func rejectedPlaybackAdmissionLetsCallerReleaseSynthesizedHandle() async throws {
    let store = AudioCache()
    let synth = try SpeechSynthesisAgent(
        synthesis: PlaybackSynthesisFixture(), store: store,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "speechSynthesis"), scope: UUID().uuidString, state: SpeechSynthesisContextState())
    )
    try await synth.start()
    let job = try await admit("rejected", agent: synth)
    let manager = AgentManager()
    try await manager.register(
        FixtureNativeAgent(
            chat: UnusedPlaybackChat(),
            context: try AgentContextRepository(
                agent: FixtureNativeChatState.agentID, scope: UUID().uuidString, state: FixtureNativeChatState())
        ))
    let gateway = await OutputGateway(
        manager: manager, requests: InputGateway(manager: manager), tools: ToolRegistry(),
        sink: { _ in })
    await #expect(throws: ActionExecutionError.missingHandler(job.2.call.actionPath)) {
        try await gateway.dispatch(job.2.testEnvelope)
    }
    // Gateway reports admission failure; the owning output consumer releases its input resources.
    try await store.validate(job.0, owner: job.1)
    await store.cancel(inputID: job.2.testEnvelope.inputID, source: job.2.testEnvelope.source.rawValue)
    await #expect(throws: AudioCacheError.missingAudio) { try await store.validate(job.0, owner: job.1) }
    await synth.stop()
    await gateway.shutdown()
    await manager.stopAll()
}
@Test(.actionCatalog, .timeLimit(.minutes(1))) func synthesisWaitsUntilOwnerStops() async throws {
    let store = AudioCache()
    let agent = try SpeechSynthesisAgent(
        synthesis: NeverCompletingSpeech(), store: store,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "speechSynthesis"), scope: UUID().uuidString, state: SpeechSynthesisContextState())
    )
    try await agent.start()
    let job = try await admit("wait", agent: agent)
    let audio = try await store.checkout(job.0, owner: job.1)
    let read = Task { try await audio.next() }
    try await Task.sleep(for: .milliseconds(40))
    await agent.stop()
    await #expect(throws: CancellationError.self) { _ = try await read.value }
    await store.shutdown()
}

private struct SlowPlaybackSynthesis: SpeechSynthesisCapability {
    let availability: CapabilityAvailability = .available
    let delayBeforeFirstFrame: Bool

    func synthesize(_ request: SpeechSynthesisRequest) async throws -> InferenceSession<SynthesisEvent> {
        let pair = InferenceSession<SynthesisEvent>.make(
            context: request.context, limits: try StreamLimits(capacity: 3), estimatedBytes: { $0.estimatedBytes })
        Task {
            do {
                if delayBeforeFirstFrame { try await Task.sleep(for: .milliseconds(3200)) }
                try pair.emitter.yield(.audio(pcm(0)))
                if !delayBeforeFirstFrame { try await Task.sleep(for: .milliseconds(3200)) }
                try pair.emitter.yield(.audio(pcm(1)))
                try pair.emitter.yield(.finished)
                pair.emitter.finish()
            } catch { pair.emitter.fail(error) }
        }
        return pair.session
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: [true, false])
func slowSynthesisDoesNotTruncatePlayback(delayBeforeFirstFrame: Bool) async throws {
    let store = AudioCache()
    let agent = try SpeechSynthesisAgent(
        synthesis: SlowPlaybackSynthesis(delayBeforeFirstFrame: delayBeforeFirstFrame), store: store,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "speechSynthesis"), scope: UUID().uuidString, state: SpeechSynthesisContextState())
    )
    try await agent.start()
    let job = try await admit("complete speech", agent: agent)
    let playback = SpeechPlayback(store: store)
    try await playback.play(job.2) { audio, _ in
        var frames: [UInt64] = []
        while let frame = try await audio.next() { frames.append(frame.sequence) }
        #expect(frames == [0, 1])
    }
    await #expect(throws: AudioCacheError.missingAudio) { try await store.validate(job.0, owner: job.1) }
    await agent.stop()
    await store.shutdown()
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) func playbackWithoutReadDeadlineStillCancels() async throws {
    let audio = AudioStream(id: UUID().uuidString)
    let reading = Task { try await audio.next() }
    reading.cancel()
    await #expect(throws: CancellationError.self) { _ = try await reading.value }
    await audio.cancel()
}

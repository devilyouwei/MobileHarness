import Actions
import AgentCore
import Agents
import Foundation
import Gateway
import ModelKit
import PlatformKit
import StorageAudio
import Synchronization
import Testing
import Tools

private struct RecognitionFixture: SpeechRecognitionCapability {
    let text: String
    let includeFinal: Bool
    var availability: CapabilityAvailability { .available }
    func transcribe(_ request: SpeechRecognitionRequest) async throws -> SpeechRecognitionSession {
        let pair = InferenceSession<TranscriptionEvent>.make(
            context: request.context,
            limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        let segment = UUID()
        return SpeechRecognitionSession(
            output: pair.session, format: request.format, sendAudio: { _ in },
            finishInput: {
                try pair.emitter.yield(
                    TranscriptionEvent(segmentID: segment, revision: 0, text: "partial", isFinal: false))
                if includeFinal {
                    try pair.emitter.yield(
                        TranscriptionEvent(segmentID: segment, revision: 1, text: text, isFinal: true))
                    try pair.emitter.yield(
                        TranscriptionEvent(segmentID: segment, revision: 2, text: "duplicate", isFinal: true))
                }
                pair.emitter.finish()
            })
    }
}

private actor VoiceProbe {
    var spokenText: [String] = []
    var displayedText: [String] = []
    var audio: [AudioFrame] = []
    func synthesized(_ text: String) { spokenText.append(text) }
    func displayed(_ text: String) { displayedText.append(text) }
    func played(_ frame: AudioFrame) { audio.append(frame) }
}

private struct SynthesisFixture: SpeechSynthesisCapability {
    let probe: VoiceProbe
    var producesAudio = true
    var availability: CapabilityAvailability { .available }
    func synthesize(_ request: SpeechSynthesisRequest) async throws -> InferenceSession<SynthesisEvent> {
        #expect(request.locale == "auto")
        await probe.synthesized(request.text)
        let pair = InferenceSession<SynthesisEvent>.make(
            context: request.context,
            limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        if producesAudio { try pair.emitter.yield(.audio(try sampleFrame())) }
        try pair.emitter.yield(.finished)
        pair.emitter.finish()
        return pair.session
    }
}

private func sampleFrame() throws -> AudioFrame {
    try AudioFrame(
        data: Data(repeating: 0, count: 320),
        format: AudioFormat(sampleRate: 16_000, channels: 1, encoding: .float32), sequence: 0, timestamp: 0)
}

private func preparedSpeech(
    text: String, input: AgentInput, probe: VoiceProbe, producesAudio: Bool = true
) async throws -> (SpeechSynthesisAgent, SpeechAudioStore, SpeechPlayback, ActionInvocation) {
    let store = SpeechAudioStore()
    let agent = try SpeechSynthesisAgent(
        synthesis: SynthesisFixture(probe: probe, producesAudio: producesAudio), store: store)
    try await agent.start()
    let request = try SpeechSynthesisInput(text: text)
    let payload = InputPayload.observation(.speechSynthesis(request))
    try await agent.receive(
        AgentInput(
            sessionID: input.sessionID, payload: payload,
            metadata: InputMetadata(payload: payload, source: "assistant", parentID: input.id)))
    let call = ActionCall(
        actionPath: ActionPath(module: "Speech", function: "speak"), channel: "Speech",
        parameters: ["audioID": request.audioID.uuidString])
    return (
        agent, store, SpeechPlayback(store: store),
        ActionInvocation(source: .assistant, input: input, call: call)
    )
}

@Test func voiceGatewaysRoundTripThroughSayAndPrint() async throws {
    let manager = AgentManager()
    let agent = try AssistantAgent(chat: FixedTextChat(text: "固定回复"))
    try await manager.register(agent)

    let probe = VoiceProbe()
    let store = SpeechAudioStore()
    let synth = try SpeechSynthesisAgent(synthesis: SynthesisFixture(probe: probe), store: store)
    try await manager.register(synth)
    try await synth.start()
    let policy = try CommunicationPolicy(
        configurations: ["Assistant", "SpeechPerception", "SpeechSynthesis"].map {
            try AgentConfigurations.load(named: $0)
        })
    let gateway = InputGateway(manager: manager, policy: policy)
    let playback = SpeechPlayback(store: store)
    let scheduler = ChannelScheduler(
        registry: try testActionRegistry(handlers: [
            ActionPath(module: "Speech", function: "speak"): { invocation in
                try await playback.play(invocation) { audio, _ in
                    while let frame = try await audio.next() { await probe.played(frame) }
                }
            },
            ActionPath(module: "UI", function: "print"): { invocation in
                try await UIActions.print(invocation: invocation) { text, _ in await probe.displayed(text) }
            },
        ]))
    let response = OutputGateway(
        manager: manager, requests: gateway, tools: ToolRegistry(), actions: scheduler, policy: policy,
    ) { _ in }
    try await agent.bind(response.messaging(for: .assistant))
    try await agent.start()
    let recognition = RecognitionFixture(text: "你好", includeFinal: true)
    let sessionID = UUID()
    let turn = LiveSpeechInput(recognition: recognition, sessionID: sessionID) { _ in }
    try await turn.enqueue([.audio([sampleFrame()]), .end(.silence)])
    let text = try await turn.finish()
    await probe.displayed(text)
    let report = try await gateway.send(AgentInput(sessionID: sessionID, payload: .text(text)), to: .assistant)
    #expect(report.delivered == [.assistant])
    #expect(await agent.status().processedInputs == 1)
    var tokens: [String] = []
    for await envelope in agent.outputs {
        #expect(envelope.sessionID == sessionID)
        if case .actionCall(let token) = envelope.output { tokens.append(token.actionPath.function) }
        try await response.dispatch(envelope)
        if envelope.output == .control("assistant.finished") { break }
    }
    await agent.stop()
    #expect(tokens == ["speak", "print"])
    #expect(await probe.spokenText == ["固定回复"])
    #expect(await probe.displayedText == ["你好", "固定回复"])
    #expect(await probe.audio.count == 1)
    await response.shutdown()
    await synth.stop()
    await store.shutdown()
}

@Test func partialRecognitionNeverSubmitsAgentInput() async throws {
    let manager = AgentManager()
    let agent = try AssistantAgent(chat: FixedTextChat())
    try await manager.register(agent)
    try await agent.start()
    let recognition = RecognitionFixture(text: "", includeFinal: false)
    let turn = LiveSpeechInput(recognition: recognition, sessionID: UUID()) { _ in }
    try await turn.enqueue([.audio([sampleFrame()]), .end(.silence)])
    #expect(try await turn.finish().isEmpty)
    #expect(await agent.status().processedInputs == 0)
    await agent.stop()
}

@Test func speechFailureDoesNotInventSuccess() async throws {
    let probe = VoiceProbe()
    let input = AgentInput(sessionID: UUID(), payload: .text("你好"))
    let (synth, store, playback, invocation) = try await preparedSpeech(
        text: "回复", input: input, probe: probe, producesAudio: false)
    await #expect(throws: SpeechAudioError.invalidAudio) {
        try await playback.play(invocation) { audio, _ in
            while let frame = try await audio.next() { await probe.played(frame) }
        }
    }
    #expect(await probe.audio.isEmpty)
    await synth.stop()
    await store.shutdown()
}

@Test func cancellingDuringPlaybackDoesNotDeliverLaterAudio() async throws {
    let manager = AgentManager()
    try await manager.register(AssistantAgent(chat: FixedTextChat()))
    let probe = VoiceProbe()
    let input = AgentInput(sessionID: UUID(), payload: .text("你好"))
    let (synth, store, playback, invocation) = try await preparedSpeech(text: "回复", input: input, probe: probe)
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let actions = ChannelScheduler(
        registry: try testActionRegistry(handlers: [
            ActionPath(module: "Speech", function: "speak"): { invocation in
                try await playback.play(invocation) { audio, _ in
                    while let frame = try await audio.next() {
                        entered.continuation.yield(())
                        try await Task.sleep(for: .seconds(30))
                        await probe.played(frame)
                    }
                }
            }
        ]))
    let responses = OutputGateway(
        manager: manager, requests: InputGateway(manager: manager),
        tools: ToolRegistry(), actions: actions
    ) { _ in }
    try await responses.dispatch(invocation.envelope)
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    await store.cancel(sessionID: input.sessionID)
    await responses.cancel(sessionID: input.sessionID)
    #expect(await probe.audio.isEmpty)
    await responses.shutdown()
    await synth.stop()
    entered.continuation.finish()
}

@Test func longVoiceTurnRecognizesChunksButSubmitsOnlyOnce() async throws {
    let manager = AgentManager()
    let agent = try AssistantAgent(chat: FixedTextChat())
    try await manager.register(agent)
    try await agent.start()
    let gateway = InputGateway(manager: manager)
    let recognition = RecognitionFixture(text: "一段", includeFinal: true)
    let id = UUID()
    let turn = LiveSpeechInput(recognition: recognition, sessionID: id) { _ in }
    try await turn.enqueue([.audio([sampleFrame()]), .end(.maximumDuration)])
    try await turn.enqueue([.audio([sampleFrame()]), .end(.silence)])
    let text = try await turn.finish()
    #expect(text == "一段 一段")
    #expect(await agent.status().processedInputs == 0)
    _ = try await gateway.send(AgentInput(sessionID: id, payload: .text(text)), to: .assistant)
    #expect(await agent.status().processedInputs == 1)
    await #expect(throws: CapabilityError.self) {
        try await turn.enqueue([.audio([sampleFrame()]), .end(.silence)])
    }
    await agent.stop()
}

private actor BlockedRecognition: SpeechRecognitionCapability {
    var availability: CapabilityAvailability { .available }
    let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    func transcribe(_ request: SpeechRecognitionRequest) async throws -> SpeechRecognitionSession {
        let pair = InferenceSession<TranscriptionEvent>.make(
            context: request.context, limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        started.continuation.yield(())
        return SpeechRecognitionSession(
            output: pair.session, format: request.format, sendAudio: { _ in },
            finishInput: {
                try await Task.sleep(for: .seconds(60))
                pair.emitter.finish()
            })
    }
}

@Test func voiceQueueOverflowIsExplicitAndCancellationReleasesGateway() async throws {
    let model = BlockedRecognition()
    let recognition = model
    let turn = LiveSpeechInput(recognition: recognition, sessionID: UUID()) { _ in }
    try await turn.enqueue([.audio([sampleFrame()]), .end(.maximumDuration)])
    var started = model.started.stream.makeAsyncIterator()
    _ = await started.next()
    // A single oversized admission fails regardless of worker scheduling.
    await #expect(throws: CapabilityError.self) {
        try await turn.enqueue(Array(repeating: .end(.maximumDuration), count: 129))
    }
    await turn.cancel()
    await #expect(throws: CapabilityError.self) { try await turn.finish() }
    let next = LiveSpeechInput(recognition: recognition, sessionID: UUID()) { _ in }
    try await next.enqueue([.audio([sampleFrame()]), .end(.silence)])
    _ = await started.next()
    await next.cancel()
    await #expect(throws: CapabilityError.self) { try await next.finish() }
}

private struct LiveRecognitionFixture: SpeechRecognitionCapability {
    var availability: CapabilityAvailability { .available }
    func transcribe(_ request: SpeechRecognitionRequest) throws -> SpeechRecognitionSession {
        #expect(request.locale == "auto")
        let pair = InferenceSession<TranscriptionEvent>.make(
            context: request.context, limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        let id = UUID()
        return SpeechRecognitionSession(
            output: pair.session, format: request.format,
            sendAudio: { _ in
                try pair.emitter.yield(TranscriptionEvent(segmentID: id, revision: 2, text: "你好", isFinal: false))
                try pair.emitter.yield(TranscriptionEvent(segmentID: id, revision: 1, text: "旧结果", isFinal: false))
            },
            finishInput: {
                try pair.emitter.yield(TranscriptionEvent(segmentID: id, revision: 3, text: "你好世界", isFinal: true))
                pair.emitter.finish()
            })
    }
}

@Test func livePreviewArrivesBeforeEndpointAndDoesNotTriggerAgent() async throws {
    let manager = AgentManager()
    let agent = try AssistantAgent(chat: FixedTextChat())
    try await manager.register(agent)
    try await agent.start()
    let recognition = LiveRecognitionFixture()
    let previews = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(8))
    let turn = LiveSpeechInput(recognition: recognition, sessionID: UUID()) { previews.continuation.yield($0) }
    try await turn.enqueue([.audio([sampleFrame()])])
    var iterator = previews.stream.makeAsyncIterator()
    #expect(await iterator.next() == "你好")
    #expect(await agent.status().processedInputs == 0)
    try await turn.enqueue([.end(.silence)])
    let final = try await turn.finish()
    #expect(final == "你好世界")
    #expect(await iterator.next() == "你好世界")
    #expect(await agent.status().processedInputs == 0)
    await turn.cancel()
    previews.continuation.finish()
    await agent.stop()
}

@Test func cancellingLivePreviewClosesAdmissionAndAllowsNextSession() async throws {
    let recognition = LiveRecognitionFixture()
    let previews = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(8))
    let turn = LiveSpeechInput(recognition: recognition, sessionID: UUID()) { previews.continuation.yield($0) }
    try await turn.enqueue([.audio([sampleFrame()])])
    var iterator = previews.stream.makeAsyncIterator()
    _ = await iterator.next()
    await turn.cancel()
    await #expect(throws: CapabilityError.self) { try await turn.enqueue([.end(.silence)]) }
    let next = LiveSpeechInput(recognition: recognition, sessionID: UUID()) { _ in }
    try await next.enqueue([.audio([sampleFrame()]), .end(.silence)])
    #expect(try await next.finish() == "你好世界")
    previews.continuation.finish()
}

@Test(arguments: [nil, "", " \n\t", String(repeating: "界", count: 667)])
func textActionsRejectInvalidParametersBeforeSideEffects(_ text: String?) async throws {
    let probe = VoiceProbe()
    let input = AgentInput(sessionID: UUID(), payload: .text("request"))
    let call = ActionCall(
        actionPath: ActionPath(module: "UI", function: "print"), channel: "Display",
        parameters: text.map { ["text": $0] } ?? [:])
    let invocation = ActionInvocation(source: .assistant, input: input, call: call)
    await #expect(throws: UIActions.PresentationError.invalidText) {
        try await UIActions.print(invocation: invocation) { value, _ in await probe.displayed(value) }
    }
    #expect(throws: CommunicationError.invalidPayload) { _ = try SpeechSynthesisInput(text: text ?? "") }
    #expect(await probe.displayedText.isEmpty)
}

@Test func textActionsPreserveAcceptedTextAtByteLimit() async throws {
    let text = " " + String(repeating: "界", count: 666) + " "
    #expect(text.utf8.count == 2000)
    let probe = VoiceProbe()
    let input = AgentInput(sessionID: UUID(), payload: .text("request"))
    let (synth, store, playback, invocation) = try await preparedSpeech(text: text, input: input, probe: probe)
    try await playback.play(invocation) { audio, _ in
        while let frame = try await audio.next() { await probe.played(frame) }
    }
    let call = expectedActionCall(name: "print", parameters: ["text": text])
    let display = ActionInvocation(source: .assistant, input: input, call: call)
    try await UIActions.print(invocation: display) { value, _ in await probe.displayed(value) }
    #expect(await probe.spokenText == [text])
    #expect(await probe.displayedText == [text])
    #expect(await probe.audio.count == 1)
    await synth.stop()
    await store.shutdown()
}

@Test(arguments: [nil, "", "Happy", "unknown"])
func expressionsRejectInvalidEmotionBeforePresentation(_ emotion: String?) async throws {
    let probe = VoiceProbe()
    let input = AgentInput(sessionID: UUID(), payload: .text("request"))
    let call = ActionCall(
        actionPath: ActionPath(module: "UI", function: "express"), channel: "Display",
        parameters: emotion.map { ["emotion": $0] } ?? [:])
    let invocation = ActionInvocation(source: .assistant, input: input, call: call)
    await #expect(throws: UIActions.ExpressionError.invalidEmotion) {
        try await UIActions.express(invocation: invocation) { value, _ in await probe.displayed(value.rawValue) }
    }
    #expect(await probe.displayedText.isEmpty)
}

@Test func expressionPresentationPropagatesCancellation() async throws {
    let input = AgentInput(sessionID: UUID(), payload: .text("request"))
    let call = ActionCall(
        actionPath: ActionPath(module: "UI", function: "express"), channel: "Display", parameters: ["emotion": "happy"])
    let invocation = ActionInvocation(source: .assistant, input: input, call: call)
    await #expect(throws: CancellationError.self) {
        try await UIActions.express(invocation: invocation) { _, _ in throw CancellationError() }
    }
}

@Test(arguments: UIActions.Emotion.allCases)
func expressionPreservesSemanticIdentifier(_ emotion: UIActions.Emotion) async throws {
    let probe = VoiceProbe()
    let input = AgentInput(sessionID: UUID(), payload: .text("request"))
    let call = expectedActionCall(name: "express", parameters: ["emotion": emotion.rawValue])
    let invocation = ActionInvocation(source: .assistant, input: input, call: call)
    try await UIActions.express(invocation: invocation) { value, _ in await probe.displayed(value.rawValue) }
    #expect(await probe.displayedText == [emotion.rawValue])
    #expect(await probe.spokenText.isEmpty)
}

private struct EndpointVAD: VoiceActivityCapability {
    var availability: CapabilityAvailability { .available }
    func detectVoiceActivity(format: AudioFormat) -> any VoiceActivitySession { EndpointVADSession() }
}
private actor EndpointVADSession: VoiceActivitySession {
    private var position: Int64 = 0
    func process(_ frame: AudioFrame) throws -> [VoiceActivityScore] {
        defer { position += Int64(frame.sampleCount) }
        return [
            try VoiceActivityScore(
                startSample: position, sampleCount: frame.sampleCount, probability: position == 0 ? 1 : 0)
        ]
    }
    func finish() -> [VoiceActivityScore] { [] }
    func reset() { position = 0 }
    func cancel() {}
}

@Test(.timeLimit(.minutes(1))) func speechPerceptionRoutesOnlyFinalAndRejectsAfterStop() async throws {
    let policy = try CommunicationPolicy(configurations: [
        AgentConfigurations.load(named: "Assistant"), AgentConfigurations.load(named: "SpeechPerception"),
        AgentConfigurations.load(named: "SpeechSynthesis"),
    ])
    let session = UUID()
    let manager = AgentManager()
    let assistant = ObservationRecorder(id: "assistant")
    let speech = try SpeechPerceptionAgent(
        recognition: RecognitionFixture(text: "你好", includeFinal: true), vad: EndpointVAD(), sessionID: session)
    try await manager.register(assistant, sessionID: session)
    await assistant.start()
    try await manager.register(speech, sessionID: session)
    let input = InputGateway(manager: manager, policy: policy)
    let observed = AsyncStream<AgentInput>.makeStream(bufferingPolicy: .bufferingOldest(8))
    let captions = VoiceProbe()
    let scheduler = ChannelScheduler(
        registry: try testActionRegistry(handlers: [
            ActionPath(module: "UI", function: "setVoiceState"): { invocation in
                try await UIActions.setVoiceState(invocation: invocation) { _, _ in }
            },
            ActionPath(module: "UI", function: "finishTranscript"): { invocation in
                try await UIActions.finishTranscript(invocation: invocation) { _ in
                    await captions.displayed("")
                }
            },
            ActionPath(module: "UI", function: "setTranscript"): { invocation in
                #expect(invocation.envelope.source == .speechPerception)
                #expect(invocation.envelope.sessionID == session)
                try await UIActions.setTranscript(invocation: invocation) { text, _ in
                    await captions.displayed(text)
                }
            },
        ]))
    let output = OutputGateway(
        manager: manager, requests: input, tools: ToolRegistry(), actions: scheduler, policy: policy,
        observedContracts: ["speech.partial", "speech.phase"],
        observeEvent: { value in observed.continuation.yield(value) }, sink: { _ in })
    try await speech.bind(output.messaging(for: .speechPerception))
    try await speech.start()
    let outputTask = Task {
        for await envelope in speech.outputs { try await output.dispatch(envelope) }
    }
    let first = try AudioInput(samples: Data(repeating: 0, count: 1536 * 4), sequence: 0, timestamp: 0)
    let second = try AudioInput(samples: Data(repeating: 0, count: 12800 * 4), sequence: 1, timestamp: 0.096)
    _ = try await input.publish(AgentInput(sessionID: session, payload: .audio(first)))
    _ = try await input.publish(AgentInput(sessionID: session, payload: .audio(second)))
    for _ in 0..<10000 {
        if await assistant.inputs.contains(where: {
            if case .observation(.transcript(_, final: true)) = $0.payload { return true }
            return false
        }) {
            break
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    let finals = await assistant.inputs.filter {
        if case .observation(.transcript(_, final: true)) = $0.payload { return true }
        return false
    }
    #expect(finals.count == 1)
    if let value = finals.first, case .observation(let event) = value.payload {
        #expect(event == .transcript("你好", final: true))
        #expect(value.turn?.ordinal == 1)
    } else {
        Issue.record("Missing final observation")
    }
    try await speech.resumeListening()
    await speech.stop()
    try await outputTask.value
    let displayed = await captions.displayedText
    #expect(displayed.contains("partial"))
    #expect(displayed.last == "")
    #expect(displayed.filter { $0.isEmpty }.count == 1)
    await scheduler.shutdown()
    await #expect(throws: HarnessError.notRunning) {
        try await speech.receive(AgentInput(sessionID: session, payload: .audio(first)))
    }
    await manager.stopAll()
}

@Test func speechRawAudioQueueRejectsOverflowAndExpiredInput() async throws {
    let session = UUID()
    let speech = try SpeechPerceptionAgent(
        recognition: RecognitionFixture(text: "hello", includeFinal: true), vad: EndpointVAD(), sessionID: session)
    try await speech.bind(AgentMessaging { _, _, _ in DeliveryReport(delivered: [.assistant]) })
    try await speech.start()
    try await speech.pause()
    for i: UInt64 in 0..<4 {
        let audio = try AudioInput(samples: Data(repeating: 0, count: 64000), sequence: i, timestamp: Double(i))
        try await speech.receive(AgentInput(sessionID: session, payload: .audio(audio)))
    }
    let payload = InputPayload.audio(try AudioInput(samples: Data(repeating: 0, count: 4), sequence: 4, timestamp: 4))
    await #expect(throws: HarnessError.queueFull) {
        try await speech.receive(AgentInput(sessionID: session, payload: payload))
    }
    let expired = AgentInput(
        sessionID: session, payload: payload,
        metadata: InputMetadata(payload: payload, deadline: .now.advanced(by: .seconds(-1))))
    await #expect(throws: CommunicationError.expired) { try await speech.receive(expired) }
    #expect(await speech.status().queuedInputs == 4)
    await speech.stop()
    #expect(await speech.status().queuedInputs == 0)
}

@Test func transcriptActionAllowsClearAndRejectsInvalidPayloads() async throws {
    let probe = VoiceProbe()
    let input = AgentInput(sessionID: UUID(), payload: .event("fixture"))
    let call = ActionCall(
        actionPath: .init(module: "UI", function: "setTranscript"), channel: "Transcript", parameters: ["text": ""])
    let invocation = ActionInvocation(source: .speechPerception, input: input, call: call)
    try await UIActions.setTranscript(invocation: invocation) { value, _ in await probe.displayed(value) }
    #expect(await probe.displayedText == [""])
    await #expect(throws: CancellationError.self) {
        try await UIActions.setTranscript(invocation: invocation) { _, _ in throw CancellationError() }
    }
    for parameters in [[:], ["text": String(repeating: "a", count: 4097)]] {
        let invalid = ActionCall(actionPath: call.actionPath, channel: call.channel, parameters: parameters)
        await #expect(throws: UIActions.PresentationError.invalidText) {
            try await UIActions.setTranscript(
                invocation: ActionInvocation(source: .speechPerception, input: input, call: invalid)
            ) { _, _ in Issue.record("Invalid caption reached presentation") }
        }
    }
}

@Test(.timeLimit(.minutes(1))) func speechOnsetClearsAssistantPresentationOnlyThroughActions() async throws {
    let session = UUID()
    let manager = AgentManager()
    let assistant = try AssistantAgent(chat: FixedTextChat(text: "must not generate"))
    let source = ObservationRecorder(id: "speechPerception")
    try await manager.register(assistant, sessionID: session)
    try await manager.register(source, sessionID: session)
    try await assistant.start()
    await source.start()
    let policy = try CommunicationPolicy(configurations: [
        AgentConfigurations.load(named: "Assistant"), AgentConfigurations.load(named: "SpeechPerception"),
        AgentConfigurations.load(named: "SpeechSynthesis"),
    ])
    let input = InputGateway(manager: manager, policy: policy)
    let probe = VoiceProbe()
    let scheduler = ChannelScheduler(
        registry: try testActionRegistry(handlers: [
            ActionPath(module: "UI", function: "beginReplyTurn"): { invocation in
                try await UIActions.beginReplyTurn(invocation: invocation) { _ in
                    await probe.displayed("reply and expression cleared atomically")
                }
            }
        ]))
    let output = OutputGateway(
        manager: manager, requests: input, tools: ToolRegistry(),
        actions: scheduler, policy: policy, sink: { _ in })
    let port = try await output.messaging(for: .speechPerception)
    let parent = AgentInput(
        sessionID: session,
        payload: .audio(
            try AudioInput(samples: Data(repeating: 0, count: 4), sequence: 0, timestamp: 0)),
        turn: ConversationTurn(ordinal: 1))
    let report = try await port.publish(.speechPhase(.speaking), parent: parent)
    #expect(report.delivered == [.assistant])
    // Signal delivery alone cannot mutate the presentation handler's state.
    #expect(await probe.displayedText.isEmpty)
    var functions: [String] = []
    for await envelope in assistant.outputs {
        if case .actionCall(let call) = envelope.output { functions.append(call.actionPath.function) }
        try await output.dispatch(envelope)
        if envelope.output == .control("agent.finished") { break }
    }
    #expect(functions == ["beginReplyTurn"])
    #expect(await probe.displayedText == ["reply and expression cleared atomically"])
    // A second VAD onset in the same long utterance must not issue another reset.
    _ = try await port.publish(.speechPhase(.speaking), parent: parent)
    for await envelope in assistant.outputs {
        #expect(envelope.turn == parent.turn)
        #expect(envelope.output == .control("agent.finished"))
        try await output.dispatch(envelope)
        break
    }
    #expect(await probe.displayedText.count == 1)
    await assistant.stop()
    await scheduler.shutdown()
    await manager.stopAll()
}

@Test func conversationPresentationRejectsLateClosedAndRepeatedUpdates() throws {
    let session = UUID()
    let first = ConversationTurn(ordinal: 1)
    let second = ConversationTurn(ordinal: 2)
    func envelope(_ turn: ConversationTurn, _ sequence: UInt64, _ source: AgentID) -> OutputEnvelope {
        OutputEnvelope(
            source: source,
            input: AgentInput(sessionID: session, payload: .text("fixture"), turn: turn),
            output: .control("fixture"), sequence: sequence)
    }
    var state = ConversationPresentation()
    // A preview may beat Assistant's reset without being erased by that reset.
    let accepted1 = state.accept(envelope(first, 1, .speechPerception), update: .transcript)
    #expect(accepted1)
    let accepted2 = state.accept(envelope(first, 1, .assistant), update: .beginReply)
    #expect(accepted2)
    let accepted3 = state.accept(envelope(first, 2, .assistant), update: .beginReply)
    #expect(!accepted3)
    let accepted4 = state.accept(envelope(first, 3, .speechPerception), update: .finishTranscript)
    #expect(accepted4)
    let accepted5 = state.accept(envelope(first, 4, .speechPerception), update: .transcript)
    #expect(!accepted5)
    let accepted6 = state.accept(envelope(first, 3, .assistant), update: .reply)
    #expect(accepted6)
    let accepted7 = state.accept(envelope(first, 2, .assistant), update: .reply)
    #expect(!accepted7)
    let accepted8 = state.accept(envelope(first, 4, .assistant), update: .expression)
    #expect(accepted8)
    let accepted9 = state.accept(envelope(second, 5, .speechPerception), update: .transcript)
    #expect(accepted9)
    let accepted10 = state.accept(envelope(first, 99, .assistant), update: .expression)
    #expect(!accepted10)
    let accepted11 = state.accept(envelope(first, 99, .speechPerception), update: .finishTranscript)
    #expect(!accepted11)
    let accepted12 = state.accept(envelope(ConversationTurn(ordinal: 2), 100, .assistant), update: .beginReply)
    #expect(!accepted12)
    let accepted13 = state.accept(envelope(second, 6, .assistant), update: .beginReply)
    #expect(accepted13)
    #expect(!state.transcriptClosed)
    let accepted14 = state.accept(envelope(second, 7, .assistant), update: .reply)
    #expect(accepted14)
    let accepted15 = state.accept(envelope(second, 8, .speechPerception), update: .expression)
    #expect(!accepted15)
}

// The UI must distinguish frequency content, not simply animate any nonzero RMS.
@Test func spectrumSeparatesLowAndHighTonesAcrossSampleRates() {
    for rate in [16000, 24000, 48000] {
        func spectrum(_ frequency: Double, amplitude: Double = 0.1) -> [Float] {
            AudioSpectrum.measure(
                (0..<2048).map { index in
                    Float(amplitude * sin(2 * .pi * frequency * Double(index) / Double(rate)))
                }, sampleRate: rate)
        }
        let bass = spectrum(250)
        let treble = spectrum(4000)
        let bassPeak = bass.indices.max { bass[$0] < bass[$1] } ?? 0
        let treblePeak = treble.indices.max { treble[$0] < treble[$1] } ?? 0
        #expect((6...9).contains(bassPeak))
        #expect((26...28).contains(treblePeak))
        #expect(bass[bassPeak] > bass[treblePeak] + 0.5)
        #expect(treble[treblePeak] > treble[bassPeak] + 0.5)
        #expect(spectrum(250, amplitude: 0.01)[bassPeak] < bass[bassPeak] - 0.25)
    }
}

@Test func spectrumSilenceDCAndInvalidPCMDoNotInventEnergy() {
    #expect(AudioSpectrum.measure([Float](), sampleRate: 48000) == AudioSpectrum.silence)
    #expect(AudioSpectrum.measure([Float](repeating: 0, count: 8192), sampleRate: 48000) == AudioSpectrum.silence)
    #expect(AudioSpectrum.measure([Float](repeating: 0.2, count: 2048), sampleRate: 48000) == AudioSpectrum.silence)
    #expect(AudioSpectrum.measure([Float.nan, .infinity], sampleRate: 48000) == AudioSpectrum.silence)
    #expect(AudioSpectrum.measure([1], sampleRate: 0) == AudioSpectrum.silence)
}

@Test func spectrumUsesLatestBoundedWindowAndIsDeterministic() {
    let signal = (0..<2048).map { Float(0.1 * sin(2 * Double.pi * 1000 * Double($0) / 16000)) }
    let expected = AudioSpectrum.measure(signal, sampleRate: 16000)
    let prefixed = [Float](repeating: 1, count: 20000) + signal
    #expect(AudioSpectrum.measure(prefixed, sampleRate: 16000) == expected)
    #expect(AudioSpectrum.measure(signal, sampleRate: 16000) == expected)
    #expect(expected.count == 32)
    #expect(expected.allSatisfy { $0.isFinite && (0...1).contains($0) })
}

@Test func spectrumReleaseSettlesWithoutOscillation() {
    let target = [Float](repeating: 0.8, count: 32)
    var levels = AudioSpectrum.smooth(target, previous: AudioSpectrum.silence)
    #expect(levels[0] > 0.6)
    for _ in 0..<24 {
        let next = AudioSpectrum.smooth(AudioSpectrum.silence, previous: levels)
        #expect(zip(next, levels).allSatisfy { $0 <= $1 })
        levels = next
    }
    #expect(levels == AudioSpectrum.silence)
}

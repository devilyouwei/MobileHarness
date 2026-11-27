import Actions
import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import ModelKit
import StorageCache
import StorageCore
import Synchronization
import Testing
import UI

@testable import Agents
@testable import PlatformKit

private struct RecognitionFixture: SpeechRecognitionCapability {
    let text: String
    let includeFinal: Bool
    var availability: CapabilityAvailability { .available }
    func transcribe(_ request: SpeechRecognitionRequest) async throws -> SpeechRecognitionSession {
        let pair = InferenceSession<TranscriptionEvent>.make(
            context: request.context,
            limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        let segment = UUID().uuidString
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
    var audio: [StorageCache.AudioFrame] = []
    func synthesized(_ text: String) { spokenText.append(text) }
    func displayed(_ text: String) { displayedText.append(text) }
    func played(_ frame: StorageCache.AudioFrame) { audio.append(frame) }
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

private func sampleFrame() throws -> ModelKit.AudioFrame {
    try ModelKit.AudioFrame(
        data: Data(repeating: 0, count: 320),
        format: ModelKit.AudioFormat(sampleRate: 16_000, channels: 1, encoding: .float32), sequence: 0, timestamp: 0)
}

private func preparedSpeech(
    text: String, input: AgentInput, probe: VoiceProbe, producesAudio: Bool = true
) async throws -> (AssistantSpeechOutput, AudioCache, SpeechPlayback, any FunctionInput) {
    let store = AudioCache()
    let agent = AssistantSpeechOutput()
    try await agent.configure(synthesis: SynthesisFixture(probe: probe, producesAudio: producesAudio), store: store)
    let audioID = try await agent.prepare(text: text, input: input)
    let call = ActionCall(
        actionPath: ActionPath(domain: "Speech", module: "Playback", function: "speak"), channel: "Speech",
        parameters: ["audioID": audioID])
    return (
        agent, store, SpeechPlayback(store: store),
        ActionInvocation(source: .assistant, input: input, call: call)
    )
}

@Test(.actionCatalog) func voiceGatewaysRoundTripThroughSayAndPrint() async throws {
    let manager = AgentManager()
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(),
        chat: FixedTextChat(text: "固定回复"),
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "assistant"), scope: UUID().uuidString, state: AssistantContextState())
    )
    try await manager.register(agent)

    let probe = VoiceProbe()
    let store = AudioCache()
    let synth = AssistantSpeechOutput()
    try await synth.configure(synthesis: SynthesisFixture(probe: probe), store: store)
    try await agent.bindSpeechOutput(synth)
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication,
        configurations: AgentConfigurations.all())
    let gateway = InputGateway(manager: manager, policy: policy)
    let playback = SpeechPlayback(store: store)
    let scheduler = ChannelScheduler(
        registry: try testActionRegistry(handlers: [
            ActionPath(domain: "Speech", module: "Playback", function: "speak"): { invocation in
                try await playback.play(invocation) { audio, _ in
                    while let frame = try await audio.next() { await probe.played(frame) }
                }
            },
            ActionPath(domain: "UI", module: "Caption", function: "print"): { invocation in
                try await UIActions.print(invocation: invocation) { text, _ in await probe.displayed(text) }
            },
        ])
    ) { await gateway.deliverActionResult($0) }
    let tools = ToolRegistry()
    let response = await OutputGateway(
        manager: manager, requests: gateway, tools: tools, actions: scheduler, policy: policy
    ) { _ in }
    try await bindFixtureCommunications(agent, port: await response.messaging(for: .assistant))
    try await agent.start()
    let recognition = RecognitionFixture(text: "你好", includeFinal: true)
    let sessionID = UUID().uuidString
    let turn = SpeechRecognitionTurn(recognition: recognition, sessionID: sessionID) { _ in }
    try await turn.enqueue([.audio([sampleFrame()]), .end(.silence)])
    let text = try await turn.finish()
    await probe.displayed(text)
    let report = try await manager.receiveLocally(
        AgentInput(id: UUID().uuidString, sessionID: sessionID, payload: .text(text)), to: .assistant)
    #expect(report.delivered == [.assistant])
    #expect(await agent.status().processedInputs == 1)
    var tokens: [String] = []
    for await envelope in fixtureOutputs(agent) {
        #expect(envelope.sessionID == sessionID)
        if case .actionCall(let token) = envelope.output { tokens.append(token.actionPath.function) }
        if case .toolCall(let token) = envelope.output { tokens.append(token.toolPath) }
        try await response.dispatch(envelope)
        if envelope.output == .control("agent.finished") { break }
    }
    await agent.stop()
    #expect(tokens == ["speak", "print"])
    #expect(await scheduler.executionSnapshot().records.map { $0.path.domain }.sorted() == ["Speech", "UI"])
    #expect(await probe.spokenText == ["固定回复"])
    #expect(await probe.displayedText == ["你好", "固定回复"])
    #expect(await probe.audio.count == 1)
    await response.shutdown()
    await synth.stop()
    await store.shutdown()
}

@Test(.actionCatalog) func partialRecognitionNeverSubmitsAgentInput() async throws {
    let manager = AgentManager()
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(),
        chat: FixedTextChat(),
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "assistant"), scope: UUID().uuidString, state: AssistantContextState())
    )
    try await manager.register(agent)
    try await agent.start()
    let recognition = RecognitionFixture(text: "", includeFinal: false)
    let turn = SpeechRecognitionTurn(recognition: recognition, sessionID: UUID().uuidString) { _ in }
    try await turn.enqueue([.audio([sampleFrame()]), .end(.silence)])
    #expect(try await turn.finish().isEmpty)
    #expect(await agent.status().processedInputs == 0)
    await agent.stop()
}

@Test(.actionCatalog) func speechFailureDoesNotInventSuccess() async throws {
    let probe = VoiceProbe()
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("你好"))
    let (synth, store, playback, invocation) = try await preparedSpeech(
        text: "回复", input: input, probe: probe, producesAudio: false)
    await #expect(throws: SpeechSynthesisError.invalidOutput) {
        try await playback.play(invocation) { audio, _ in
            while let frame = try await audio.next() { await probe.played(frame) }
        }
    }
    #expect(await probe.audio.isEmpty)
    await synth.stop()
    await store.shutdown()
}

@Test(.actionCatalog) func cancellingDuringPlaybackDoesNotDeliverLaterAudio() async throws {
    let manager = AgentManager()
    try await manager.register(
        AssistantAgent(
            stateContext: try publicStateFixture(),
            chat: FixedTextChat(),
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "assistant"), scope: UUID().uuidString, state: AssistantContextState())
        ))
    let probe = VoiceProbe()
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("你好"))
    let (synth, store, playback, invocation) = try await preparedSpeech(text: "回复", input: input, probe: probe)
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let actions = ChannelScheduler(
        registry: try testActionRegistry(handlers: [
            ActionPath(domain: "Speech", module: "Playback", function: "speak"): { invocation in
                try await playback.play(invocation) { audio, _ in
                    while let frame = try await audio.next() {
                        entered.continuation.yield(())
                        try await Task.sleep(for: .seconds(30))
                        await probe.played(frame)
                    }
                }
            }
        ]))
    let responses = await OutputGateway(
        manager: manager, requests: InputGateway(manager: manager),
        tools: ToolRegistry(), actions: actions
    ) { _ in }
    try await responses.dispatch(invocation.testEnvelope)
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    await store.cancel(sessionID: input.sessionID)
    await responses.cancel(sessionID: input.sessionID)
    #expect(await probe.audio.isEmpty)
    await responses.shutdown()
    await synth.stop()
    entered.continuation.finish()
}

@Test(.actionCatalog) func longVoiceTurnRecognizesChunksButSubmitsOnlyOnce() async throws {
    let manager = AgentManager()
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(),
        chat: FixedTextChat(),
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "assistant"), scope: UUID().uuidString, state: AssistantContextState())
    )
    try await manager.register(agent)
    try await agent.start()
    let gateway = InputGateway(manager: manager)
    let recognition = RecognitionFixture(text: "一段", includeFinal: true)
    let id = UUID().uuidString
    let turn = SpeechRecognitionTurn(recognition: recognition, sessionID: id) { _ in }
    try await turn.enqueue([.audio([sampleFrame()]), .end(.maximumDuration)])
    try await turn.enqueue([.audio([sampleFrame()]), .end(.silence)])
    let text = try await turn.finish()
    #expect(text == "一段 一段")
    #expect(await agent.status().processedInputs == 0)
    _ = try await manager.receiveLocally(
        AgentInput(id: UUID().uuidString, sessionID: id, payload: .text(text)), to: .assistant)
    #expect(await agent.status().processedInputs == 1)
    await #expect(throws: CapabilityError.self) {
        try await turn.enqueue([.audio([sampleFrame()]), .end(.silence)])
    }
    await agent.stop()
}

private actor BlockedRecognition: SpeechRecognitionCapability {
    var availability: CapabilityAvailability { .available }
    let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private let finalBeforeStall: String?
    init(finalBeforeStall: String? = nil) { self.finalBeforeStall = finalBeforeStall }

    func transcribe(_ request: SpeechRecognitionRequest) async throws -> SpeechRecognitionSession {
        let pair = InferenceSession<TranscriptionEvent>.make(
            context: request.context, limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        started.continuation.yield(())
        return SpeechRecognitionSession(
            output: pair.session, format: request.format, sendAudio: { _ in },
            finishInput: { [finalBeforeStall] in
                if let finalBeforeStall {
                    try pair.emitter.yield(
                        TranscriptionEvent(segmentID: "final", revision: 0, text: finalBeforeStall, isFinal: true))
                }
                try await Task.sleep(for: .seconds(60))
                pair.emitter.finish()
            })
    }
}

@Test(.actionCatalog) func voiceQueueOverflowIsExplicitAndCancellationReleasesGateway() async throws {
    let model = BlockedRecognition()
    let recognition = model
    let turn = SpeechRecognitionTurn(recognition: recognition, sessionID: UUID().uuidString) { _ in }
    try await turn.enqueue([.audio([sampleFrame()]), .end(.maximumDuration)])
    var started = model.started.stream.makeAsyncIterator()
    _ = await started.next()
    // A single oversized admission fails regardless of worker scheduling.
    await #expect(throws: CapabilityError.self) {
        try await turn.enqueue(Array(repeating: .end(.maximumDuration), count: 2049))
    }
    await turn.cancel()
    await #expect(throws: CapabilityError.self) { try await turn.finish() }
    let next = SpeechRecognitionTurn(recognition: recognition, sessionID: UUID().uuidString) { _ in }
    try await next.enqueue([.audio([sampleFrame()]), .end(.silence)])
    _ = await started.next()
    await next.cancel()
    await #expect(throws: CapabilityError.self) { try await next.finish() }
}

@Test(.timeLimit(.minutes(1)), arguments: [nil, "停下"] as [String?])
func noTranscriptEndpointCancelsAStalledRecognizer(final: String?) async throws {
    let recognition = BlockedRecognition(finalBeforeStall: final)
    let turn = SpeechRecognitionTurn(recognition: recognition, sessionID: UUID().uuidString) { _ in }
    try await turn.enqueue([.audio([sampleFrame()])])
    var started = recognition.started.stream.makeAsyncIterator()
    _ = await started.next()
    #expect(try await turn.finish(noTextGrace: .seconds(1)) == (final ?? ""))
    await #expect(throws: CapabilityError.sessionClosed) { try await turn.enqueue([.end(.silence)]) }
}

private struct LiveRecognitionFixture: SpeechRecognitionCapability {
    var availability: CapabilityAvailability { .available }
    func transcribe(_ request: SpeechRecognitionRequest) throws -> SpeechRecognitionSession {
        #expect(request.locale == "auto")
        let pair = InferenceSession<TranscriptionEvent>.make(
            context: request.context, limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        let id = UUID().uuidString
        let emittedPreview = Mutex(false)
        return SpeechRecognitionSession(
            output: pair.session, format: request.format,
            sendAudio: { _ in
                guard
                    emittedPreview.withLock({ emitted in
                        guard !emitted else { return false }
                        emitted = true
                        return true
                    })
                else { return }
                try pair.emitter.yield(
                    TranscriptionEvent(segmentID: id, revision: 2, text: "你好", isFinal: false))
                try pair.emitter.yield(
                    TranscriptionEvent(segmentID: id, revision: 1, text: "旧结果", isFinal: false))
            },
            finishInput: {
                try pair.emitter.yield(
                    TranscriptionEvent(segmentID: id, revision: 3, text: "你好世界", isFinal: true))
                pair.emitter.finish()
            })
    }
}

@Test(.actionCatalog) func livePreviewArrivesBeforeEndpointAndDoesNotTriggerAgent() async throws {
    let manager = AgentManager()
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(),
        chat: FixedTextChat(),
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "assistant"), scope: UUID().uuidString, state: AssistantContextState())
    )
    try await manager.register(agent)
    try await agent.start()
    let recognition = LiveRecognitionFixture()
    let previews = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(8))
    let turn = SpeechRecognitionTurn(recognition: recognition, sessionID: UUID().uuidString) {
        previews.continuation.yield($0)
    }
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

@Test(.actionCatalog) func cancellingLivePreviewClosesAdmissionAndAllowsNextSession() async throws {
    let recognition = LiveRecognitionFixture()
    let previews = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(8))
    let turn = SpeechRecognitionTurn(recognition: recognition, sessionID: UUID().uuidString) {
        previews.continuation.yield($0)
    }
    try await turn.enqueue([.audio([sampleFrame()])])
    var iterator = previews.stream.makeAsyncIterator()
    _ = await iterator.next()
    await turn.cancel()
    await #expect(throws: CapabilityError.self) { try await turn.enqueue([.end(.silence)]) }
    let next = SpeechRecognitionTurn(recognition: recognition, sessionID: UUID().uuidString) { _ in }
    try await next.enqueue([.audio([sampleFrame()]), .end(.silence)])
    #expect(try await next.finish() == "你好世界")
    previews.continuation.finish()
}

@Test(.timeLimit(.minutes(1))) func noTranscriptEndpointStaysOffAfterTextArrives() async throws {
    let previews = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(2))
    let turn = SpeechRecognitionTurn(recognition: LiveRecognitionFixture(), sessionID: UUID().uuidString) {
        previews.continuation.yield($0)
    }
    let format = try ModelKit.AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32)
    let frames = try (0..<64).map { sequence in
        try ModelKit.AudioFrame(
            floatSamples: Array(repeating: 0.1, count: 512), format: format,
            sequence: UInt64(sequence), timestamp: Double(sequence) * 0.032)
    }
    try await turn.enqueue([.audio(frames)])
    var preview = previews.stream.makeAsyncIterator()
    #expect(await preview.next() == "你好")
    #expect(await !turn.reachedNoTextEndpoint)
    #expect(try await turn.finish() == "你好世界")
    #expect(await !turn.reachedNoTextEndpoint)
    previews.continuation.finish()
}

private struct BufferedTextRecognition: SpeechRecognitionCapability {
    let sixtyFive = ColdVoiceGate()
    let availability: CapabilityAvailability = .available

    func transcribe(_ request: SpeechRecognitionRequest) throws -> SpeechRecognitionSession {
        let events = InferenceSession<TranscriptionEvent>.make(
            context: request.context, limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        let frames = Mutex(0)
        return SpeechRecognitionSession(
            output: events.session, format: request.format,
            sendAudio: { _ in
                let index = frames.withLock { value in
                    value += 1
                    return value
                }
                switch index {
                case 1:
                    try events.emitter.yield(.init(segmentID: "voice", revision: 1, text: "", isFinal: false))
                case 64:
                    try events.emitter.yield(.init(segmentID: "voice", revision: 2, text: "captured", isFinal: false))
                case 65:
                    try await sixtyFive.wait()
                default:
                    break
                }
            },
            finishInput: {
                try events.emitter.yield(.init(segmentID: "voice", revision: 3, text: "captured", isFinal: true))
                events.emitter.finish()
            })
    }
}

@Test(.timeLimit(.minutes(1))) func noTranscriptEndpointWaitsForBufferedRecognitionText() async throws {
    let model = BufferedTextRecognition()
    let blankPreview = ColdVoiceGate()
    defer {
        blankPreview.open()
        model.sixtyFive.open()
    }
    let turn = SpeechRecognitionTurn(recognition: model, sessionID: "buffered") {
        if $0.isEmpty { try await blankPreview.wait() }
    }
    let format = try ModelKit.AudioFormat(sampleRate: 16_000, channels: 1, encoding: .float32)
    let frames = try (0..<65).map { sequence in
        try ModelKit.AudioFrame(
            floatSamples: Array(repeating: 0.1, count: 512), format: format,
            sequence: UInt64(sequence), timestamp: Double(sequence) * 0.032)
    }
    try await turn.enqueue([.audio(Array(frames.prefix(64))), .audio([frames[64]])])
    var preview = blankPreview.entered.stream.makeAsyncIterator()
    _ = await preview.next()
    var threshold = model.sixtyFive.entered.stream.makeAsyncIterator()
    _ = await threshold.next()
    #expect(await !turn.reachedNoTextEndpoint)
    blankPreview.open()
    model.sixtyFive.open()
    #expect(try await turn.finish() == "captured")
}

@Test(.actionCatalog, arguments: [nil, "", " \n\t", String(repeating: "界", count: 667)])
func textActionsRejectInvalidParametersBeforeSideEffects(_ text: String?) async throws {
    let probe = VoiceProbe()
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("request"))
    let call = ActionCall(
        actionPath: ActionPath(domain: "UI", module: "Caption", function: "print"), channel: "Display",
        parameters: text.map { ["text": $0] } ?? [:])
    let invocation = ActionInvocation(source: .assistant, input: input, call: call)
    await #expect(throws: UIActions.PresentationError.invalidText) {
        try await UIActions.print(invocation: uiActionInvocation(invocation)) { value, _ in await probe.displayed(value)
        }
    }
    #expect(throws: SpeechValidationError.invalidRequest) { _ = try AssistantSpeechOutput.validate(text: text ?? "") }
    #expect(await probe.displayedText.isEmpty)
}

@Test(.actionCatalog) func textActionsPreserveAcceptedTextAtByteLimit() async throws {
    let text = " " + String(repeating: "界", count: 666) + " "
    #expect(text.utf8.count == 2000)
    let probe = VoiceProbe()
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("request"))
    let (synth, store, playback, invocation) = try await preparedSpeech(text: text, input: input, probe: probe)
    try await playback.play(invocation) { audio, _ in
        while let frame = try await audio.next() { await probe.played(frame) }
    }
    let call = expectedActionCall(name: "print", parameters: ["text": text])
    let display = ActionInvocation(source: .assistant, input: input, call: call)
    try await UIActions.print(invocation: uiActionInvocation(display)) { value, _ in await probe.displayed(value) }
    #expect(await probe.spokenText == [text])
    #expect(await probe.displayedText == [text])
    #expect(await probe.audio.count == 1)
    await synth.stop()
    await store.shutdown()
}

@Test(.actionCatalog, arguments: [nil, "", "Happy", "unknown", "clear"])
func expressionsRejectInvalidEmotionBeforePresentation(_ emotion: String?) async throws {
    let probe = VoiceProbe()
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("request"))
    let call = ActionCall(
        actionPath: ActionPath(domain: "UI", module: "Expression", function: "express"), channel: "Display",
        parameters: emotion.map { ["emotion": $0] } ?? [:])
    let invocation = ActionInvocation(source: .assistant, input: input, call: call)
    await #expect(throws: UIActions.ExpressionError.invalidEmotion) {
        try await UIActions.express(
            invocation: invocation, using: { value, _ in await probe.displayed(value.rawValue) }, restoring: { _ in })
    }
    #expect(await probe.displayedText.isEmpty)
}

@Test(.actionCatalog) func expressionPresentationPropagatesCancellation() async throws {
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("request"))
    let call = ActionCall(
        actionPath: ActionPath(domain: "UI", module: "Expression", function: "express"), channel: "Display",
        parameters: ["emotion": "happy"])
    let invocation = ActionInvocation(source: .assistant, input: input, call: call)
    await #expect(throws: CancellationError.self) {
        try await UIActions.express(
            invocation: invocation, using: { _, _ in throw CancellationError() }, restoring: { _ in })
    }
}

@Test(.actionCatalog, arguments: UIActions.Emotion.allCases)
func expressionPreservesSemanticIdentifier(_ emotion: UIActions.Emotion) async throws {
    let probe = VoiceProbe()
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("request"))
    let call = expectedActionCall(name: "express", parameters: ["emotion": emotion.rawValue])
    let invocation = ActionInvocation(source: .assistant, input: input, call: call)
    try await UIActions.setExpression(invocation: invocation) { value, _ in await probe.displayed(value.rawValue) }
    #expect(await probe.displayedText == [emotion.rawValue])
    #expect(await probe.spokenText.isEmpty)
}

struct EndpointVAD: VoiceActivityCapability {
    var voicedWindows = 3
    var availability: CapabilityAvailability { .available }
    func detectVoiceActivity(format: ModelKit.AudioFormat) -> any VoiceActivitySession {
        EndpointVADSession(voicedWindows: voicedWindows)
    }
}

private actor EndpointVADSession: VoiceActivitySession {
    private var position: Int64 = 0
    private var pending = 0
    private let voicedSamples: Int64
    init(voicedWindows: Int = 3) { voicedSamples = Int64(voicedWindows * 512) }
    func process(_ frame: ModelKit.AudioFrame) throws -> [VoiceActivityScore] {
        pending += frame.sampleCount
        var scores: [VoiceActivityScore] = []
        while pending >= 512 {
            scores.append(
                try VoiceActivityScore(
                    startSample: position, sampleCount: 512, probability: position < voicedSamples ? 1 : 0))
            position += 512
            pending -= 512
        }
        return scores
    }
    func finish() -> [VoiceActivityScore] { [] }
    func reset() {
        position = 0
        pending = 0
    }
    func cancel() {}
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func nativeSpeechPublishesCaptureAndOnsetSignals() async throws {
    let root = UUID().uuidString
    let captureSession = UUID().uuidString
    let microphone = NativeMicrophoneFixture()
    let speech = try SpeechPerceptionAgent(
        recognition: RecognitionFixture(text: "hello", includeFinal: true), vad: EndpointVAD(), sessionID: root,
        interactionSessionID: root, residentListening: true, microphoneInput: microphone,
        speechDetection: { (16, 0.5) },
        context: try AgentContextRepository(
            agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState()))
    try await speech.start()
    let probe = PerceptionListeningProbe()
    let pump = Task { for await envelope in speech.outputs { await probe.record(envelope) } }
    try await speech.receive(ListeningIntent(enabled: true).input(sessionID: root))
    try await speech.openCapture(sessionID: captureSession)
    try await speech.startInput(sessionID: captureSession)
    let origin = ContinuousClock.now
    for sequence: UInt64 in 0..<21 {
        let timestamp = Double(sequence) * 0.064
        try microphone.capture.send(
            MicrophoneFrame(
                samples: [Float](repeating: 0, count: 1024), sampleRate: 16000, sequence: sequence,
                timestamp: timestamp, capturedAt: origin.advanced(by: .seconds(timestamp))))
    }
    for _ in 0..<1000 {
        if await probe.activities.contains(where: { $0.kind == .onsetCleared }) { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    let activities = await probe.activities
    let kinds = activities.map(\.kind)
    let started = try #require(kinds.firstIndex(of: .captureStarted))
    let onset = try #require(kinds.firstIndex(of: .onsetStarted))
    // Three speech windows never reach the sixteen-window onset, so the candidate is published and then cleared.
    let cleared = try #require(kinds.firstIndex(of: .onsetCleared))
    #expect(started < onset && onset < cleared)
    #expect(!kinds.contains(.onsetConfirmed))
    #expect(UUID(uuidString: activities[started].generation) != nil)
    await speech.closeCapture()
    await speech.stop()
    await pump.value
    #expect(await probe.activities.last?.kind == .captureStopped)
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func speechPerceptionRoutesOnlyFinalAndRejectsAfterStop() async throws {
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication,
        configurations: AgentConfigurations.all())
    let session = UUID().uuidString
    let manager = AgentManager()
    let assistant = ObservationRecorder(id: "assistant")
    let context = try AgentContextRepository(
        agent: AgentID(rawValue: "speechPerception"), scope: UUID().uuidString, state: SpeechPerceptionContextState())
    let speech = try SpeechPerceptionAgent(
        recognition: RecognitionFixture(text: "你好", includeFinal: true), vad: EndpointVAD(), sessionID: session,
        speechDetection: { (3, 0.5) },
        context: context)
    try await manager.register(assistant, sessionID: session)
    await assistant.start()
    try await manager.register(speech, sessionID: session)
    let input = InputGateway(manager: manager, policy: policy)
    let observed = AsyncStream<AgentInput>.makeStream(bufferingPolicy: .bufferingOldest(8))
    let captions = VoiceProbe()
    let scheduler = ChannelScheduler(registry: try testActionRegistry(handlers: [:]))
    let tools = ToolRegistry()
    try await tools.registerCompletion("UI.VoiceState.setVoiceState") { invocation in
        try await UIActions.setVoiceState(invocation: invocation) { _, _ in }
    }
    try await tools.registerCompletion("UI.Caption.finishTranscript") { invocation in
        try await UIActions.finishTranscript(invocation: invocation) { _ in
            await captions.displayed("sealed")
        }
    }
    try await tools.registerCompletion("UI.Caption.setTranscript") { invocation in
        #expect(
            invocation.context.source == AgentID.speechPerception.rawValue && invocation.context.sessionID == session)
        try await UIActions.setTranscript(invocation: invocation) { text, _ in
            await captions.displayed(text)
        }
    }
    let output = await OutputGateway(
        manager: manager, requests: input, tools: tools, actions: scheduler, policy: policy,
        observedContracts: [PerceptionMessage.speechProtocol],
        observeEvent: { value in observed.continuation.yield(value) }, sink: { _ in })
    // Static consumers bind themselves at assembly; publishing never initializes them.
    _ = try await output.consumer(for: assistant)
    try await speech.bind(output.messaging(for: .speechPerception))
    try await speech.start()
    let outputTask = Task {
        for await envelope in fixtureOutputs(speech) { try await output.dispatch(envelope) }
    }
    let first = try syntheticAudioInput(
        samples: Data(repeating: 0, count: 1536 * 4), sampleRate: 16000, sequence: 0, timestamp: 0)
    let second = try syntheticAudioInput(
        samples: Data(repeating: 0, count: 16 * 512 * 4), sampleRate: 16000,
        sequence: 1, timestamp: 0.096)
    _ = try await processMicrophoneFixture(
        AgentInput(
            id: UUID().uuidString,
            sessionID: session, payload: .audio(first),
            metadata: InputMetadata(
                payload: .audio(first), source: "phone.microphone", rootID: UUID().uuidString)), using: speech)
    _ = try await processMicrophoneFixture(
        AgentInput(
            id: UUID().uuidString,
            sessionID: session, payload: .audio(second),
            metadata: InputMetadata(
                payload: .audio(second), source: "phone.microphone", rootID: UUID().uuidString)), using: speech)
    #expect(try await context.snapshot().state.phase == "speaking")
    let remaining = try syntheticAudioInput(
        samples: Data(repeating: 0, count: 9 * 512 * 4), sampleRate: 16000, sequence: 2, timestamp: 0.608)
    try await processMicrophoneFixture(
        .init(id: UUID().uuidString, sessionID: session, payload: .audio(remaining)), using: speech)
    for _ in 0..<10000 {
        if await assistant.inputs.contains(where: {
            if case .transcript(_, final: true)? = $0.payload.perception { return true }
            return false
        }) {
            break
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    let finals = await assistant.inputs.filter {
        if case .transcript(_, final: true)? = $0.payload.perception { return true }
        return false
    }
    #expect(finals.count == 1)
    #expect(await assistant.inputs.count == 1)
    await input.flushPublications()
    var previews = observed.stream.makeAsyncIterator()
    let preview = try #require(await previews.next())
    #expect(preview.metadata.contract == PerceptionMessage.speechProtocol)
    #expect(preview.metadata.topic == PerceptionMessage.userInputTopic)
    if let value = finals.first, case .observation(let event) = value.payload {
        #expect(event.perception == .transcript("你好", final: true))
        #expect(value.metadata.topic == PerceptionMessage.userInputTopic)
        #expect(value.turn?.ordinal == 1)
    } else {
        Issue.record("Missing final observation")
    }
    try await speech.resumeListening()
    await speech.stop()
    try await outputTask.value
    let displayed = await captions.displayedText
    #expect(displayed.contains("partial"))
    #expect(Array(displayed.suffix(2)) == ["你好", "sealed"])
    #expect(displayed.first == "")
    await scheduler.shutdown()
    await #expect(throws: HarnessError.notRunning) {
        try await processMicrophoneFixture(
            AgentInput(
                id: UUID().uuidString,
                sessionID: session, payload: .audio(first),
                metadata: InputMetadata(
                    payload: .audio(first), source: "phone.microphone", rootID: UUID().uuidString)), using: speech)
    }
    await manager.stopAll()
}

@Test(.actionCatalog) func speechRejectsGenericAudioIngressWithoutQueuing() async throws {
    let session = UUID().uuidString
    let speech = try SpeechPerceptionAgent(
        recognition: RecognitionFixture(text: "hello", includeFinal: true), vad: EndpointVAD(), sessionID: session,
        speechDetection: { (3, 0.5) },
        context: try AgentContextRepository(
            agent: .speechPerception, scope: UUID().uuidString,
            state: SpeechPerceptionContextState()))
    try await speech.start()
    let audio = try syntheticAudioInput(
        samples: Data(repeating: 0, count: 640), sampleRate: 16000,
        sequence: 0, timestamp: 0)
    await #expect(throws: HarnessError.unsupportedInput) {
        try await speech.receive(AgentInput(id: UUID().uuidString, sessionID: session, payload: .audio(audio)))
    }
    #expect(await speech.status().queuedInputs == 0)
    #expect(await speech.status().processedInputs == 0)
    await speech.stop()
}

@Test(.actionCatalog) func transcriptActionAllowsClearAndRejectsInvalidPayloads() async throws {
    let probe = VoiceProbe()
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .event("fixture"))
    let call = ActionCall(
        actionPath: .init(domain: "UI", module: "Caption", function: "setTranscript"), channel: "Transcript",
        parameters: ["text": ""])
    let invocation = ActionInvocation(source: .speechPerception, input: input, call: call)
    try await UIActions.setTranscript(invocation: uiActionInvocation(invocation)) { value, _ in
        await probe.displayed(value)
    }
    #expect(await probe.displayedText == [""])
    await #expect(throws: CancellationError.self) {
        try await UIActions.setTranscript(invocation: uiActionInvocation(invocation)) { _, _ in
            throw CancellationError()
        }
    }
    for parameters in [[:], ["text": String(repeating: "a", count: 4097)]] {
        let invalid = ActionCall(actionPath: call.actionPath, channel: call.channel, parameters: parameters)
        await #expect(throws: UIActions.PresentationError.invalidText) {
            try await UIActions.setTranscript(
                invocation: uiActionInvocation(ActionInvocation(source: .speechPerception, input: input, call: invalid))
            ) { _, _ in Issue.record("Invalid caption reached presentation") }
        }
    }
}

@Test(.actionCatalog) func conversationPresentationRejectsLateClosedAndRepeatedUpdates() throws {
    let session = UUID().uuidString
    let first = AgentTurn(id: UUID().uuidString, ordinal: 1)
    let second = AgentTurn(id: UUID().uuidString, ordinal: 2)
    func envelope(_ turn: AgentTurn, _ sequence: UInt64, _ source: AgentID) -> ActionExecutionContext {
        OutputEnvelope(
            source: source,
            context: (AgentInput(
                id: UUID().uuidString, sessionID: session, payload: .text("fixture"), turn: turn)).context,
            output: .control("fixture"), sequence: sequence
        ).executionContext
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
    #expect(accepted10)  // Recognition may advance while the current reply remains active.
    let accepted11 = state.accept(envelope(first, 99, .speechPerception), update: .finishTranscript)
    #expect(!accepted11)
    let accepted12 = state.accept(
        envelope(AgentTurn(id: UUID().uuidString, ordinal: 2), 1, .assistant), update: .beginReply)
    #expect(!accepted12)
    let accepted13 = state.accept(envelope(second, 100, .assistant), update: .beginReply)
    #expect(accepted13)
    #expect(!state.transcriptClosed)
    let accepted14 = state.accept(envelope(second, 101, .assistant), update: .reply)
    #expect(accepted14)
    let accepted15 = state.accept(envelope(second, 8, .speechPerception), update: .expression)
    #expect(!accepted15)
}

// The UI must distinguish frequency content, not simply animate any nonzero RMS.
@Test(.actionCatalog) func spectrumSeparatesLowAndHighTonesAcrossSampleRates() {
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

@Test(.actionCatalog) func spectrumSilenceDCAndInvalidPCMDoNotInventEnergy() {
    #expect(AudioSpectrum.measure([Float](), sampleRate: 48000) == AudioSpectrum.silence)
    #expect(AudioSpectrum.measure([Float](repeating: 0, count: 8192), sampleRate: 48000) == AudioSpectrum.silence)
    #expect(AudioSpectrum.measure([Float](repeating: 0.2, count: 2048), sampleRate: 48000) == AudioSpectrum.silence)
    #expect(AudioSpectrum.measure([Float.nan, .infinity], sampleRate: 48000) == AudioSpectrum.silence)
    #expect(AudioSpectrum.measure([1], sampleRate: 0) == AudioSpectrum.silence)
}

@Test(.actionCatalog) func spectrumUsesLatestBoundedWindowAndIsDeterministic() {
    let signal = (0..<2048).map { Float(0.1 * sin(2 * Double.pi * 1000 * Double($0) / 16000)) }
    let expected = AudioSpectrum.measure(signal, sampleRate: 16000)
    let prefixed = [Float](repeating: 1, count: 20000) + signal
    #expect(AudioSpectrum.measure(prefixed, sampleRate: 16000) == expected)
    #expect(AudioSpectrum.measure(signal, sampleRate: 16000) == expected)
    #expect(expected.count == 32)
    #expect(expected.allSatisfy { $0.isFinite && (0...1).contains($0) })
}

@Test(.actionCatalog) func spectrumReleaseSettlesWithoutOscillation() {
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

@Test(.actionCatalog) func speechTranscriptAccumulatorRetainsOrderAndSealsFinalSegments() throws {
    var transcript = TranscriptAccumulator(prefix: "前段")
    let first = UUID().uuidString
    let second = UUID().uuidString
    #expect(
        try transcript.accept(TranscriptionEvent(segmentID: first, revision: 2, text: "新", isFinal: false))
            == "前段 新")
    #expect(
        try transcript.accept(TranscriptionEvent(segmentID: first, revision: 1, text: "旧", isFinal: false))
            == nil)
    #expect(
        try transcript.accept(TranscriptionEvent(segmentID: second, revision: 0, text: "后", isFinal: true))
            == "前段 新 后")
    #expect(transcript.finalText == "后")
    #expect(
        try transcript.accept(TranscriptionEvent(segmentID: first, revision: 3, text: "完成", isFinal: true))
            == "前段 完成 后"
    )
    #expect(
        try transcript.accept(TranscriptionEvent(segmentID: first, revision: 4, text: "迟到", isFinal: true))
            == nil)
    #expect(transcript.finalText == "完成 后")
}

@Test(.actionCatalog) func speechTranscriptAccumulatorRejectsOversizeWithoutRetainingRevision() throws {
    var transcript = TranscriptAccumulator(prefix: String(repeating: "x", count: 65530))
    let segment = UUID().uuidString
    #expect(throws: CapabilityError.self) {
        try transcript.accept(
            TranscriptionEvent(segmentID: segment, revision: 9, text: "overflow", isFinal: true))
    }
    #expect(
        try transcript.accept(TranscriptionEvent(segmentID: segment, revision: 1, text: "ok", isFinal: true))
            != nil)
    #expect(transcript.finalText == "ok")
}

@Test(.actionCatalog) func speechBoundaryPaddingUsesSampleBudgetForVariableWindows() throws {
    var policy = SpeechBoundaryPolicy()
    let format = try ModelKit.AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32)
    var position = 0
    func frame(_ samples: Int) throws -> ModelKit.AudioFrame {
        defer { position += samples }
        return try ModelKit.AudioFrame(
            data: Data(repeating: 0, count: samples * 4), format: format,
            sequence: UInt64(position), timestamp: Double(position) / 16000)
    }
    _ = policy.consume(try frame(1536), probability: 1, threshold: 0.5, onsetWindows: 3)
    for _ in 0..<25 { _ = policy.consume(try frame(1024), probability: 0, threshold: 0.5, onsetWindows: 3) }
    let padding = policy.streamEvents.reduce(0) { total, event in
        if case .audio(let frames) = event { return total + frames.reduce(0) { $0 + $1.sampleCount } }
        return total
    }
    #expect(padding == 3072)
    #expect(!policy.isSpeaking)
    #expect(
        policy.streamEvents.contains {
            if case .end(.silence) = $0 { return true }
            return false
        })
}

@Test func speechVADReportsCandidateAndWindowOffsetAcrossPartialFrames() async throws {
    let segmenter = VoiceActivitySegmenter(session: EndpointVADSession())
    let format = try ModelKit.AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32)
    func frame(_ sequence: UInt64, _ count: Int) throws -> ModelKit.AudioFrame {
        try .init(
            data: Data(repeating: 0, count: count * 4), format: format,
            sequence: sequence, timestamp: Double(sequence) / 16000)
    }
    let partial = try await segmenter.process(frame(0, 256), threshold: 0.5, onsetWindows: 3)
    #expect(partial.windows.isEmpty)
    let first = try await segmenter.process(frame(256, 256), threshold: 0.5, onsetWindows: 3)
    #expect(first.windows.count == 1)
    #expect(first.windows.first?.offset == -256)
    #expect(first.windows.first?.sampleCount == 512)
    #expect(first.windows.first?.onsetCandidate == true)
    _ = try await segmenter.process(frame(512, 512), threshold: 0.5, onsetWindows: 3)
    let onset = try await segmenter.process(frame(1024, 512), threshold: 0.5, onsetWindows: 3)
    #expect(onset.isSpeaking)
    #expect(onset.windows.first?.onsetCandidate == false)
    await segmenter.cancel()
}

private actor SpeechEndpointProbe: SpeechEndpointCapability {
    let availability: CapabilityAvailability = .available
    private let outcomes: [Result<Float?, CapabilityError>]
    private(set) var inputs: [[Float]] = []

    init(_ outcomes: [Result<Float?, CapabilityError>]) { self.outcomes = outcomes }

    func completionProbability(for samples: [Float]) throws -> Float? {
        inputs.append(samples)
        return try outcomes[min(inputs.count - 1, outcomes.count - 1)].get()
    }
}

private actor EndpointPCMVoiceActivity: VoiceActivitySession {
    private var position: Int64 = 0

    func process(_ frame: ModelKit.AudioFrame) throws -> [VoiceActivityScore] {
        let start = position
        position += Int64(frame.sampleCount)
        return [
            try VoiceActivityScore(
                startSample: start, sampleCount: frame.sampleCount,
                probability: frame.floatSamples.first == 0 ? 0 : 1)
        ]
    }
    func finish() -> [VoiceActivityScore] { [] }
    func reset() { position = 0 }
    func cancel() {}
}

private func submitEndpointWindow(
    _ segmenter: VoiceActivitySegmenter, _ index: Int, sample: Float
) async throws -> VoiceSegmentation {
    let format = try ModelKit.AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32)
    let frame = try ModelKit.AudioFrame(
        floatSamples: Array(repeating: sample, count: 512), format: format,
        sequence: UInt64(index), timestamp: Double(index) * 0.032)
    return try await segmenter.process(frame, onsetWindows: 1)
}

private func endedAtSilence(_ result: VoiceSegmentation) -> Bool {
    result.streamEvents.contains {
        if case .end(.silence) = $0 { return true }
        return false
    }
}

@Test func smartTurnPreservesOneTurnThroughAnUnfinishedPause() async throws {
    let endpoint = SpeechEndpointProbe([.success(0.5), .success(0.8)])
    let segmenter = VoiceActivitySegmenter(session: EndpointPCMVoiceActivity(), endpointConfirmation: endpoint)
    _ = try await submitEndpointWindow(segmenter, 0, sample: 0.1)
    for index in 1...30 {
        let pause = try await submitEndpointWindow(segmenter, index, sample: 0)
        #expect(pause.isSpeaking && !endedAtSilence(pause))
    }
    #expect(await endpoint.inputs.map(\.count) == [26 * 512])
    let resumed = try await submitEndpointWindow(segmenter, 31, sample: 0.2)
    guard case .audio(let frames)? = resumed.streamEvents.first else {
        Issue.record("Resuming speech did not release held audio")
        return
    }
    #expect(frames.map(\.sampleCount).reduce(0, +) == 31 * 512)
    for index in 32..<56 { _ = try await submitEndpointWindow(segmenter, index, sample: 0) }
    let completed = try await submitEndpointWindow(segmenter, 56, sample: 0)
    #expect(endedAtSilence(completed) && !completed.isSpeaking)
    let inputs = await endpoint.inputs
    #expect(inputs.count == 2)
    #expect(inputs.last?.first == 0.1)
    #expect(inputs.last?.contains(0.2) == true)
    await segmenter.cancel()
}

@Test func smartTurnBoundsAnUnfinishedSilenceWithoutRepeatedInference() async throws {
    let endpoint = SpeechEndpointProbe([.success(0.1)])
    let segmenter = VoiceActivitySegmenter(session: EndpointPCMVoiceActivity(), endpointConfirmation: endpoint)
    _ = try await submitEndpointWindow(segmenter, 0, sample: 0.1)
    for index in 1...62 {
        #expect(try await submitEndpointWindow(segmenter, index, sample: 0).isSpeaking)
    }
    let completed = try await submitEndpointWindow(segmenter, 63, sample: 0)
    #expect(endedAtSilence(completed) && !completed.isSpeaking)
    #expect(await endpoint.inputs.count == 1)
    await segmenter.cancel()
}

@Test(arguments: [false, true])
func smartTurnUsesVADEndpointIfPredictionIsUnavailableOrFails(failure: Bool) async throws {
    let outcome: Result<Float?, CapabilityError> = failure ? .failure(.sessionClosed) : .success(nil)
    let endpoint = SpeechEndpointProbe([outcome])
    let segmenter = VoiceActivitySegmenter(session: EndpointPCMVoiceActivity(), endpointConfirmation: endpoint)
    _ = try await submitEndpointWindow(segmenter, 0, sample: 0.1)
    for index in 1..<25 { _ = try await submitEndpointWindow(segmenter, index, sample: 0) }
    let completed = try await submitEndpointWindow(segmenter, 25, sample: 0)
    #expect(endedAtSilence(completed) && !completed.isSpeaking)
    #expect(await endpoint.inputs.count == 1)
    await segmenter.cancel()
}

@Test func smartTurnUsesOnlyTheLatestEightSeconds() async throws {
    let endpoint = SpeechEndpointProbe([.success(0.8)])
    let segmenter = VoiceActivitySegmenter(session: EndpointPCMVoiceActivity(), endpointConfirmation: endpoint)
    _ = try await submitEndpointWindow(segmenter, 0, sample: 0.1)
    for index in 1...249 { _ = try await submitEndpointWindow(segmenter, index, sample: 0.2) }
    for index in 250...274 { _ = try await submitEndpointWindow(segmenter, index, sample: 0) }
    let inputs = await endpoint.inputs
    #expect(inputs.count == 1)
    #expect(inputs.first?.count == 128_000)
    #expect(inputs.first?.first == 0.2)
    #expect(inputs.first?.last == 0)
    await segmenter.cancel()
}

@Test(arguments: [false, true])
func speechBoundaryUsesCurrentEndpointDuringSilence(initiallyShort: Bool) throws {
    var policy = SpeechBoundaryPolicy()
    let format = try ModelKit.AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32)
    let frame = try ModelKit.AudioFrame(
        data: Data(repeating: 0, count: 512 * 4), format: format, sequence: 0, timestamp: 0)

    for _ in 0..<3 {
        _ = policy.consume(frame, probability: 1, threshold: 0.5, onsetWindows: 3, useShortEndpoint: initiallyShort)
    }
    for _ in 0..<15 {
        #expect(
            policy.consume(frame, probability: 0, threshold: 0.5, onsetWindows: 3, useShortEndpoint: initiallyShort)
                == nil)
    }
    let afterChange = policy.consume(
        frame, probability: 0, threshold: 0.5, onsetWindows: 3, useShortEndpoint: !initiallyShort)
    if initiallyShort {
        #expect(afterChange == nil)
        for _ in 0..<8 { #expect(policy.consume(frame, probability: 0, threshold: 0.5, onsetWindows: 3) == nil) }
        #expect(policy.consume(frame, probability: 0, threshold: 0.5, onsetWindows: 3) == .silence)
    } else {
        #expect(afterChange == .silence)
    }
    #expect(!policy.isSpeaking)
}

private actor NativeRateVADProbe: VoiceActivityCapability, VoiceActivitySession {
    nonisolated let availability: CapabilityAvailability = .available
    private(set) var requestedRate: Int?
    private(set) var receivedRate: Int?
    private(set) var receivedSamples = 0
    func detectVoiceActivity(format: ModelKit.AudioFormat) -> any VoiceActivitySession {
        requestedRate = format.sampleRate
        return self
    }
    func process(_ frame: ModelKit.AudioFrame) -> [VoiceActivityScore] {
        receivedRate = frame.format.sampleRate
        receivedSamples += frame.sampleCount
        return []
    }
    func finish() -> [VoiceActivityScore] { [] }
    func reset() {}
    func cancel() {}
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) func speechPerceptionPreparesNativeRateTransportForItsModel()
    async throws
{
    let probe = NativeRateVADProbe()
    let session = UUID().uuidString
    let agent = try SpeechPerceptionAgent(
        recognition: RecognitionFixture(text: "", includeFinal: false), vad: probe, sessionID: session,
        speechDetection: { (3, 0.5) },
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "speechPerception"), scope: UUID().uuidString,
            state: SpeechPerceptionContextState())
    )
    try await agent.bind(AgentMessaging { _, _, _ in DeliveryReport() })
    try await agent.start()
    let samples = [Float](repeating: 0.1, count: 8192)
    let audio = try syntheticAudioInput(
        samples: samples.withUnsafeBytes { Data($0) }, sampleRate: 48000, sequence: 0, timestamp: 0)
    try await processMicrophoneFixture(
        AgentInput(id: UUID().uuidString, sessionID: session, payload: .audio(audio)), using: agent)
    for _ in 0..<1000 {
        if await probe.receivedSamples > 0 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await probe.requestedRate == 16000)
    #expect(await probe.receivedRate == 16000)
    let receivedSamples = await probe.receivedSamples
    #expect(receivedSamples > 0 && receivedSamples < 8192)
    #expect(await agent.status().lifecycle == .running)
    await agent.stop()
}

private actor FailOnceRecognition: SpeechRecognitionCapability {
    var availability: CapabilityAvailability { .available }
    private var attempts = 0
    let failsAtFinish: Bool
    init(failsAtFinish: Bool) { self.failsAtFinish = failsAtFinish }
    func transcribe(_ request: SpeechRecognitionRequest) async throws -> SpeechRecognitionSession {
        attempts += 1
        if attempts == 1 {
            if !failsAtFinish { throw CapabilityError.unavailable("synthetic ASR failure") }
            let pair = InferenceSession<TranscriptionEvent>.make(
                context: request.context, limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
            return SpeechRecognitionSession(
                output: pair.session, format: request.format, sendAudio: { _ in },
                finishInput: {
                    pair.emitter.fail(
                        NSError(
                            domain: "SFSpeechErrorDomain", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "RecogRejected"]))
                })
        }
        return try await RecognitionFixture(text: "recovered", includeFinal: true).transcribe(request)
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: [false, true])
func speechRecognitionFailureReportsAndNextUtteranceStillPublishes(failsAtFinish: Bool) async throws {
    let session = UUID().uuidString
    let context = try AgentContextRepository(
        agent: AgentID(rawValue: "speechPerception"), scope: UUID().uuidString,
        state: SpeechPerceptionContextState())
    let agent = try SpeechPerceptionAgent(
        recognition: FailOnceRecognition(failsAtFinish: failsAtFinish), vad: EndpointVAD(), sessionID: session,
        speechDetection: { (3, 0.5) },
        context: context)
    let observed = Mutex((displays: [String](), sealed: 0))
    let events = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(16))
    try await agent.bind(
        AgentMessaging { message, _, _ in
            if case .transcript(let text, true)? = message.perception { events.continuation.yield(text) }
            return DeliveryReport()
        })
    try await agent.start()
    let pump = Task {
        var failed = false
        for await envelope in fixtureOutputs(agent) {
            if case .control(let message) = envelope.output, message.hasPrefix("agent.error:") {
                failed = true
                events.continuation.yield("error")
            }
            if case .toolCall(let call) = envelope.output {
                if call.toolPath == "UI.Caption.finishTranscript" { observed.withLock { $0.sealed += 1 } }
                if call.toolPath == "UI.VoiceState.setVoiceState", let state = call.arguments["state"] {
                    observed.withLock { $0.displays.append(state) }
                    if failed && state == "listening" {
                        failed = false
                        events.continuation.yield("listening")
                    }
                }
            }
        }
    }
    var values = events.stream.makeAsyncIterator()
    var sequence: UInt64 = 0
    func frame(_ speaking: Bool) throws -> AgentInput {
        defer { sequence += 1 }
        let samples = [Float](repeating: speaking ? 0.1 : 0, count: speaking ? 1536 : 12800)
        return AgentInput(
            id: UUID().uuidString,
            sessionID: session,
            payload: .audio(
                try syntheticAudioInput(
                    samples: samples.withUnsafeBytes { Data($0) }, sampleRate: 16000,
                    sequence: sequence, timestamp: Double(sequence))))
    }
    try await processMicrophoneFixture(frame(true), using: agent)
    try await processMicrophoneFixture(frame(false), using: agent)
    #expect(await values.next() == "error")
    #expect(await values.next() == "listening")
    #expect(try await context.snapshot().state.phase == "listening")
    #expect(observed.withLock { $0.sealed } == 1)
    #expect(observed.withLock { $0.displays.last } == "listening")
    if failsAtFinish { #expect(observed.withLock { $0.displays.contains("processing") }) }
    #expect(await agent.status().lifecycle == .running)
    try await processMicrophoneFixture(frame(true), using: agent)
    try await processMicrophoneFixture(frame(false), using: agent)
    #expect(await values.next() == "recovered")
    try await processMicrophoneFixture(frame(true), using: agent)
    #expect(await agent.status().lifecycle == .running)
    await agent.stop()
    await pump.value
}

@Test(.actionCatalog) func speechListeningResumesAfterPauseBeforeAnyCaptureFrame() async throws {
    let session = UUID().uuidString
    let agent = try SpeechPerceptionAgent(
        recognition: RecognitionFixture(text: "", includeFinal: false),
        vad: NativeRateVADProbe(), sessionID: session,
        speechDetection: { (3, 0.5) },
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "speechPerception"), scope: UUID().uuidString,
            state: SpeechPerceptionContextState())
    )
    try await agent.start()
    try await agent.pauseAudioAdmission()
    try await agent.resumeListening()
    let samples = [Float](repeating: 0, count: 1024)
    try await processMicrophoneFixture(
        AgentInput(
            id: UUID().uuidString,
            sessionID: session,
            payload: .audio(
                try syntheticAudioInput(
                    samples: samples.withUnsafeBytes { Data($0) }, sampleRate: 16000,
                    sequence: 0, timestamp: 0))), using: agent)
    #expect(await agent.status().lifecycle == .running)
    await agent.stop()
}

private actor PerceptionListeningProbe {
    struct Value: Sendable {
        let enabled: Bool
        let paused: Bool
        let revision: UInt64
    }
    var values: [Value] = []
    var finalRoots: [String] = []
    var activities: [SpeechActivity] = []
    func record(_ envelope: OutputEnvelope) {
        if case .communication(let action) = envelope.output,
            let activity = action.message.content(as: SpeechActivity.self)
        {
            activities.append(activity)
        }
        if case .communication(let action) = envelope.output,
            case .transcript(_, true)? = action.message.perception
        {
            finalRoots.append(envelope.inputMetadata.rootID)
        }
        guard case .toolCall(let call) = envelope.output,
            call.toolPath == "Speech.Listening.update",
            let enabled = call.arguments["enabled"].flatMap(Bool.init),
            let paused = call.arguments["paused"].flatMap(Bool.init),
            let revision = call.arguments["revision"].flatMap(UInt64.init)
        else { return }
        values.append(Value(enabled: enabled, paused: paused, revision: revision))
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func speechPerceptionOwnsConsentAcrossCaptureEpochs() async throws {
    let session = UUID().uuidString
    let agent = try SpeechPerceptionAgent(
        recognition: RecognitionFixture(text: "", includeFinal: false), vad: NativeRateVADProbe(),
        sessionID: session, interactionSessionID: session, residentListening: true,
        speechDetection: { (3, 0.5) },
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "speechPerception"), scope: UUID().uuidString,
            state: SpeechPerceptionContextState())
    )
    try await agent.start()
    let probe = PerceptionListeningProbe()
    let pump = Task { for await output in agent.outputs { await probe.record(output) } }
    try await agent.receive(ListeningIntent().input(sessionID: session))
    let epoch = UUID().uuidString
    try await agent.openCapture(sessionID: epoch)
    try await agent.receive(ListeningIntent().input(sessionID: session))
    await agent.closeCapture()
    #expect(await agent.status().lifecycle == .running)
    try await agent.receive(ListeningIntent().input(sessionID: session))
    try await agent.openCapture(sessionID: UUID().uuidString)
    await agent.stop()
    await pump.value
    let values = await probe.values
    try #require(values.count == 3)
    #expect(values[0].enabled && !values[0].paused)
    #expect(!values[1].enabled && !values[1].paused)
    #expect(values[2].enabled && !values[2].paused)
    #expect(zip(values, values.dropFirst()).allSatisfy { $0.revision < $1.revision })
}

@Test(.actionCatalog) func speechPerceptionRejectsForgedListeningAndCrossSessionControl() async throws {
    let session = UUID().uuidString
    let agent = try SpeechPerceptionAgent(
        recognition: RecognitionFixture(text: "", includeFinal: false), vad: NativeRateVADProbe(),
        sessionID: session, interactionSessionID: session, residentListening: true,
        speechDetection: { (3, 0.5) },
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "speechPerception"), scope: UUID().uuidString,
            state: SpeechPerceptionContextState())
    )
    try await agent.start()
    await #expect(throws: CommunicationError.scopeClosed) {
        try await agent.receive(ListeningIntent().input(sessionID: UUID().uuidString))
    }
    let payload = try ListeningIntent().input(sessionID: session).payload
    let forged = AgentInput(
        id: "forged", sessionID: session, payload: payload,
        metadata: .init(payload: payload, source: "assistant", origin: .agent, rootID: "forged"))
    await #expect(throws: CommunicationError.unauthorized) { try await agent.receive(forged) }
    await #expect(throws: HarnessError.notRunning) {
        try await agent.openCapture(sessionID: UUID().uuidString)
    }
    await agent.stop()
}

@Test(.actionCatalog) func nativeCaptureTerminationCannotDisableNewerListeningConsent() async throws {
    let session = UUID().uuidString
    let speech = try SpeechPerceptionAgent(
        recognition: RecognitionFixture(text: "", includeFinal: false), vad: NativeRateVADProbe(),
        sessionID: session, interactionSessionID: session, residentListening: true,
        speechDetection: { (3, 0.5) },
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "speechPerception"), scope: UUID().uuidString,
            state: SpeechPerceptionContextState())
    )
    try await speech.start()
    let probe = PerceptionListeningProbe()
    let pump = Task { for await envelope in speech.outputs { await probe.record(envelope) } }
    try await speech.receive(ListeningIntent().input(sessionID: session))
    try await speech.receive(SpeechCaptureEnded(revision: 1).input(sessionID: session))
    await #expect(throws: HarnessError.notRunning) {
        try await speech.openCapture(sessionID: UUID().uuidString)
    }
    try await speech.receive(ListeningIntent().input(sessionID: session))
    try await speech.receive(SpeechCaptureEnded(revision: 1).input(sessionID: session))
    try await speech.openCapture(sessionID: UUID().uuidString)
    await speech.stop()
    await pump.value
    let values = await probe.values
    #expect(values.map(\.enabled) == [true, false, true])
}

@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: [false, true])
func completedASRContinuesWithoutAcknowledgmentAndPlaybackUsesRouteCapability(fullDuplex: Bool) async throws {
    let session = UUID().uuidString
    let epoch = UUID().uuidString
    let origin = ContinuousClock.now
    let speech = try SpeechPerceptionAgent(
        recognition: RecognitionFixture(text: "你好", includeFinal: true), vad: EndpointVAD(),
        sessionID: session, interactionSessionID: session, residentListening: true,
        speechDetection: { (3, 0.5) },
        context: try AgentContextRepository(
            agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState()))
    try await speech.start()
    let probe = PerceptionListeningProbe()
    let pump = Task { for await envelope in speech.outputs { await probe.record(envelope) } }
    _ = try await speech.setListening(enabled: true, sessionID: session)
    try await speech.openCapture(sessionID: epoch)
    await speech.setCaptureDuplex(fullDuplex)

    func frame(_ speaking: Bool, sequence: UInt64) throws -> AgentInput {
        let samples = [Float](repeating: speaking ? 0.1 : 0, count: speaking ? 1536 : 12800)
        let timestamp = Double(sequence / 2) * 1.2 + (speaking ? 0 : 0.096)
        return AgentInput(
            id: UUID().uuidString, sessionID: epoch,
            payload: .audio(
                try syntheticAudioInput(
                    samples: samples.withUnsafeBytes { Data($0) }, sampleRate: 16000,
                    sequence: sequence, timestamp: timestamp, capturedAt: origin + .seconds(timestamp))))
    }
    try await processMicrophoneFixture(frame(true, sequence: 0), using: speech)
    #expect(await speech.acquirePlaybackAdmission() == fullDuplex)
    try await processMicrophoneFixture(frame(false, sequence: 1), using: speech)
    #expect(try await speech.admitsMicrophone(sessionID: epoch))
    #expect(await speech.acquirePlaybackAdmission())
    #expect(try await speech.admitsMicrophone(sessionID: epoch) == fullDuplex)
    if !fullDuplex {
        let capturedDuringPlayback = ContinuousClock.now
        await #expect(throws: CapabilityError.inputBusy) {
            try await processMicrophoneFixture(frame(true, sequence: 2), using: speech)
        }
        try await speech.resumeListening()
        #expect(try await !speech.admitsMicrophone(sessionID: epoch, capturedAt: capturedDuringPlayback))
        #expect(try await speech.admitsMicrophone(sessionID: epoch, capturedAt: .now))
    }
    // PCM timestamps stay contiguous within each utterance, including delayed prepared slices.
    try await processMicrophoneFixture(frame(true, sequence: 2), using: speech)
    try await processMicrophoneFixture(frame(false, sequence: 3), using: speech)
    _ = try await speech.setListening(enabled: false, sessionID: session)
    try await speech.resumeListening()
    #expect(try await !speech.admitsMicrophone(sessionID: epoch))
    await speech.stop()
    await pump.value
    #expect(await probe.finalRoots.count == 2)
    #expect(await probe.values.isEmpty)
}

/// Controlled cold resources: no model weights, native microphone or timing assumptions.
private struct ColdVoiceGate: Sendable {
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    func wait() async throws {
        entered.continuation.yield(())
        for await _ in release.stream { break }
        try Task.checkCancellation()
    }
    func open() { release.continuation.yield(()) }
}

private actor ColdVoiceRecognition: SpeechRecognitionCapability {
    nonisolated let availability: CapabilityAvailability = .available
    nonisolated let gate = ColdVoiceGate()
    private(set) var received = Data()
    private let emitsPreview: Bool
    init(emitsPreview: Bool = false) { self.emitsPreview = emitsPreview }

    func transcribe(_ request: SpeechRecognitionRequest) async throws -> SpeechRecognitionSession {
        try await gate.wait()
        let pair = InferenceSession<TranscriptionEvent>.make(
            context: request.context, limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        return SpeechRecognitionSession(
            output: pair.session, format: request.format,
            sendAudio: { [self, emitsPreview] frame in
                if await append(frame.data), emitsPreview {
                    try pair.emitter.yield(
                        TranscriptionEvent(segmentID: "cold", revision: 0, text: "cold", isFinal: false))
                }
            },
            finishInput: {
                try pair.emitter.yield(
                    TranscriptionEvent(segmentID: "cold", revision: 1, text: "cold-start", isFinal: true))
                pair.emitter.finish()
            })
    }
    private func append(_ data: Data) -> Bool {
        let isFirst = received.isEmpty
        received.append(data)
        return isFirst
    }
}

private actor ColdVoiceActivity: VoiceActivityCapability, VoiceActivitySession {
    nonisolated let availability: CapabilityAvailability = .available
    nonisolated let gate = ColdVoiceGate()
    nonisolated let caughtUp = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private var position: Int64 = 0
    private var pending = Data()
    func detectVoiceActivity(format: ModelKit.AudioFormat) async throws -> any VoiceActivitySession {
        try await gate.wait()
        return self
    }
    func process(_ frame: ModelKit.AudioFrame) throws -> [VoiceActivityScore] {
        let windowBytes = 512 * MemoryLayout<Float>.size
        pending.append(frame.data)
        var scores: [VoiceActivityScore] = []
        var offset = 0
        while pending.count - offset >= windowBytes {
            let probability: Float = pending.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: Float.self) > 0 ? 1 : 0
            }
            scores.append(try VoiceActivityScore(startSample: position, sampleCount: 512, probability: probability))
            offset += windowBytes
            position += 512
        }
        pending.removeFirst(offset)
        if position == 128_000 { caughtUp.continuation.yield(()) }
        return scores
    }
    func finish() -> [VoiceActivityScore] { [] }
    func reset() {
        position = 0
        pending.removeAll()
    }
    func cancel() {}
}

@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: [false, true])
func noTranscriptEndpointEndsTheUtteranceAndRearmsAfterQuiet(includeFinal: Bool) async throws {
    let vad = ColdVoiceActivity()
    vad.gate.open()
    let session = UUID().uuidString
    let context = try AgentContextRepository(
        agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState())
    let speech = try SpeechPerceptionAgent(
        recognition: RecognitionFixture(text: "停下", includeFinal: includeFinal), vad: vad,
        sessionID: session, interactionSessionID: session, speechDetection: { (3, 0.5) }, context: context)
    let finalTexts = Mutex([String]())
    let ended = Mutex(0)
    try await speech.start()
    let pump = Task {
        for await envelope in speech.outputs {
            guard case .communication(let action) = envelope.output else { continue }
            if let recognition = action.message.content(as: SpeechRecognition.self), recognition.kind == .final {
                if recognition.text.isEmpty {
                    ended.withLock { $0 += 1 }
                } else {
                    finalTexts.withLock { $0.append(recognition.text) }
                }
            }
        }
    }
    defer { pump.cancel() }
    var sequence: UInt64 = 0
    func send(_ value: Float) async throws {
        let samples = [Float](repeating: value, count: 512)
        let audio = try syntheticAudioInput(
            samples: samples.withUnsafeBytes { Data($0) }, sampleRate: 16000,
            sequence: sequence, timestamp: Double(sequence) * 0.032)
        sequence += 1
        try await processMicrophoneFixture(
            .init(id: UUID().uuidString, sessionID: session, payload: .audio(audio)), using: speech)
    }
    for _ in 0..<63 { try await send(0.1) }
    #expect(try await context.snapshot().state.phase == "speaking")
    for _ in 0..<20 {
        try await send(0.1)
        if try await context.snapshot().state.phase == "listening" { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(try await context.snapshot().state.phase == "listening")
    for _ in 0..<100 {
        if finalTexts.withLock({ !$0.isEmpty }) || ended.withLock({ $0 > 0 }) { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(finalTexts.withLock { $0 } == (includeFinal ? ["停下"] : []))
    #expect(ended.withLock { $0 } == (includeFinal ? 0 : 1))
    for _ in 0..<16 { try await send(0.1) }
    #expect(try await context.snapshot().state.utteranceCount == 1)
    for _ in 0..<5 { try await send(0) }
    for _ in 0..<5 { try await send(0.1) }
    #expect(try await context.snapshot().state.utteranceCount == 2)
    await speech.stop()
    await pump.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func coldVADAndASRPreserveRecordedPrefixAndJoinLiveAudioInOrder() async throws {
    let recognition = ColdVoiceRecognition(emitsPreview: true)
    let vad = ColdVoiceActivity()
    let root = UUID().uuidString
    let epoch = UUID().uuidString
    let microphone = NativeMicrophoneFixture()
    let speech = try SpeechPerceptionAgent(
        recognition: recognition, vad: vad, sessionID: root, interactionSessionID: root, residentListening: true,
        microphoneInput: microphone,
        speechDetection: { (3, 0.5) },
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "speechPerception"), scope: UUID().uuidString,
            state: SpeechPerceptionContextState())
    )
    let final = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(1))
    try await speech.start()
    let output = Task {
        for await envelope in speech.outputs {
            if case .communication(let action) = envelope.output,
                case .transcript(let text, final: true)? = action.message.perception
            {
                final.continuation.yield(text)
            }
        }
    }
    try await speech.receive(ListeningIntent(enabled: true).input(sessionID: root))
    try await speech.openCapture(sessionID: epoch)
    try await speech.startInput(sessionID: epoch)
    var expected = Data()
    func packet(_ sequence: UInt64, silent: Bool = false) throws -> MicrophoneFrame {
        let samples = [Float](repeating: silent ? 0 : Float(sequence + 1) / 100, count: 4000)
        return MicrophoneFrame(
            samples: samples, sampleRate: 16000,
            sequence: sequence, timestamp: Double(sequence) / 4)
    }
    // Eight seconds, uniquely marked by packet, exceeds both previous PCM queue bounds.
    for sequence: UInt64 in 0..<32 {
        let input = try packet(sequence)
        expected.append(input.samples.withUnsafeBytes { Data($0) })
        try microphone.capture.send(input)
        if sequence == 0 {
            var entered = vad.gate.entered.stream.makeAsyncIterator()
            await entered.next()
        }
    }
    #expect(await speech.status().queuedInputs == 0)
    vad.gate.open()
    var recognizing = recognition.gate.entered.stream.makeAsyncIterator()
    await recognizing.next()
    var caughtUp = vad.caughtUp.stream.makeAsyncIterator()
    await caughtUp.next()
    #expect(await recognition.received.isEmpty)
    recognition.gate.open()
    // Live input follows the buffered prefix through exactly the same model session.
    let live = try packet(32)
    expected.append(live.samples.withUnsafeBytes { Data($0) })
    try microphone.capture.send(live)
    for sequence: UInt64 in 33..<37 { try microphone.capture.send(packet(sequence, silent: true)) }
    var result = final.stream.makeAsyncIterator()
    #expect(await result.next() == "cold-start")
    let received = await recognition.received
    #expect(received.prefix(expected.count) == expected)
    #expect(received.dropFirst(expected.count).allSatisfy { $0 == 0 })
    await speech.stop()
    await output.value
    #expect(await speech.status().queuedInputs == 0)
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func cancellingColdRecognitionClearsBufferedPrefixBeforeNextTurn() async throws {
    let recognition = ColdVoiceRecognition()
    let turn = SpeechRecognitionTurn(recognition: recognition, sessionID: UUID().uuidString) { _ in }
    try await turn.enqueue([.audio([sampleFrame()])])
    var entered = recognition.gate.entered.stream.makeAsyncIterator()
    await entered.next()
    let window = try ModelKit.AudioFrame(
        floatSamples: Array(repeating: 0, count: 512), format: sampleFrame().format, sequence: 1, timestamp: 0.032)
    try await turn.enqueue([.audio(Array(repeating: window, count: 64))])
    #expect(await !turn.reachedNoTextEndpoint)
    await turn.cancel()
    recognition.gate.open()
    #expect(await recognition.received.isEmpty)
    await #expect(throws: CapabilityError.sessionClosed) { try await turn.finish() }
    let next = SpeechRecognitionTurn(recognition: recognition, sessionID: UUID().uuidString) { _ in }
    let samples: [Float] = [0.25, 0.5]
    let frame = try ModelKit.AudioFrame(
        data: samples.withUnsafeBytes { Data($0) },
        format: ModelKit.AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32), sequence: 0, timestamp: 0)
    recognition.gate.open()
    try await next.enqueue([.audio([frame]), .end(.silence)])
    #expect(try await next.finish() == "cold-start")
    #expect(await recognition.received == frame.data)
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func coldRecognitionRejectsOverflowWithoutDroppingPreviouslyQueuedPCM() async throws {
    let recognition = ColdVoiceRecognition()
    let turn = SpeechRecognitionTurn(recognition: recognition, sessionID: UUID().uuidString) { _ in }
    try await turn.enqueue([.audio([sampleFrame()])])
    var entered = recognition.gate.entered.stream.makeAsyncIterator()
    await entered.next()
    let samples = [Float](repeating: 0.25, count: 16000)
    let data = samples.withUnsafeBytes { Data($0) }
    let frames = try (0..<30).map { sequence in
        try ModelKit.AudioFrame(
            data: data, format: ModelKit.AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32),
            sequence: UInt64(sequence + 1), timestamp: Double(sequence + 1))
    }
    try await turn.enqueue([.audio(frames)])
    await #expect(throws: CapabilityError.bufferOverflow) { try await turn.enqueue([.audio([sampleFrame()])]) }
    recognition.gate.open()
    #expect(try await turn.finish() == "cold-start")
    let received = await recognition.received
    #expect(received.count == 480_000 * 4 + 320)
    #expect(received.prefix(320) == Data(repeating: 0, count: 320))
    #expect(received.dropFirst(320) == frames.reduce(into: Data()) { $0.append($1.data) })
}

@Test(.actionCatalog) func nativeMicrophoneQueueRejectsPacket65AndTerminates() async throws {
    let source = NativeMicrophoneFixture()
    let input = try await source.listenCapture()
    let frame = MicrophoneFrame(samples: [0], sampleRate: 16000, sequence: 0)
    for _ in 0..<64 { #expect(try source.capture.send(frame)) }
    #expect(throws: AudioIOError.overflow) { try source.capture.send(frame) }
    var iterator = input.frames.makeAsyncIterator()
    for _ in 0..<64 { #expect(try await iterator.next() != nil) }
    await #expect(throws: AudioIOError.overflow) { try await iterator.next() }
    #expect(!source.capture.isActive)
}

@Test @MainActor func spectrumOffMainMatchesSynchronousAndRejectsCancelledWork() async throws {
    let samples = (0..<AudioSpectrum.sampleCount).map { index in
        Float(sin(Double(index) * 2 * .pi * 440 / 16000))
    }
    let expected = AudioSpectrum.measure(samples, sampleRate: 16000)
    let actual = try await AudioSpectrum.measureOffMain(samples, sampleRate: 16000)
    #expect(actual == expected)
    let cancelled = Task { @MainActor in
        try await AudioSpectrum.measureOffMain(samples, sampleRate: 16000)
    }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
}

@Test(.actionCatalog, .timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
func speechRolesOwnIndependentIslandsAndJoinShutdown(initiallyUnavailable: Bool) async throws {
    let state = UI.IslandState()
    state.setAvailable(!initiallyUnavailable)
    let service = IslandPresentationService(state: state)
    let manager = AgentManager()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, configurations: AgentConfigurations.all())
    let input = InputGateway(manager: manager, policy: policy)
    let assembly = try BehaviorAssembly(capabilityModules: [IslandModule(island: service)])
    let output = await OutputGateway(
        manager: manager, requests: input, tools: assembly.tools, policy: policy, sink: { _ in })
    let session = UUID().uuidString
    let perception = try SpeechPerceptionAgent(
        recognition: RecognitionFixture(text: "", includeFinal: false), vad: NativeRateVADProbe(),
        sessionID: session, interactionSessionID: session, residentListening: true,
        speechDetection: { (3, 0.5) },
        context: AgentContextRepository(
            agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState()))
    let synthesis = AssistantSpeechOutput()
    try await synthesis.configure(synthesis: SynthesisFixture(probe: VoiceProbe()), store: AudioCache())
    try await manager.register(perception)
    let assistant = try AssistantAgent(
        stateContext: publicStateFixture(), speechOutput: synthesis, chat: FixedTextChat(),
        context: AgentContextRepository(agent: .assistant, scope: UUID().uuidString, state: AssistantContextState()))
    try await manager.register(assistant)
    try await manager.start(perception.descriptor.id)
    try await manager.start(.assistant)
    await perception.bindPresentation(try await output.consumer(for: perception))
    await synthesis.bindPresentation(try await output.consumer(for: assistant))
    func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }
    _ = try await perception.setListening(enabled: true, sessionID: session)
    try await perception.openCapture(sessionID: session)
    if initiallyUnavailable {
        let failureDeadline = ContinuousClock.now + .seconds(4)
        while await perception.presentationFailure == nil, ContinuousClock.now < failureDeadline { await Task.yield() }
        #expect(await perception.presentationFailure != nil)
        #expect(await perception.status().lifecycle == .running)
        state.setAvailable(true)
    }
    try await wait { state.activities.contains { $0.owner.hasPrefix("speechPerception:") } }
    let listening = try #require(state.activities.first { $0.owner.hasPrefix("speechPerception:") })
    #expect(listening.content.title == "Listening")
    try await perception.pause()
    try await wait { state.activities.isEmpty }
    try await perception.resume()
    try await wait { state.activities.contains { $0.owner.hasPrefix("speechPerception:") } }
    let resumed = try #require(state.activities.first { $0.owner.hasPrefix("speechPerception:") })
    let first = try await synthesis.prepare(
        text: "第一段播报", input: .init(id: UUID().uuidString, sessionID: session, payload: .text("speak")))
    try await synthesis.preparePlayback(audioID: first)
    await synthesis.playbackChanged(audioID: first, active: true)
    try await wait { state.headerActivity?.owner.hasPrefix("assistant:") == true }
    #expect(state.headerActivity?.content.secondary == .spectrum)
    let second = try await synthesis.prepare(
        text: "生产完成不能撤下仍在播放的活动",
        input: .init(id: UUID().uuidString, sessionID: session, payload: .text("speak")))
    let productionDeadline = ContinuousClock.now + .seconds(4)
    while await synthesis.snapshot().processed < 2, ContinuousClock.now < productionDeadline { await Task.yield() }
    #expect(await synthesis.snapshot().processed == 2)
    #expect(state.headerActivity?.owner.hasPrefix("assistant:") == true)
    #expect(state.activities.contains { $0.id == resumed.id && $0.content.secondary == resumed.content.secondary })
    try await synthesis.preparePlayback(audioID: second)
    await synthesis.playbackChanged(audioID: second, active: true)
    await synthesis.playbackChanged(audioID: first, active: false)
    #expect(state.headerActivity?.owner.hasPrefix("assistant:") == true)
    await synthesis.playbackChanged(audioID: second, active: false)
    try await wait { state.headerActivity?.owner.hasPrefix("speechPerception:") == true }
    #expect(await perception.acquirePlaybackAdmission())
    try await wait { state.activities.isEmpty }
    try await perception.resumeListening()
    try await wait { state.headerActivity?.owner.hasPrefix("speechPerception:") == true }
    let third = try await synthesis.prepare(
        text: "第三段播报", input: .init(id: UUID().uuidString, sessionID: session, payload: .text("speak")))
    try await synthesis.preparePlayback(audioID: third)
    await synthesis.playbackChanged(audioID: third, active: true)
    try await wait { state.headerActivity?.owner.hasPrefix("assistant:") == true }
    await perception.stop()
    #expect(!state.activities.contains { $0.owner.hasPrefix("speechPerception:") })
    #expect(state.activities.contains { $0.owner.hasPrefix("assistant:") })
    await synthesis.stop()
    #expect(state.activities.isEmpty)
    await synthesis.playbackChanged(audioID: "late", active: true)
    #expect(state.activities.isEmpty)
    #expect(await perception.presentationFailure == nil)
    #expect(await synthesis.snapshot().presentationFailure == nil)
    await output.shutdown()
    await state.stop()
}

@Test(.actionCatalog) func nativeVoiceProcessingKeepsRecognitionActiveDuringReplies() async throws {
    let echo = try AudioEchoCancellationSelection.select(voiceProcessing: { true })
    let fullDuplex = AudioCaptureDuplexSelection.supportsFullDuplex(echoCancellation: echo)
    #expect(fullDuplex)
    try await completedASRContinuesWithoutAcknowledgmentAndPlaybackUsesRouteCapability(fullDuplex: fullDuplex)
}

@Test(arguments: [1, 8, 16])
func configurableSpeechOnsetRetainsCandidate(windows: Int) throws {
    var policy = SpeechBoundaryPolicy()
    let format = try ModelKit.AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32)
    let frame = try ModelKit.AudioFrame(
        data: Data(repeating: 0, count: 512 * 4), format: format, sequence: 0, timestamp: 0)
    for _ in 0..<20 {
        _ = policy.consume(frame, probability: 0.64, threshold: 0.65, onsetWindows: windows)
        #expect(!policy.isSpeaking)
    }
    for _ in 0..<(windows - 1) {
        _ = policy.consume(frame, probability: 0.65, threshold: 0.65, onsetWindows: windows)
        #expect(!policy.isSpeaking)
    }
    _ = policy.consume(frame, probability: 0.65, threshold: 0.65, onsetWindows: windows)
    #expect(policy.isSpeaking)
    let retained = policy.streamEvents.reduce(0) { total, event in
        if case .audio(let frames) = event { return total + frames.reduce(0) { $0 + $1.sampleCount } }
        return total
    }
    #expect(retained >= windows * 512)
}

@Test func nativePlaybackSnapshotSeparatesPlaybackFromItsEchoTail() {
    let time = ContinuousClock.now
    let end = time + .milliseconds(10)
    let snapshot = AudioPlaybackSnapshot(periods: [.init(start: time, end: end)])
    #expect(!snapshot.isPlaying(at: time - .milliseconds(1), tail: .milliseconds(200)))
    #expect(snapshot.isPlaying(at: time))
    #expect(!snapshot.isPlaying(at: end))
    #expect(snapshot.isPlaying(at: end + .milliseconds(199), tail: .milliseconds(200)))
    #expect(!snapshot.isPlaying(at: end + .milliseconds(200), tail: .milliseconds(200)))
    let bounded = AudioPlaybackSnapshot(
        periods: (0..<40).map {
            .init(start: time + .seconds($0), end: time + .seconds($0) + .milliseconds(1))
        })
    #expect(!bounded.isPlaying(at: time))
    #expect(bounded.isPlaying(at: time + .seconds(39)))
}

@Test func speechPlaybackOnsetIsStricterWithoutCuttingConfirmedSpeech() throws {
    var policy = SpeechBoundaryPolicy()
    let frame = try ModelKit.AudioFrame(
        data: Data(repeating: 0, count: 512 * 4),
        format: ModelKit.AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32), sequence: 0, timestamp: 0)
    for _ in 0..<20 {
        _ = policy.consume(frame, probability: 0.7, threshold: 0.65, onsetWindows: 10, onsetThreshold: 0.8)
    }
    #expect(!policy.isSpeaking)
    for _ in 0..<10 {
        _ = policy.consume(frame, probability: 0.9, threshold: 0.65, onsetWindows: 10, onsetThreshold: 0.8)
    }
    #expect(policy.isSpeaking)
    for _ in 0..<30 {
        #expect(policy.consume(frame, probability: 0.7, threshold: 0.65, onsetWindows: 10, onsetThreshold: 0.8) == nil)
    }
    #expect(policy.isSpeaking)
}

@Test func speechOnsetPolicyRaisesOnlyTheOnsetGateDuringPlayback() {
    let idle = SpeechOnsetPolicy(windows: 8, threshold: 0.65, playing: false)
    #expect(idle.threshold == 0.65 && idle.onsetThreshold == 0.65 && idle.onsetWindows == 8)
    let playing = SpeechOnsetPolicy(windows: 8, threshold: 0.65, playing: true)
    #expect(playing.threshold == 0.65)
    #expect(abs(playing.onsetThreshold - 0.8) < 0.0001)
    #expect(playing.onsetWindows == 10)
    let capped = SpeechOnsetPolicy(windows: 16, threshold: 0.9, playing: true)
    #expect(capped.onsetThreshold == 0.95 && capped.onsetWindows == 16)
    // Invalid window counts reach the segmenter unchanged, where they are rejected explicitly.
    #expect(SpeechOnsetPolicy(windows: 0, threshold: 0.65, playing: true).onsetWindows == 0)
}

@Test func audioFrameFloatSamplesRoundTripWithLevel() throws {
    let format = try ModelKit.AudioFormat(sampleRate: 16000, channels: 1, encoding: .float32)
    let frame = try ModelKit.AudioFrame(
        floatSamples: [0.5, -0.5, 0.5, -0.5], format: format, sequence: 3, timestamp: 1)
    #expect(frame.floatSamples == [0.5, -0.5, 0.5, -0.5])
    #expect(abs(frame.rmsDecibels + 6.0206) < 0.001)
    let silence = try ModelKit.AudioFrame(floatSamples: [0, 0], format: format, sequence: 4, timestamp: 1)
    #expect(silence.rmsDecibels == -120)
}

@Test func speechSuppressionHysteresisRequiresConsecutiveWindows() {
    var policy = SpeechEnergyBands()
    func window(_ level: Float) -> [Float] { Array(repeating: pow(10, level / 20), count: 512) }

    #expect(policy.observe(window(-32), hasVoice: true) == nil)
    #expect(policy.observe(window(-37), hasVoice: true) == nil)
    #expect(policy.observe(window(-32), hasVoice: true) == nil)
    #expect(policy.observe(window(-32), hasVoice: true) == .medium)
    for _ in 0..<4 { #expect(policy.observe(window(-37), hasVoice: true) == nil) }
    #expect(policy.energy == .medium)

    for _ in 0..<5 { #expect(policy.observe(window(-16), hasVoice: true) == nil) }
    #expect(policy.observe(window(-16), hasVoice: true) == .high)
    for _ in 0..<4 { #expect(policy.observe(window(-23), hasVoice: true) == nil) }
    #expect(policy.energy == .high)
    for _ in 0..<4 { #expect(policy.observe(window(-28), hasVoice: true) == nil) }
    #expect(policy.observe(window(-28), hasVoice: true) == .medium)
}

@Test func speechOutputTracksNativePlaybackForTheOwningReply() async throws {
    let session = UUID().uuidString
    let input = AgentInput(id: UUID().uuidString, sessionID: session, payload: .text("reply"))
    let (speech, store, _, invocation) = try await preparedSpeech(text: "reply", input: input, probe: VoiceProbe())
    let id = try #require(invocation.call.parameters["audioID"])
    try await speech.preparePlayback(audioID: id)
    await speech.playbackChanged(audioID: id, active: true)
    #expect(await speech.isPlaying(sessionID: session) == true)
    #expect(await speech.isPlaying(sessionID: "other") == false)
    await speech.cancel(input: input)
    await speech.playbackChanged(audioID: id, active: false)
    #expect(await speech.isPlaying(sessionID: session) != true)
    await speech.endSession()
    await speech.playbackChanged(audioID: id, active: true)
    #expect(await speech.isPlaying(sessionID: session) != true)
    await speech.stop()
    await store.shutdown()
}

@Test func playbackSuppressionGainUsesLinearInterpolation() {
    let steps = AudioPlaybackRamp.steps
    #expect(AudioPlaybackRamp.volume(from: 0.35, to: 0, step: 0) == 0.35)
    #expect(AudioPlaybackRamp.volume(from: 0.35, to: 0, step: steps / 2) == 0.175)
    #expect(AudioPlaybackRamp.volume(from: 0.35, to: 0, step: steps) == 0)
    #expect(AudioPlaybackRamp.volume(from: 0, to: 1, step: steps / 2) == 0.5)
    #expect(AudioPlaybackRamp.volume(from: 0, to: 1, step: steps) == 1)
}

@Test func cancellingPreparedSpeechRevokesPlaybackBeforeFirstPCM() async throws {
    let input = AgentInput(id: "old-reply", sessionID: "speech", payload: .text("reply"))
    let (speech, store, _, invocation) = try await preparedSpeech(text: "reply", input: input, probe: VoiceProbe())
    let id = try #require(invocation.call.parameters["audioID"])
    try await speech.preparePlayback(audioID: id)
    await speech.cancel(input: input)
    let owner = AudioCache.Owner(source: "assistant", session: input.sessionID, input: input.id)
    #expect((try? await store.validate(id, owner: owner)) == nil)
    await #expect(throws: CancellationError.self) { try await speech.preparePlayback(audioID: id) }
    await speech.playbackChanged(audioID: id, active: false)
    #expect(await speech.isPlaying(sessionID: input.sessionID) != true)
    await speech.stop()
}

/// Feeds one spoken utterance (speech, then silence) so the endpoint finishes it.
private func speakOneUtterance(_ speech: SpeechPerceptionAgent, epoch: String, from base: UInt64 = 0) async throws {
    let origin = ContinuousClock.now
    func frame(_ speaking: Bool, sequence: UInt64) throws -> AgentInput {
        let samples = [Float](repeating: speaking ? 0.1 : 0, count: speaking ? 1536 : 12800)
        let timestamp = Double(sequence / 2) * 1.2 + (speaking ? 0 : 0.096)
        return AgentInput(
            id: UUID().uuidString, sessionID: epoch,
            payload: .audio(
                try syntheticAudioInput(
                    samples: samples.withUnsafeBytes { Data($0) }, sampleRate: 16000,
                    sequence: sequence, timestamp: timestamp, capturedAt: origin + .seconds(timestamp))))
    }
    try await processMicrophoneFixture(frame(true, sequence: base), using: speech)
    try await processMicrophoneFixture(frame(false, sequence: base + 1), using: speech)
}

private func listeningFixture() async throws -> (
    SpeechPerceptionAgent, String, PerceptionListeningProbe, Task<Void, Never>
) {
    let session = UUID().uuidString
    let epoch = UUID().uuidString
    let speech = try SpeechPerceptionAgent(
        recognition: RecognitionFixture(text: "你好", includeFinal: true), vad: EndpointVAD(),
        sessionID: session, interactionSessionID: session, residentListening: true,
        speechDetection: { (3, 0.5) },
        context: try AgentContextRepository(
            agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState()))
    try await speech.start()
    let probe = PerceptionListeningProbe()
    let pump = Task { for await envelope in speech.outputs { await probe.record(envelope) } }
    _ = try await speech.setListening(enabled: true, sessionID: session)
    try await speech.openCapture(sessionID: epoch)
    return (speech, epoch, probe, pump)
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func speechPerceptionPublishesActivityAndFinalText() async throws {
    let (speech, epoch, probe, pump) = try await listeningFixture()
    try await speakOneUtterance(speech, epoch: epoch)
    await speech.stop()
    await pump.value
    #expect(await probe.finalRoots.count == 1)
    let kinds = await probe.activities.map(\.kind)
    let started = try #require(kinds.firstIndex(of: .onsetStarted))
    #expect(started < (try #require(kinds.firstIndex(of: .onsetConfirmed))))
    #expect(await probe.activities.filter { $0.kind == .onsetConfirmed }.allSatisfy { $0.utterance?.isEmpty == false })
}

@Test(.actionCatalog) func speechContractsValidateTheirPayloads() throws {
    let contracts = try AgentContracts.communication
    for kind in SpeechActivity.Kind.allCases {
        let activity = SpeechActivity(
            kind, generation: "g", utterance: [.onsetConfirmed, .energyChanged].contains(kind) ? "u" : nil,
            sequence: kind == .vadProgress ? 4 : nil,

            energy: kind == .energyChanged ? .high : nil)
        #expect(try contracts.validatedSize(activity.message()) > 0)
    }
    for failure in [nil, "recognition failed"] {
        let terminal = SpeechRecognition(.final, text: "", generation: "g", failure: failure)
        #expect(try contracts.validatedSize(terminal.message()) > 0)
    }
    let keyword = SpeechKeywordMatch(
        generation: "g", utterance: "u", label: "en-stop", keyword: "stop", onset: .zero, matchedAt: .milliseconds(64))
    #expect(try contracts.validatedSize(keyword.message()) > 0)
    let invalidKeyword = SpeechKeywordMatch(
        generation: "g", utterance: "u", label: "en-stop", keyword: "stop", onset: .zero, matchedAt: .milliseconds(64),
        detection: .init(
            modelID: "fixture", modelName: nil, inferenceDuration: .milliseconds(-1), completedAt: .milliseconds(70)))
    #expect(throws: CommunicationError.invalidPayload) { try contracts.validatedSize(invalidKeyword.message()) }
    #expect(throws: CommunicationError.invalidPayload) {
        try contracts.validatedSize(SpeechActivity(.onsetConfirmed, generation: "g").message())
    }
    #expect(throws: CommunicationError.invalidPayload) {
        try contracts.validatedSize(SpeechActivity(.captureStarted, generation: "").message())
    }
}

@Test(
    .actionCatalog, .timeLimit(.minutes(1)),
    arguments: [
        (false, false, true), (true, false, true), (true, true, true), (true, false, false), (true, true, false),
    ])
func speechEnergyFollowsConfirmedVADWindows(fullDuplex: Bool, playing: Bool, loudWindowsAreVoice: Bool) async throws {
    let session = UUID().uuidString
    let microphone = NativeMicrophoneFixture()
    let speech = try SpeechPerceptionAgent(
        recognition: RecognitionFixture(text: "继续", includeFinal: true),
        vad: EndpointVAD(voicedWindows: loudWindowsAreVoice ? 17 : 5),
        sessionID: session, interactionSessionID: session, residentListening: true, microphoneInput: microphone,
        speechDetection: { (1, 0.5) },
        context: AgentContextRepository(
            agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState()))
    let events = Mutex([AgentMessage]())
    let pump = Task {
        for await envelope in speech.outputs {
            if case .communication(let action) = envelope.output {
                events.withLock { $0.append(action.message) }
            }
        }
    }
    try await speech.start()
    _ = try await speech.setListening(enabled: true, sessionID: session)
    try await speech.openCapture(sessionID: session)
    await speech.setCaptureDuplex(fullDuplex)
    await speech.bindMicrophoneGeneration("capture")
    let origin = ContinuousClock.now - .seconds(2)
    if playing { await microphone.setPlayback(.init(periods: [.init(start: origin - .milliseconds(100))])) }
    for index in 0..<42 {
        if index == 11, playing, loudWindowsAreVoice {
            // A pause ends audible output, but the same confirmed utterance still drives recovery.
            await microphone.setPlayback(
                .init(periods: [.init(start: origin - .milliseconds(100), end: origin + .milliseconds(352))]))
        }
        let amplitude: Float = index < 5 ? 0.05 : index < 11 ? 0.25 : index < 17 ? 0.05 : 0
        try await speech.processMicrophone(
            MicrophoneFrame(
                samples: Array(repeating: amplitude, count: 512), sampleRate: 16000,
                sequence: UInt64(index), timestamp: Double(index) * 0.032,
                capturedAt: origin + .milliseconds(index * 32)),
            sessionID: session, captureGeneration: "capture")
    }
    await speech.stop()
    await pump.value
    let messages = events.withLock { $0 }
    let activities = messages.compactMap { $0.content(as: SpeechActivity.self) }
    let expected: [SpeechActivity.Energy] = loudWindowsAreVoice ? [.medium, .high, .medium, .low] : [.medium, .low]
    #expect(activities.compactMap(\.energy) == expected)
    let final = try #require(messages.firstIndex { $0.content(as: SpeechRecognition.self)?.kind == .final })
    let started = try #require(messages.firstIndex { $0.content(as: SpeechActivity.self)?.kind == .captureStarted })
    let candidate = try #require(messages.firstIndex { $0.content(as: SpeechActivity.self)?.kind == .onsetStarted })
    let onset = try #require(messages.firstIndex { $0.content(as: SpeechActivity.self)?.kind == .onsetConfirmed })
    let first = try #require(messages.firstIndex { $0.content(as: SpeechActivity.self)?.energy == .medium })
    let recovered = try #require(messages.firstIndex { $0.content(as: SpeechActivity.self)?.energy == .low })
    let stopped = try #require(messages.firstIndex { $0.content(as: SpeechActivity.self)?.kind == .captureStopped })
    #expect(started < candidate && candidate < onset && onset < first && first < recovered)
    #expect(recovered < final && final < stopped)
}

@Test(.actionCatalog, arguments: [true, false])
func perceptionPublishesKeywordFromIdleCaptureWhenEnabled(enabled: Bool) async throws {
    let session = UUID().uuidString
    let keyword = MatchingKeywordModel(minimumSamples: 4096)
    let speech = try SpeechPerceptionAgent(
        recognition: RecognitionFixture(text: "停下", includeFinal: true), vad: EndpointVAD(),
        keywordSpotting: keyword, sessionID: session, interactionSessionID: session, residentListening: true,
        speechDetection: { (3, 0.5) },
        context: AgentContextRepository(
            agent: .speechPerception, scope: UUID().uuidString,
            state: SpeechPerceptionContextState()))
    let observations = Mutex([SpeechKeywordMatch]())
    let pump = Task {
        for await envelope in speech.outputs {
            if case .communication(let action) = envelope.output,
                let match = action.message.content(as: SpeechKeywordMatch.self)
            {
                #expect(envelope.sessionID == session && envelope.turn?.id == match.utterance)
                observations.withLock { $0.append(match) }
            }
        }
    }
    try await speech.start()
    _ = try await speech.setListening(enabled: true, sessionID: session)
    try await speech.openCapture(sessionID: session)
    await speech.setCaptureDuplex(true)
    await speech.bindMicrophoneGeneration("capture", keywordDetection: (enabled, 0.25))
    let origin = ContinuousClock.now - .milliseconds(256)
    for index in 0..<8 {
        try await speech.processMicrophone(
            MicrophoneFrame(
                samples: Array(repeating: index < 3 ? 0.1 : 0, count: 512), sampleRate: 16000,
                sequence: UInt64(index), timestamp: Double(index) * 0.032,
                capturedAt: origin + .milliseconds(index * 32)),
            sessionID: session, captureGeneration: "capture")
    }
    if enabled {
        for _ in 0..<200 where observations.withLock({ $0.isEmpty }) {
            try await Task.sleep(for: .milliseconds(2))
        }
        let match = try #require(observations.withLock { $0.first })
        #expect(match.keyword == "停下" && match.label == "zh-stop")
        #expect(match.onset == SpeechSignalClock.offset(at: origin))
        #expect(match.matchedAt == SpeechSignalClock.offset(at: origin + .milliseconds(256)))
        let detection = try #require(match.detection)
        #expect(detection.modelID == MatchingKeywordModel.metadata.model.modelID)
        #expect(detection.modelName == MatchingKeywordModel.metadata.model.displayName)
        #expect(detection.inferenceDuration == MatchingKeywordModel.metadata.inferenceDuration)
        #expect(detection.completedAt >= match.matchedAt)
        #expect(try JSONDecoder().decode(SpeechKeywordMatch.self, from: JSONEncoder().encode(match)) == match)
    } else {
        #expect(await keyword.received == 0)
        #expect(observations.withLock { $0.isEmpty })
    }
    await speech.stop()
    await pump.value
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func speechFactsTravelOneWayThroughGatewayEvents() async throws {
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, configurations: AgentConfigurations.all())
    let session = UUID().uuidString
    let manager = AgentManager()
    let assistant = ObservationRecorder(id: "assistant")
    let speech = try SpeechPerceptionAgent(
        recognition: RecognitionFixture(text: "你好", includeFinal: true), vad: EndpointVAD(), sessionID: session,
        interactionSessionID: session, residentListening: true,
        speechDetection: { (3, 0.5) },
        context: try AgentContextRepository(
            agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState()))
    try await manager.register(assistant, sessionID: session)
    await assistant.start()
    try await manager.register(speech, sessionID: session)
    let input = InputGateway(manager: manager, policy: policy)
    let scheduler = ChannelScheduler(registry: try testActionRegistry(handlers: [:]))
    let output = await OutputGateway(
        manager: manager, requests: input, tools: ToolRegistry(), actions: scheduler, policy: policy, sink: { _ in })
    _ = try await output.consumer(for: assistant)
    try await speech.bind(output.messaging(for: .speechPerception))
    try await speech.start()
    let outputTask = Task {
        for await envelope in fixtureOutputs(speech) { try await output.dispatch(envelope) }
    }
    let configuration = try AgentConfigurations.load(named: "SpeechPerception")
    #expect(configuration.communication.subscriptions.isEmpty)
    let generation = "capture"
    let turn = AgentTurn(id: "u1", ordinal: 1)
    let activity = SpeechActivity(.onsetConfirmed, generation: generation, utterance: turn.id)
    let parent = AgentInput(id: UUID().uuidString, sessionID: session, payload: .event("speech"), turn: turn)
    let match = SpeechKeywordMatch(
        generation: generation, utterance: turn.id, label: "en-stop", keyword: "stop",
        onset: .zero, matchedAt: .milliseconds(32))
    try await speech.communicate(activity.message(), parent: parent)
    try await speech.communicate(match.message(), parent: parent)
    try await speech.communicate(
        SpeechRecognition(.partial, text: "sto", generation: generation).message(), parent: parent)
    try await speech.communicate(
        SpeechRecognition(.final, text: "stop", generation: generation).message(), parent: parent)
    for _ in 0..<2000 where await assistant.inputs.count < 3 { try await Task.sleep(for: .milliseconds(2)) }
    let delivered = await assistant.inputs
    #expect(
        Set(delivered.compactMap(\.metadata.topic)) == [
            SpeechActivity.channel, SpeechKeywordMatch.channel, SpeechRecognition.channel,
        ])
    #expect(delivered.allSatisfy { $0.sessionID == session && $0.metadata.source == "speechPerception" })
    #expect(delivered.compactMap(\.payload.speechRecognition).map(\.kind) == [.final])
    await speech.stop()
    try await outputTask.value
    await scheduler.shutdown()
    await manager.stopAll()
}

@Test(.actionCatalog, .timeLimit(.minutes(1)))
func duplexCapturePolicyUsesNativeEchoCancellation() async throws {
    let (speech, _, _, pump) = try await listeningFixture()
    await speech.setCaptureDuplex(false)
    await speech.setCaptureDuplex(true)
    #expect(await speech.acquirePlaybackAdmission())
    await speech.stop()
    await pump.value
}

import ActionRuntime
import Actions
import AgentCore
import Agents
import Foundation
import Gateway
import ModelKit
import PlatformKit
import Synchronization
import Testing
import ToolRuntime

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

private func voiceActions(probe: VoiceProbe, producesAudio: Bool = true) -> ChannelScheduler {
    ChannelScheduler(
        registry: ActionRegistry(handlers: [
            ActionPath(module: "Speech", function: "speak"): { invocation in
                try await SpeechActions.speak(
                    invocation: invocation, synthesis: SynthesisFixture(probe: probe, producesAudio: producesAudio),
                    play: { frame, _ in await probe.played(frame) })
            },
            ActionPath(module: "UI", function: "print"): { invocation in
                try await UIActions.print(invocation: invocation) { text, _ in await probe.displayed(text) }
            },
        ]))
}

@Test func voiceGatewaysRoundTripThroughSayAndPrint() async throws {
    let manager = AgentManager()
    let agent = try AssistantAgent(chat: FixedTextChat(text: "固定回复"))
    try await manager.register(agent)
    try await agent.start()
    let probe = VoiceProbe()
    let gateway = InputGateway(manager: manager, recognition: RecognitionFixture(text: "你好", includeFinal: true))
    let sessionID = UUID()
    let turn = LiveSpeechInput(requests: gateway, sessionID: sessionID) { _ in }
    try await turn.enqueue([.audio([sampleFrame()]), .end(.silence)])
    let text = try await turn.finish()
    await probe.displayed(text)
    let report = try await gateway.submit(AgentInput(sessionID: sessionID, payload: .text(text)))
    #expect(report.delivered == [.assistant])
    #expect(await agent.status().processedInputs == 1)
    let response = OutputGateway(
        manager: manager, requests: gateway, tools: ToolRegistry(), actions: voiceActions(probe: probe)
    ) { _ in }
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
}

@Test func partialRecognitionNeverSubmitsAgentInput() async throws {
    let manager = AgentManager()
    let agent = try AssistantAgent(chat: FixedTextChat())
    try await manager.register(agent)
    try await agent.start()
    let gateway = InputGateway(manager: manager, recognition: RecognitionFixture(text: "", includeFinal: false))
    let turn = LiveSpeechInput(requests: gateway, sessionID: UUID()) { _ in }
    try await turn.enqueue([.audio([sampleFrame()]), .end(.silence)])
    #expect(try await turn.finish().isEmpty)
    #expect(await agent.status().processedInputs == 0)
    await agent.stop()
}

@Test func speechFailureDoesNotInventSuccess() async throws {
    let manager = AgentManager()
    try await manager.register(AssistantAgent(chat: FixedTextChat()))
    let requests = InputGateway(manager: manager)
    await #expect(throws: CapabilityError.self) {
        _ = try await requests.openSpeechStream(sessionID: UUID())
    }
    let probe = VoiceProbe()
    let responses = OutputGateway(
        manager: manager, requests: requests, tools: ToolRegistry(),
        actions: voiceActions(probe: probe, producesAudio: false)
    ) { _ in }
    let input = AgentInput(sessionID: UUID(), payload: .text("你好"))
    try await responses.dispatch(
        OutputEnvelope(
            source: .assistant, input: input,
            output: .actionCall(expectedActionCall(name: "say", parameters: ["text": "回复"])))
    )
    await #expect(throws: CapabilityError.self) {
        try await responses.dispatch(
            OutputEnvelope(source: .assistant, input: input, output: .control("assistant.finished")))
    }
    #expect(await probe.audio.isEmpty)
    await responses.shutdown()
}

@Test func cancellingDuringPlaybackDoesNotDeliverLaterAudio() async throws {
    let manager = AgentManager()
    try await manager.register(AssistantAgent(chat: FixedTextChat()))
    let probe = VoiceProbe()
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let actions = ChannelScheduler(
        registry: ActionRegistry(handlers: [
            ActionPath(module: "Speech", function: "speak"): { invocation in
                try await SpeechActions.speak(invocation: invocation, synthesis: SynthesisFixture(probe: probe)) {
                    frame, _ in
                    entered.continuation.yield(())
                    try await Task.sleep(for: .seconds(30))
                    await probe.played(frame)
                }
            }
        ]))
    let responses = OutputGateway(
        manager: manager, requests: InputGateway(manager: manager), tools: ToolRegistry(), actions: actions
    ) { _ in }
    let input = AgentInput(sessionID: UUID(), payload: .text("你好"))
    try await responses.dispatch(
        OutputEnvelope(
            source: .assistant, input: input,
            output: .actionCall(expectedActionCall(name: "say", parameters: ["text": "回复"])))
    )
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    await responses.cancel(sessionID: input.sessionID)
    #expect(await probe.audio.isEmpty)
    await responses.shutdown()
    entered.continuation.finish()
}

@Test func longVoiceTurnRecognizesChunksButSubmitsOnlyOnce() async throws {
    let manager = AgentManager()
    let agent = try AssistantAgent(chat: FixedTextChat())
    try await manager.register(agent)
    try await agent.start()
    let gateway = InputGateway(manager: manager, recognition: RecognitionFixture(text: "一段", includeFinal: true))
    let id = UUID()
    let turn = LiveSpeechInput(requests: gateway, sessionID: id) { _ in }
    try await turn.enqueue([.audio([sampleFrame()]), .end(.maximumDuration)])
    try await turn.enqueue([.audio([sampleFrame()]), .end(.silence)])
    let text = try await turn.finish()
    #expect(text == "一段 一段")
    #expect(await agent.status().processedInputs == 0)
    _ = try await gateway.submit(AgentInput(sessionID: id, payload: .text(text)))
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
    let gateway = InputGateway(manager: AgentManager(), recognition: model)
    let turn = LiveSpeechInput(requests: gateway, sessionID: UUID()) { _ in }
    try await turn.enqueue([.audio([sampleFrame()]), .end(.maximumDuration)])
    var started = model.started.stream.makeAsyncIterator()
    _ = await started.next()
    // A single oversized admission fails regardless of worker scheduling.
    await #expect(throws: CapabilityError.self) {
        try await turn.enqueue(Array(repeating: .end(.maximumDuration), count: 129))
    }
    await turn.cancel()
    await #expect(throws: CapabilityError.self) { try await turn.finish() }
    let next = LiveSpeechInput(requests: gateway, sessionID: UUID()) { _ in }
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
    let gateway = InputGateway(manager: manager, recognition: LiveRecognitionFixture())
    let previews = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(8))
    let turn = LiveSpeechInput(requests: gateway, sessionID: UUID()) { previews.continuation.yield($0) }
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
    let gateway = InputGateway(manager: AgentManager(), recognition: LiveRecognitionFixture())
    let previews = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(8))
    let turn = LiveSpeechInput(requests: gateway, sessionID: UUID()) { previews.continuation.yield($0) }
    try await turn.enqueue([.audio([sampleFrame()])])
    var iterator = previews.stream.makeAsyncIterator()
    _ = await iterator.next()
    await turn.cancel()
    await #expect(throws: CapabilityError.self) { try await turn.enqueue([.end(.silence)]) }
    let next = LiveSpeechInput(requests: gateway, sessionID: UUID()) { _ in }
    try await next.enqueue([.audio([sampleFrame()]), .end(.silence)])
    #expect(try await next.finish() == "你好世界")
    previews.continuation.finish()
}

@Test(arguments: [nil, "", " \n\t", String(repeating: "界", count: 667)])
func textActionsRejectInvalidParametersBeforeSideEffects(_ text: String?) async throws {
    let probe = VoiceProbe()
    let input = AgentInput(sessionID: UUID(), payload: .text("request"))
    for module in ["Speech", "UI"] {
        let call = ActionCall(
            actionPath: ActionPath(module: module, function: module == "Speech" ? "speak" : "print"),
            channel: module, parameters: text.map { ["text": $0] } ?? [:])
        let invocation = ActionInvocation(
            envelope: OutputEnvelope(source: .assistant, input: input, output: .actionCall(call)), call: call)
        await #expect(throws: ActionExecutionError.invalidText) {
            if module == "Speech" {
                try await SpeechActions.speak(invocation: invocation, synthesis: SynthesisFixture(probe: probe)) {
                    frame, _ in await probe.played(frame)
                }
            } else {
                try await UIActions.print(invocation: invocation) { value, _ in await probe.displayed(value) }
            }
        }
    }
    #expect(await probe.spokenText.isEmpty)
    #expect(await probe.displayedText.isEmpty)
    #expect(await probe.audio.isEmpty)
}

@Test func textActionsPreserveAcceptedTextAtByteLimit() async throws {
    let text = " " + String(repeating: "界", count: 666) + " "
    #expect(text.utf8.count == 2000)
    let probe = VoiceProbe()
    let input = AgentInput(sessionID: UUID(), payload: .text("request"))
    for alias in ["say", "print"] {
        let call = expectedActionCall(name: alias, parameters: ["text": text])
        let invocation = ActionInvocation(
            envelope: OutputEnvelope(source: .assistant, input: input, output: .actionCall(call)), call: call)
        if alias == "say" {
            try await SpeechActions.speak(invocation: invocation, synthesis: SynthesisFixture(probe: probe)) {
                frame, _ in await probe.played(frame)
            }
        } else {
            try await UIActions.print(invocation: invocation) { value, _ in await probe.displayed(value) }
        }
    }
    #expect(await probe.spokenText == [text])
    #expect(await probe.displayedText == [text])
    #expect(await probe.audio.count == 1)
}

@Test(arguments: [nil, "", "Happy", "unknown"])
func expressionsRejectInvalidEmotionBeforePresentation(_ emotion: String?) async throws {
    let probe = VoiceProbe()
    let input = AgentInput(sessionID: UUID(), payload: .text("request"))
    let call = ActionCall(
        actionPath: ActionPath(module: "UI", function: "express"), channel: "Display",
        parameters: emotion.map { ["emotion": $0] } ?? [:])
    let invocation = ActionInvocation(
        envelope: OutputEnvelope(source: .assistant, input: input, output: .actionCall(call)), call: call)
    await #expect(throws: UIActions.ExpressionError.invalidEmotion) {
        try await UIActions.express(invocation: invocation) { value, _ in await probe.displayed(value) }
    }
    #expect(await probe.displayedText.isEmpty)
}

@Test func expressionPresentationPropagatesCancellation() async throws {
    let input = AgentInput(sessionID: UUID(), payload: .text("request"))
    let call = ActionCall(
        actionPath: ActionPath(module: "UI", function: "express"), channel: "Display", parameters: ["emotion": "happy"])
    let invocation = ActionInvocation(
        envelope: OutputEnvelope(source: .assistant, input: input, output: .actionCall(call)), call: call)
    await #expect(throws: CancellationError.self) {
        try await UIActions.express(invocation: invocation) { _, _ in throw CancellationError() }
    }
}

@Test func smileUsesParameterizedExpressionPresentation() async throws {
    let probe = VoiceProbe()
    let input = AgentInput(sessionID: UUID(), payload: .text("request"))
    let call = expectedActionCall(name: "express", parameters: ["emotion": "smile"])
    let invocation = ActionInvocation(
        envelope: OutputEnvelope(source: .assistant, input: input, output: .actionCall(call)), call: call)
    try await UIActions.express(invocation: invocation) { value, _ in await probe.displayed(value) }
    #expect(await probe.displayedText == ["🙂"])
    #expect(await probe.spokenText.isEmpty)
}

import AgentCore
import Foundation
import Gateway
import ModelKit
import PlatformKit
import Testing
import ToolRuntime

@testable import Agents

private func soundPCM(direction: (Float, Float, Float), count: Int, amplitude: Float = 0.1) -> [Float] {
    (0..<count).flatMap { index in
        let w = index.isMultiple(of: 2) ? amplitude : -amplitude
        return [w, w * direction.1, w * direction.2, w * direction.0]
    }
}

private func soundEstimates(_ samples: [Float], rate: Int, timestamp: Double = 0, estimator: inout SoundSourceEstimator)
    throws
    -> [SoundSourceObservation]
{
    var values: [SoundSourceObservation] = []
    for index in stride(from: 0, to: samples.count, by: 4) {
        if let value = try estimator.consume(
            w: samples[index], y: samples[index + 1], z: samples[index + 2], x: samples[index + 3],
            sampleRate: rate, timestamp: timestamp + Double(index / 4) / Double(rate))
        {
            values.append(value)
        }
    }
    return values
}

@Test(arguments: [(Float(1), Float(0), Float(0)), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)])
func soundSourceAxesUseACNOrderAndRadians(_ axis: (Float, Float, Float)) throws {
    var estimator = SoundSourceEstimator()
    let value = try #require(
        soundEstimates(soundPCM(direction: axis, count: 1600), rate: 16000, estimator: &estimator).first)
    try value.validate()
    #expect(value.state == .active)
    #expect(abs(value.quality - 1) < 0.000001)
    let direction = try #require(value.direction)
    #expect(abs(direction.x - Double(axis.0)) < 0.000001)
    #expect(abs(direction.y - Double(axis.1)) < 0.000001)
    #expect(abs(direction.z - Double(axis.2)) < 0.000001)
}

@Test(arguments: [8000, 11025, 16000, 44100, 48000, 192000])
func soundSourceCadenceAndQuietClearUseSamples(_ rate: Int) throws {
    var estimator = SoundSourceEstimator()
    let size = (rate + 9) / 10
    let active = try soundEstimates(soundPCM(direction: (1, 0, 0), count: size), rate: rate, estimator: &estimator)
    #expect(active.count == 1)
    #expect(active[0].duration >= 0.1 && active[0].duration <= 0.101)
    let quiet = try soundEstimates(Array(repeating: Float(0), count: size * 8), rate: rate, estimator: &estimator)
    #expect(quiet.map(\.state) == [.uncertain, .inactive])
    #expect(quiet.allSatisfy { $0.direction == nil })
}

@Test func soundSourceRejectsNonFiniteAndResetsRateAndWindow() throws {
    var estimator = SoundSourceEstimator()
    _ = try soundEstimates(soundPCM(direction: (1, 0, 0), count: 800), rate: 16000, estimator: &estimator)
    #expect(throws: SoundSourceValidationError.self) {
        try estimator.consume(w: .nan, y: 0, z: 0, x: 0, sampleRate: 16000, timestamp: 0)
    }
    estimator.reset()
    #expect(try soundEstimates(soundPCM(direction: (0, 1, 0), count: 800), rate: 16000, estimator: &estimator).isEmpty)
    let result = try soundEstimates(soundPCM(direction: (0, 0, 1), count: 800), rate: 8000, estimator: &estimator)
    #expect(result.count == 1 && result[0].direction?.z == 1)
}

@Test func soundSourceMixedOppositeDirectionsAreUncertainAndPacketIndependent() throws {
    var mixed: [Float] = []
    for index in 0..<1600 {
        let w: Float = index.isMultiple(of: 2) ? 0.1 : -0.1
        mixed += [w, 0, 0, index < 800 ? w : -w]
    }
    var estimator = SoundSourceEstimator()
    let result = try soundEstimates(mixed, rate: 16000, estimator: &estimator)
    #expect(result.first?.state == .uncertain)
    #expect(result.first?.direction == nil)
    var fragmented = SoundSourceEstimator()
    var fragmentedValues: [SoundSourceObservation] = []
    for offset in stride(from: 0, to: mixed.count, by: 28) {
        fragmentedValues += try soundEstimates(
            Array(mixed[offset..<min(offset + 28, mixed.count)]), rate: 16000, timestamp: Double(offset / 4) / 16000,
            estimator: &fragmented)
    }
    // Absolute timestamps and DSP/cadence are independent of packet boundaries.
    #expect(fragmentedValues == result)
}

@Test func soundSourceTransportValidatesAllChannelsAndRetainsNativeDuration() throws {
    let values = soundPCM(direction: (0, 1, 0), count: 1600)
    let input = try AudioInput(
        samples: values.withUnsafeBytes { Data($0) }, sampleRate: 16000, sequence: 1, timestamp: 0,
        layout: .firstOrderAmbisonicsACNSN3D)
    #expect(input.sampleCount == 6400 && input.frameCount == 1600)
    #expect(throws: AudioValidationError.self) {
        try AudioInput(
            samples: Data(repeating: 0, count: 20), sampleRate: 16000, sequence: 1, timestamp: 0,
            layout: .firstOrderAmbisonicsACNSN3D)
    }
    let microphone = MicrophoneFrame(
        samples: values, sampleRate: 16000, sequence: 1, layout: .firstOrderAmbisonicsACNSN3D)
    #expect(microphone.duration == 0.1)
    #expect(microphone.omnidirectionalSamples.count == 1600)
    #expect(abs(microphone.rms - 0.1) < 0.000001)
    let message = AgentMessage.soundSource(
        .init(
            state: .active, direction: .init(x: 0, y: 1, z: 0), quality: 1, rms: 0.1,
            timestamp: 0, duration: 0.1))
    #expect(message.contract == "sound.source")
    #expect(try JSONDecoder().decode(PerceptionMessage.self, from: message.encodedContent()) == message.perception)
    try SoundSourceObservation(state: .unavailable, timestamp: 0, duration: 0).validate()
    #expect(throws: SoundSourceValidationError.self) {
        try SoundSourceObservation(state: .inactive, direction: .init(x: 1, y: 0, z: 0), timestamp: 0, duration: 0)
            .validate()
    }
}

private actor SoundVADSession: VoiceActivitySession {
    private var position: Int64 = 0
    private(set) var frames: [AudioFrame] = []
    func process(_ frame: AudioFrame) throws -> [VoiceActivityScore] {
        frames.append(frame)
        defer { position += Int64(frame.sampleCount) }
        return [try VoiceActivityScore(startSample: position, sampleCount: frame.sampleCount, probability: 0)]
    }
    func finish() -> [VoiceActivityScore] { [] }
    func reset() { position = 0 }
    func cancel() {}
}
private struct SoundVAD: VoiceActivityCapability {
    let session: SoundVADSession
    var availability: CapabilityAvailability { .available }
    func detectVoiceActivity(format: AudioFormat) -> any VoiceActivitySession { session }
}
private struct NoSoundASR: SpeechRecognitionCapability {
    var availability: CapabilityAvailability { .available }
    func transcribe(_ request: SpeechRecognitionRequest) throws -> SpeechRecognitionSession {
        throw CapabilityError.unavailable("Non-speech test must not open ASR")
    }
}
private struct ForbiddenSoundVAD: VoiceActivityCapability {
    var availability: CapabilityAvailability { .unavailable(reason: "No diagnostic model") }
    func detectVoiceActivity(format: AudioFormat) throws -> any VoiceActivitySession {
        throw CapabilityError.unavailable("Direction-only detection must not open VAD")
    }
}
private actor SoundPublications {
    private(set) var values: [SoundSourceObservation] = []
    func append(_ value: SoundSourceObservation) { values.append(value) }
}
private func soundInput(
    _ samples: [Float], session: UUID, sequence: UInt64, timestamp: Double,
    layout: AudioChannelLayout = .firstOrderAmbisonicsACNSN3D,
    capturedAt: ContinuousClock.Instant = .now
) throws -> AgentInput {
    let audio = try AudioInput(
        samples: samples.withUnsafeBytes { Data($0) }, sampleRate: 16000, sequence: sequence, timestamp: timestamp,
        layout: layout, capturedAt: capturedAt)
    return AgentInput(
        sessionID: session, payload: .audio(audio),
        metadata: InputMetadata(payload: .audio(audio), source: "phone.microphone"))
}
private func waitForSound(_ predicate: () async -> Bool) async throws {
    for _ in 0..<2000 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting for sound perception")
}

@Test func soundSourceOnlyDiagnosticCrossesGatewaysWithoutModelsOrPresentationGrants() async throws {
    let configuration = try AgentConfigurations.load(named: "SpeechPerception")
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, externalSources: ["phone.microphone"],
        configurations: [configuration])
    let manager = AgentManager()
    let session = UUID()
    let values = SoundPublications()
    let speech = try SpeechPerceptionAgent(
        recognition: NoSoundASR(), vad: ForbiddenSoundVAD(), sessionID: session,
        configuration: configuration, mode: .soundSourceOnly)
    #expect(speech.descriptor.capabilities.internalTools.isEmpty)
    #expect(speech.descriptor.capabilities.internalActions.isEmpty)
    try await manager.register(speech, sessionID: session)
    let input = InputGateway(manager: manager, policy: policy)
    let output = OutputGateway(
        manager: manager, requests: input, tools: ToolRegistry(), policy: policy,
        observedContracts: ["sound.source"],
        observeEvent: { input in
            if case .soundSource(let value)? = input.payload.perception { await values.append(value) }
        }, sink: { _ in Issue.record("Diagnostic must not emit presentation output") })
    try await speech.bind(output.messaging(for: .speechPerception))
    try await speech.start()
    _ = try await input.publish(
        soundInput(Array(repeating: 0, count: 1600), session: session, sequence: 0, timestamp: 0, layout: .mono))
    try await waitForSound { await values.values.count == 1 }
    #expect(await values.values.first?.state == .unavailable)
    _ = try await input.publish(
        soundInput(soundPCM(direction: (0, 1, 0), count: 1600), session: session, sequence: 1, timestamp: 0.1))
    try await waitForSound { await values.values.count == 2 }
    #expect(await values.values.last?.direction?.y == 1)
    #expect(await speech.status().lifecycle == .running)
    await speech.stop()
    var outputCount = 0
    for await _ in speech.outputs { outputCount += 1 }
    #expect(outputCount == 0)
    await output.shutdown()
}

@Test func soundSourceNonSpeechBroadcastDoesNotRequireSubscribersOrOpenASR() async throws {
    let session = UUID()
    let vad = SoundVADSession()
    let values = SoundPublications()
    let agent = try SpeechPerceptionAgent(recognition: NoSoundASR(), vad: SoundVAD(session: vad), sessionID: session)
    try await agent.bind(
        AgentMessaging { message, _, _ in
            if case .soundSource(let value)? = message.perception { await values.append(value) }
            return DeliveryReport()
        })
    try await agent.start()
    try await agent.receive(
        soundInput(soundPCM(direction: (0, 1, 0), count: 1600), session: session, sequence: 0, timestamp: 0))
    try await waitForSound { await values.values.count == 1 }
    #expect(await values.values.first?.state == .active)
    #expect(await agent.status().lifecycle == .running)
    try await waitForSound { await vad.frames.reduce(0) { $0 + $1.sampleCount } == 1600 }
    let frames = await vad.frames
    #expect(frames.reduce(0) { $0 + $1.sampleCount } == 1600)
    #expect(frames.allSatisfy { $0.format.channels == 1 && $0.format.sampleRate == 16000 })
    let rms = frames.flatMap { frame in
        frame.data.withUnsafeBytes { bytes in
            (0..<frame.sampleCount).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
    }
    #expect(rms.allSatisfy { abs(abs($0) - 0.1) < 0.000001 })
    await agent.stop()
    await #expect(throws: HarnessError.notRunning) {
        try await agent.receive(
            soundInput(soundPCM(direction: (1, 0, 0), count: 1600), session: session, sequence: 1, timestamp: 0.1))
    }
    #expect(await values.values.count == 1)
}

@Test func soundSourceMonoIsUnavailableAndRejectedPublicationDoesNotStopRecognition() async throws {
    let session = UUID()
    let values = SoundPublications()
    let agent = try SpeechPerceptionAgent(
        recognition: NoSoundASR(), vad: SoundVAD(session: SoundVADSession()), sessionID: session)
    try await agent.bind(
        AgentMessaging { message, _, _ in
            if case .soundSource(let value)? = message.perception { await values.append(value) }
            return DeliveryReport(rejected: [AgentID(rawValue: "futureSubscriber"): "full"])
        })
    try await agent.start()
    try await agent.receive(
        soundInput(Array(repeating: 0, count: 1600), session: session, sequence: 0, timestamp: 0, layout: .mono))
    try await waitForSound { await values.values.count == 1 }
    #expect(await values.values.first?.state == .unavailable)
    #expect(await agent.status().lifecycle == .running)
    try await waitForSound { await agent.soundPublicationRejections == 1 }
    #expect(await agent.soundPublicationRejections == 1)
    await agent.stop()
}

@Test func soundSourceBroadcastCrossesGatewaysWithBoundIdentityAndCaptureDeadline() async throws {
    let speechConfiguration = try AgentConfigurations.load(named: "SpeechPerception")
    let listenerData: [String: Any] = [
        "version": 5, "id": "soundListener", "actions": [:], "tools": [],
        "communication": [
            "inputs": [["contract": "sound.source", "version": 1, "kind": "observation"]],
            "subscriptions": [["contract": "sound.source", "source": "speechPerception", "topic": "sound.source"]],
            "publications": [], "sends": [],
        ],
    ]
    let listener = try AgentConfiguration(
        contracts: AgentContracts.communication, data: JSONSerialization.data(withJSONObject: listenerData))
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, externalSources: ["phone.microphone"],
        configurations: [speechConfiguration, listener])
    let manager = AgentManager()
    let session = UUID()
    let speech = try SpeechPerceptionAgent(
        recognition: NoSoundASR(), vad: SoundVAD(session: SoundVADSession()), sessionID: session)
    let recorder = ObservationRecorder(id: "soundListener")
    try await manager.register(speech, sessionID: session)
    try await manager.register(recorder, sessionID: session)
    await recorder.start()
    let input = InputGateway(manager: manager, policy: policy)
    let output = OutputGateway(manager: manager, requests: input, tools: ToolRegistry(), policy: policy, sink: { _ in })
    try await speech.bind(output.messaging(for: .speechPerception))
    try await speech.start()
    let capturedAt = ContinuousClock.now.advanced(by: .milliseconds(-200))
    let parent = try soundInput(
        soundPCM(direction: (0, -1, 0), count: 1600), session: session, sequence: 1, timestamp: 0,
        capturedAt: capturedAt)
    let admitted = try await input.publish(parent)
    #expect(admitted.delivered == [.speechPerception])
    try await waitForSound { await recorder.inputs.count == 1 }
    let received = try #require(await recorder.inputs.first)
    #expect(received.metadata.source == "speechPerception")
    #expect(received.metadata.parentID == parent.id && received.metadata.rootID == parent.metadata.rootID)
    #expect(received.sessionID == session && received.turn == nil)
    #expect(received.metadata.deadline <= capturedAt.advanced(by: .milliseconds(600)))
    #expect(received.payload.perception?.contract == "sound.source")
    #expect(try AgentContracts.communication["sound.source"]?.lifetime == 0.5)
    await manager.stopAll()
    await output.shutdown()
}

private actor SoundPublicationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func markStarted() { started = true }
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@Test func soundSourceSlowSubscriberKeepsOnlyLatestPendingDirection() async throws {
    let session = UUID()
    let values = SoundPublications()
    let gate = SoundPublicationGate()
    let vad = SoundVADSession()
    let agent = try SpeechPerceptionAgent(recognition: NoSoundASR(), vad: SoundVAD(session: vad), sessionID: session)
    try await agent.bind(
        AgentMessaging { message, _, _ in
            if case .soundSource(let value)? = message.perception {
                if !(await gate.started) { await gate.wait() }
                await values.append(value)
            }
            return DeliveryReport()
        })
    try await agent.start()
    try await agent.receive(
        soundInput(soundPCM(direction: (1, 0, 0), count: 1600), session: session, sequence: 0, timestamp: 0))
    try await waitForSound { await gate.started }
    for index in 1...5 {
        try await agent.receive(
            soundInput(
                soundPCM(direction: (0, 1, 0), count: 1600), session: session,
                sequence: UInt64(index), timestamp: Double(index) * 0.1))
    }
    try await waitForSound { await vad.frames.count == 6 }
    #expect(await agent.soundPublicationReplacements >= 4)
    await gate.release()
    try await waitForSound { await values.values.count == 2 }
    #expect(await values.values.last?.direction?.y == 1)
    await agent.stop()
}

@Test func soundSourceOldCaptureNeverPublishesDirection() async throws {
    let session = UUID()
    let values = SoundPublications()
    let agent = try SpeechPerceptionAgent(
        recognition: NoSoundASR(), vad: SoundVAD(session: SoundVADSession()), sessionID: session)
    try await agent.bind(
        AgentMessaging { message, _, _ in
            if case .soundSource(let value)? = message.perception { await values.append(value) }
            return DeliveryReport()
        })
    try await agent.start()
    try await agent.receive(
        soundInput(
            soundPCM(direction: (1, 0, 0), count: 1600), session: session, sequence: 0,
            timestamp: 0, capturedAt: .now.advanced(by: .seconds(-1))))
    try await waitForSound { await agent.status().processedInputs > 0 }
    await agent.stop()
    #expect(await values.values.isEmpty)
}

@Test func soundSourceNoGatewayRecipientsIsAnOrdinaryDeliveryOutcome() async throws {
    let manager = AgentManager()
    let session = UUID()
    let speech = try SpeechPerceptionAgent(
        recognition: NoSoundASR(), vad: SoundVAD(session: SoundVADSession()), sessionID: session)
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, externalSources: ["phone.microphone"],
        configurations: [AgentConfigurations.load(named: "SpeechPerception")])
    try await manager.register(speech, sessionID: session)
    let input = InputGateway(manager: manager, policy: policy)
    let output = OutputGateway(manager: manager, requests: input, tools: ToolRegistry(), policy: policy, sink: { _ in })
    let port = try await output.messaging(for: .speechPerception)
    try await speech.bind(port)
    try await speech.start()
    _ = try await input.publish(
        soundInput(soundPCM(direction: (1, 0, 0), count: 1600), session: session, sequence: 1, timestamp: 0))
    try await waitForSound { await port.history.snapshot().contains { $0.contract == "sound.source" } }
    #expect(await speech.status().lifecycle == .running)
    #expect(await speech.soundPublicationRejections == 0)
    await manager.stopAll()
    await output.shutdown()
}

private struct SoundRecognition: SpeechRecognitionCapability {
    var availability: CapabilityAvailability { .available }
    func transcribe(_ request: SpeechRecognitionRequest) throws -> SpeechRecognitionSession {
        let pair = InferenceSession<TranscriptionEvent>.make(
            context: request.context, limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        return SpeechRecognitionSession(
            output: pair.session, format: request.format, sendAudio: { _ in },
            finishInput: {
                try pair.emitter.yield(TranscriptionEvent(segmentID: UUID(), revision: 1, text: "hello", isFinal: true))
                pair.emitter.finish()
            })
    }
}
private actor SoundEndpointSession: VoiceActivitySession {
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
private struct SoundEndpoint: VoiceActivityCapability {
    var availability: CapabilityAvailability { .available }
    func detectVoiceActivity(format: AudioFormat) -> any VoiceActivitySession { SoundEndpointSession() }
}

@Test func soundSourceReplyGateClearsDirectionAndResumeStartsANewWindow() async throws {
    let session = UUID()
    let values = SoundPublications()
    let finals = SoundPublications()
    let speech = try SpeechPerceptionAgent(recognition: SoundRecognition(), vad: SoundEndpoint(), sessionID: session)
    try await speech.bind(
        AgentMessaging { message, _, _ in
            if case .soundSource(let value)? = message.perception { await values.append(value) }
            if case .transcript(_, true)? = message.perception {
                await finals.append(.init(state: .inactive, timestamp: 0, duration: 0))
                return DeliveryReport(delivered: [.assistant])
            }
            return DeliveryReport()
        })
    try await speech.start()
    let outputs = Task { for await _ in speech.outputs {} }
    try await speech.receive(
        soundInput(soundPCM(direction: (1, 0, 0), count: 1600), session: session, sequence: 0, timestamp: 0))
    try await waitForSound { await values.values.contains { $0.state == .active } }
    for index in 1...4 {
        try await speech.receive(
            soundInput(
                Array(repeating: 0, count: 3200 * 4), session: session, sequence: UInt64(index),
                timestamp: 0.1 + Double(index - 1) * 0.2))
        try await waitForSound { await speech.status().processedInputs >= index + 1 }
    }
    try await waitForSound { await finals.values.count == 1 }
    try await waitForSound { await values.values.last?.state == .inactive }
    await #expect(throws: CapabilityError.inputBusy) {
        try await speech.receive(
            soundInput(soundPCM(direction: (0, 1, 0), count: 800), session: session, sequence: 5, timestamp: 0.9))
    }
    try await speech.resumeListening()
    let previousCount = await values.values.count
    try await speech.receive(
        soundInput(soundPCM(direction: (0, 1, 0), count: 800), session: session, sequence: 6, timestamp: 1))
    try await waitForSound { await speech.status().processedInputs >= 6 }
    #expect(await values.values.count == previousCount)
    try await speech.receive(
        soundInput(soundPCM(direction: (0, 1, 0), count: 800), session: session, sequence: 7, timestamp: 1.05))
    try await waitForSound { await values.values.last?.direction?.y == 1 }
    await speech.stop()
    await outputs.value
}

@Test func soundSourceStopCancelsAndJoinsAnInFlightPublisher() async throws {
    let session = UUID()
    let values = SoundPublications()
    let gate = SoundPublicationGate()
    let speech = try SpeechPerceptionAgent(
        recognition: NoSoundASR(), vad: SoundVAD(session: SoundVADSession()), sessionID: session)
    try await speech.bind(
        AgentMessaging { message, _, _ in
            if case .soundSource(let value)? = message.perception {
                await gate.markStarted()
                // A cancellable slow recipient must be joined without publishing after stop.
                try await Task.sleep(for: .seconds(30))
                await values.append(value)
            }
            return DeliveryReport()
        })
    try await speech.start()
    try await speech.receive(
        soundInput(soundPCM(direction: (1, 0, 0), count: 1600), session: session, sequence: 0, timestamp: 0))
    try await waitForSound { await gate.started }
    await speech.stop()
    #expect(await speech.status().lifecycle == .stopped)
    #expect(await values.values.isEmpty)
}

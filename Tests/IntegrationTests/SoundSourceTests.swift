import Actions
import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import ModelKit
import StorageCore
import Testing
import UI

@testable import Agents
@testable import PlatformKit

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

@Test(
    .actionCatalog,
    arguments: [(Float(1), Float(0), Float(0)), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)])
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

@Test(.actionCatalog, arguments: [8000, 11025, 16000, 44100, 48000, 192000])
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

@Test(.actionCatalog) func soundSourceRejectsNonFiniteAndResetsRateAndWindow() throws {
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

@Test(.actionCatalog) func soundSourceMixedOppositeDirectionsAreUncertainAndPacketIndependent() throws {
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

@Test(.actionCatalog) func soundSourceTransportValidatesAllChannelsAndRetainsNativeDuration() throws {
    let values = soundPCM(direction: (0, 1, 0), count: 1600)
    let input = try syntheticAudioInput(
        samples: values.withUnsafeBytes { Data($0) }, sampleRate: 16000, sequence: 1, timestamp: 0,
        layout: .firstOrderAmbisonicsACNSN3D)
    #expect(input.sampleCount == 6400 && input.frameCount == 1600)
    #expect(throws: AudioValidationError.self) {
        try syntheticAudioInput(
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
    _ samples: [Float], session: String, sequence: UInt64, timestamp: Double,
    layout: AudioChannelLayout = .firstOrderAmbisonicsACNSN3D,
    capturedAt: ContinuousClock.Instant = .now
) throws -> AgentInput {
    let audio = try syntheticAudioInput(
        samples: samples.withUnsafeBytes { Data($0) }, sampleRate: 16000, sequence: sequence, timestamp: timestamp,
        layout: layout, capturedAt: capturedAt)
    return AgentInput(
        id: UUID().uuidString,
        sessionID: session, payload: .audio(audio),
        metadata: InputMetadata(
            payload: .audio(audio), source: "phone.microphone", rootID: UUID().uuidString))
}
private func waitForSound(_ predicate: () async -> Bool) async throws {
    for _ in 0..<2000 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting for sound perception")
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func soundSourceOnlyDiagnosticCrossesGatewaysWithoutModelsOrPresentationGrants()
        async throws
    {
        let original = try AgentConfigurations.load(named: "SpeechPerception")
        #expect(throws: CommunicationError.unauthorized) {
            try CommunicationPolicy(
                contracts: AgentContracts.communication,
                configurations: [original])
        }
        let configuration = try original.restrictingCommunication(
            to: ["media.audio", "sound.source"], contracts: AgentContracts.communication)
        #expect(configuration.communication.inputs.isEmpty)
        #expect(configuration.communication.subscriptions.isEmpty)
        #expect(configuration.communication.publications == ["sound.source"])
        #expect(configuration.communication.sends.isEmpty)
        #expect(original.communication.subscriptions.contains { $0.source == "assistant" })
        #expect(configuration.agentID == original.agentID && configuration.version == original.version)
        let policy = try CommunicationPolicy(
            contracts: AgentContracts.communication, configurations: [configuration])
        let session = UUID().uuidString
        let values = SoundPublications()
        let speech = try SpeechPerceptionAgent(
            recognition: NoSoundASR(), vad: ForbiddenSoundVAD(), sessionID: session,
            configuration: configuration, mode: .soundSourceOnly,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "speechPerception"), scope: UUID().uuidString,
                state: SpeechPerceptionContextState())
        )
        #expect(speech.descriptor.capabilities.internalTools.isEmpty)
        #expect(speech.descriptor.capabilities.internalActions.isEmpty)
        let root = await GatewayContainer()
        let assembly = await AgentGatewayAssembly(
            signals: root.signals, admission: root.admissionPort,
            configuration: .init(
                executor: fixtureExecutionPort(actions: []), catalog: .init(revision: UUID(), entries: [])))
        let ports = try await root.configureExecution(assembly.configuration)
        let main = await assembly.bind(ports: ports, observations: root.observations)
        try await root.start()
        let diagnostic = try await main.observations.open(
            policy: policy, observedContracts: ["sound.source"],
            observeEvent: { input in
                if case .soundSource(let value)? = input.payload.perception { await values.append(value) }
            })
        let manager = diagnostic.capabilities.manager
        let output = diagnostic.capabilities.output
        try await manager.register(speech, sessionID: session)
        try await speech.start()
        let consumer = try await output.consumer(for: speech)
        let pump = Task {
            try await IndependentOutputWorkflow.consumeSignals(speech.outputs) { envelope in
                try await consumer.execute(envelope)
            }
        }
        #expect(await manager.descriptors().map(\.id) == [.speechPerception])
        let probe = try soundInput([0], session: session, sequence: 0, timestamp: 0, layout: .mono)
        #expect(policy.destinations(for: probe).isEmpty)
        _ = try await processMicrophoneFixture(
            soundInput(Array(repeating: 0, count: 1600), session: session, sequence: 0, timestamp: 0, layout: .mono),
            using: speech)
        try await waitForSound { await values.values.count == 1 }
        #expect(await values.values.first?.state == .unavailable)
        _ = try await processMicrophoneFixture(
            soundInput(soundPCM(direction: (0, 1, 0), count: 1600), session: session, sequence: 1, timestamp: 0.1),
            using: speech)
        try await waitForSound { await values.values.count == 2 }
        #expect(await values.values.last?.direction?.y == 1)
        #expect(await speech.status().lifecycle == .running)
        await speech.stop()
        try await pump.value
        try await main.observations.close(diagnostic)
        #expect(await root.isAvailable)
        try await root.stop()
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func soundSourceNonSpeechBroadcastDoesNotRequireSubscribersOrOpenASR() async throws {
        let session = UUID().uuidString
        let vad = SoundVADSession()
        let values = SoundPublications()
        let agent = try SpeechPerceptionAgent(
            recognition: NoSoundASR(), vad: SoundVAD(session: vad), sessionID: session,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "speechPerception"), scope: UUID().uuidString,
                state: SpeechPerceptionContextState())
        )
        try await agent.bind(
            AgentMessaging { message, _, _ in
                if case .soundSource(let value)? = message.perception { await values.append(value) }
                return DeliveryReport()
            })
        try await agent.start()
        try await processMicrophoneFixture(
            soundInput(soundPCM(direction: (0, 1, 0), count: 1600), session: session, sequence: 0, timestamp: 0),
            using: agent)
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
            try await processMicrophoneFixture(
                soundInput(soundPCM(direction: (1, 0, 0), count: 1600), session: session, sequence: 1, timestamp: 0.1),
                using: agent)
        }
        #expect(await values.values.count == 1)
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog, .timeLimit(.minutes(1))) func soundSourceContextWriteFailureReportsWithoutStoppingOrSelfJoin()
        async throws
    {
        let session = UUID().uuidString
        let context = try AgentContextRepository(
            agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState(),
            persistence: .init(
                load: { nil },
                commit: { value, _ in
                    if value.records.contains(where: { $0.kind == "communication.output" }) {
                        throw CommunicationError.invalidPayload
                    }
                })
        )
        let agent = try SpeechPerceptionAgent(
            recognition: NoSoundASR(), vad: ForbiddenSoundVAD(), sessionID: session,
            mode: .soundSourceOnly, context: context)
        try await agent.start()
        try await processMicrophoneFixture(
            soundInput(Array(repeating: 0, count: 1600), session: session, sequence: 0, timestamp: 0, layout: .mono),
            using: agent)
        var iterator = agent.outputs.makeAsyncIterator()
        let output = try #require(await iterator.next())
        #expect(await agent.status().lifecycle == .running)
        if case .control(let message) = output.output {
            #expect(message.hasPrefix("agent.error: speech perception:"))
        } else {
            Issue.record("Failed context must not emit a communication Action")
        }
        await agent.stop()
        #expect(await iterator.next() == nil)
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func soundSourceMonoIsUnavailableAndRejectedPublicationDoesNotStopRecognition() async throws {
        let session = UUID().uuidString
        let values = SoundPublications()
        let agent = try SpeechPerceptionAgent(
            recognition: NoSoundASR(), vad: SoundVAD(session: SoundVADSession()), sessionID: session,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "speechPerception"), scope: UUID().uuidString,
                state: SpeechPerceptionContextState())
        )
        try await agent.bind(
            AgentMessaging { message, _, _ in
                if case .soundSource(let value)? = message.perception { await values.append(value) }
                return DeliveryReport(rejected: [AgentID(rawValue: "futureSubscriber"): "full"])
            })
        try await agent.start()
        try await processMicrophoneFixture(
            soundInput(Array(repeating: 0, count: 1600), session: session, sequence: 0, timestamp: 0, layout: .mono),
            using: agent)
        try await waitForSound { await values.values.count == 1 }
        #expect(await values.values.first?.state == .unavailable)
        #expect(await agent.status().lifecycle == .running)
        #expect(await agent.soundPublicationRejections == 0)
        await agent.stop()
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func soundSourceBroadcastCrossesGatewaysWithBoundIdentityAndCaptureDeadline() async throws {
        let speechConfiguration = try AgentConfigurations.load(named: "SpeechPerception")
        let listenerData: [String: Any] = [
            "version": 7, "id": "soundListener", "actions": [:], "tools": [],
            "communication": [
                "inputs": [["contract": "sound.source", "version": 1, "kind": "observation"]],
                "subscriptions": [["contract": "sound.source", "source": "speechPerception", "topic": "sound.source"]],
                "publications": [], "sends": [],
            ],
        ]
        let listener = try AgentConfiguration(
            contracts: AgentContracts.communication, data: JSONSerialization.data(withJSONObject: listenerData))
        let policy = try CommunicationPolicy(
            contracts: AgentContracts.communication,
            configurations: try AgentConfigurations.all().filter { $0.agentID != speechConfiguration.agentID } + [
                speechConfiguration, listener,
            ])
        let manager = AgentManager()
        let session = UUID().uuidString
        let speech = try SpeechPerceptionAgent(
            recognition: NoSoundASR(), vad: SoundVAD(session: SoundVADSession()), sessionID: session,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "speechPerception"), scope: UUID().uuidString,
                state: SpeechPerceptionContextState())
        )
        let recorder = ObservationRecorder(id: "soundListener")
        try await manager.register(speech, sessionID: session)
        try await manager.register(recorder, sessionID: session)
        await recorder.start()
        let input = InputGateway(manager: manager, policy: policy)
        let output = await OutputGateway(
            manager: manager, requests: input, tools: ToolRegistry(), policy: policy, sink: { _ in })
        try await speech.bind(output.messaging(for: .speechPerception))
        try await speech.start()
        // This test verifies routing of fresh capture; expired capture has separate rejection coverage.
        let capturedAt = ContinuousClock.now
        let parent = try soundInput(
            soundPCM(direction: (0, -1, 0), count: 1600), session: session, sequence: 1, timestamp: 0,
            capturedAt: capturedAt)
        try await processMicrophoneFixture(parent, using: speech)
        try await waitForSound { await recorder.inputs.count == 1 }
        let received = try #require(await recorder.inputs.first)
        #expect(received.metadata.source == "speechPerception")
        #expect(received.metadata.parentID != nil && received.metadata.rootID == received.metadata.parentID)
        #expect(received.sessionID == session && received.turn == nil)
        #expect(try #require(received.metadata.deadline) <= capturedAt.advanced(by: .milliseconds(600)))
        #expect(received.payload.perception?.contract == "sound.source")
        await manager.stopAll()
        await output.shutdown()
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog, .timeLimit(.minutes(1))) func directMicrophoneConsumptionPreservesNativeSequenceAcrossGating()
        async throws
    {
        let session = UUID().uuidString
        let configuration = try AgentConfigurations.load(named: "SpeechPerception").restrictingCommunication(
            to: ["sound.source"], contracts: AgentContracts.communication)
        let microphone = DirectSoundMicrophone()
        let speech = try SpeechPerceptionAgent(
            recognition: NoSoundASR(), vad: ForbiddenSoundVAD(), sessionID: session,
            configuration: configuration, mode: .soundSourceOnly, microphoneInput: microphone,
            context: try AgentContextRepository(
                agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState()))
        let parents = AsyncStream<AgentInput>.makeStream(bufferingPolicy: .bufferingOldest(1))
        try await speech.bind(
            AgentMessaging { _, parent, _ in
                parents.continuation.yield(parent)
                return DeliveryReport()
            })
        try await speech.start()
        #expect(await microphone.subscriptions == 0)
        #expect(await speech.acquirePlaybackAdmission())
        try await speech.startInput(sessionID: session)
        #expect(await microphone.subscriptions == 1)
        await #expect(throws: CapabilityError.inputBusy) { try await speech.startInput(sessionID: session) }
        try await microphone.send(9)
        try await waitForSound { await speech.suppressedMicrophonePackets == 1 }
        try await speech.resumeListening()
        try await microphone.send(10)
        var iterator = parents.stream.makeAsyncIterator()
        let received = try #require(await iterator.next())
        #expect(received.metadata.sequence == 10)
        #expect(received.sessionID == session)
        #expect(received.payload.perception?.contract == "sound.source")
        #expect(received.metadata.generation == microphone.source.generation)
        await speech.stop()
        #expect(await speech.status().lifecycle == .stopped)
    }
}

private actor DirectSoundMicrophone: AudioCaptureObserving {
    nonisolated let source = MicrophoneCapture()
    private var replacement: MicrophoneCapture?
    private(set) var subscriptions = 0
    func subscribeCapture() throws -> MicrophoneCaptureInput {
        subscriptions += 1
        return try (replacement ?? source).subscribe()
    }
    func replaceCapture() -> String {
        let capture = MicrophoneCapture()
        replacement = capture
        return capture.generation
    }
    func finishCapture(throwing error: (any Error)? = nil) { (replacement ?? source).finish(throwing: error) }
    func send(_ sequence: UInt64) throws {
        try (replacement ?? source).send(
            MicrophoneFrame(
                samples: soundPCM(direction: (1, 0, 0), count: 1600), sampleRate: 16000, sequence: sequence,
                layout: .firstOrderAmbisonicsACNSN3D, timestamp: Double(sequence) / 10))
    }
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

extension LiveRuntimeTests {
    @Test(.actionCatalog) func soundSourceSlowSubscriberDoesNotBlockFollowingDirections() async throws {
        let session = UUID().uuidString
        let values = SoundPublications()
        let gate = SoundPublicationGate()
        let vad = SoundVADSession()
        let agent = try SpeechPerceptionAgent(
            recognition: NoSoundASR(), vad: SoundVAD(session: vad), sessionID: session,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "speechPerception"), scope: UUID().uuidString,
                state: SpeechPerceptionContextState())
        )
        try await agent.bind(
            AgentMessaging { message, _, _ in
                if case .soundSource(let value)? = message.perception {
                    if !(await gate.started) { await gate.wait() }
                    await values.append(value)
                }
                return DeliveryReport()
            })
        try await agent.start()
        try await processMicrophoneFixture(
            soundInput(soundPCM(direction: (1, 0, 0), count: 1600), session: session, sequence: 0, timestamp: 0),
            using: agent)
        try await waitForSound { await gate.started }
        for index in 1...5 {
            try await processMicrophoneFixture(
                soundInput(
                    soundPCM(direction: (0, 1, 0), count: 1600), session: session,
                    sequence: UInt64(index), timestamp: Double(index) * 0.1), using: agent)
        }
        try await waitForSound { await vad.frames.count == 6 }
        try await waitForSound { await values.values.contains { $0.direction?.y == 1 } }
        await gate.release()
        try await waitForSound { await values.values.contains { $0.direction?.x == 1 } }
        await agent.stop()
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func soundSourceOldCaptureNeverPublishesDirection() async throws {
        let session = UUID().uuidString
        let values = SoundPublications()
        let agent = try SpeechPerceptionAgent(
            recognition: NoSoundASR(), vad: SoundVAD(session: SoundVADSession()), sessionID: session,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "speechPerception"), scope: UUID().uuidString,
                state: SpeechPerceptionContextState())
        )
        try await agent.bind(
            AgentMessaging { message, _, _ in
                if case .soundSource(let value)? = message.perception { await values.append(value) }
                return DeliveryReport()
            })
        try await agent.start()
        try await processMicrophoneFixture(
            soundInput(
                soundPCM(direction: (1, 0, 0), count: 1600), session: session, sequence: 0,
                timestamp: 0, capturedAt: .now.advanced(by: .seconds(-1))), using: agent)
        try await waitForSound { await agent.status().processedInputs > 0 }
        await agent.stop()
        #expect(await values.values.isEmpty)
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func soundSourceNoGatewayRecipientsIsAnOrdinaryDeliveryOutcome() async throws {
        let manager = AgentManager()
        let session = UUID().uuidString
        let speech = try SpeechPerceptionAgent(
            recognition: NoSoundASR(), vad: SoundVAD(session: SoundVADSession()), sessionID: session,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "speechPerception"), scope: UUID().uuidString,
                state: SpeechPerceptionContextState())
        )
        let policy = try CommunicationPolicy(
            contracts: AgentContracts.communication,
            configurations: AgentConfigurations.all())
        try await manager.register(speech, sessionID: session)
        let input = InputGateway(manager: manager, policy: policy)
        let output = await OutputGateway(
            manager: manager, requests: input, tools: ToolRegistry(), policy: policy, sink: { _ in })
        let port = try await output.messaging(for: .speechPerception)
        try await speech.bind(port)
        try await speech.start()
        _ = try await processMicrophoneFixture(
            soundInput(soundPCM(direction: (1, 0, 0), count: 1600), session: session, sequence: 1, timestamp: 0),
            using: speech)
        try await waitForSound { await speech.status().processedInputs > 0 }
        #expect(await port.history.snapshot().isEmpty)
        #expect(await speech.status().lifecycle == .running)
        #expect(await speech.soundPublicationRejections == 0)
        await manager.stopAll()
        await output.shutdown()
    }
}

private struct SoundRecognition: SpeechRecognitionCapability {
    var availability: CapabilityAvailability { .available }
    func transcribe(_ request: SpeechRecognitionRequest) throws -> SpeechRecognitionSession {
        let pair = InferenceSession<TranscriptionEvent>.make(
            context: request.context, limits: try StreamLimits(), estimatedBytes: { $0.estimatedBytes })
        return SpeechRecognitionSession(
            output: pair.session, format: request.format, sendAudio: { _ in },
            finishInput: {
                try pair.emitter.yield(
                    TranscriptionEvent(
                        segmentID: UUID().uuidString, revision: 1, text: "hello", isFinal: true))
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

extension LiveRuntimeTests {
    @Test(.actionCatalog) func soundSourceReplyGateClearsDirectionAndResumeStartsANewWindow() async throws {
        let session = UUID().uuidString
        let values = SoundPublications()
        let finals = SoundPublications()
        let speech = try SpeechPerceptionAgent(
            recognition: SoundRecognition(), vad: SoundEndpoint(), sessionID: session,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "speechPerception"), scope: UUID().uuidString,
                state: SpeechPerceptionContextState())
        )
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
        let outputs = Task { for await _ in fixtureOutputs(speech) {} }
        try await processMicrophoneFixture(
            soundInput(soundPCM(direction: (1, 0, 0), count: 1600), session: session, sequence: 0, timestamp: 0),
            using: speech)
        try await waitForSound { await values.values.contains { $0.state == .active } }
        for index in 1...4 {
            try await processMicrophoneFixture(
                soundInput(
                    Array(repeating: 0, count: 3200 * 4), session: session, sequence: UInt64(index),
                    timestamp: 0.1 + Double(index - 1) * 0.2), using: speech)
            try await waitForSound { await speech.status().processedInputs >= index + 1 }
        }
        try await waitForSound { await finals.values.count == 1 }
        try await waitForSound { await values.values.last?.state == .inactive }
        // Final ASR gates the next utterance; playback admission is an additional independent barrier.
        try await waitForSound { await speech.isUtteranceActive() == false }
        try await speech.pauseAudioAdmission()
        await #expect(throws: CapabilityError.inputBusy) {
            try await processMicrophoneFixture(
                soundInput(soundPCM(direction: (0, 1, 0), count: 800), session: session, sequence: 5, timestamp: 0.9),
                using: speech)
        }
        try await speech.resumeListening()
        let previousCount = await values.values.count
        try await processMicrophoneFixture(
            soundInput(soundPCM(direction: (0, 1, 0), count: 800), session: session, sequence: 6, timestamp: 1),
            using: speech)
        try await waitForSound { await speech.status().processedInputs >= 6 }
        #expect(await values.values.count == previousCount)
        try await processMicrophoneFixture(
            soundInput(soundPCM(direction: (0, 1, 0), count: 800), session: session, sequence: 7, timestamp: 1.05),
            using: speech)
        try await waitForSound { await values.values.last?.direction?.y == 1 }
        await speech.stop()
        await outputs.value
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func soundSourceStopCancelsAndJoinsAnInFlightPublisher() async throws {
        let session = UUID().uuidString
        let values = SoundPublications()
        let gate = SoundPublicationGate()
        let speech = try SpeechPerceptionAgent(
            recognition: NoSoundASR(), vad: SoundVAD(session: SoundVADSession()), sessionID: session,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "speechPerception"), scope: UUID().uuidString,
                state: SpeechPerceptionContextState())
        )
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
        try await processMicrophoneFixture(
            soundInput(soundPCM(direction: (1, 0, 0), count: 1600), session: session, sequence: 0, timestamp: 0),
            using: speech)
        try await waitForSound { await gate.started }
        await speech.stop()
        #expect(await speech.status().lifecycle == .stopped)
        #expect(await values.values.isEmpty)
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
    func listeningContainerIsConsumedBySpeechPerceptionWithoutAssistantForwarding() async throws {
        let ui = UIContainer()
        try ui.start()
        let agent = try SpeechPerceptionAgent(
            recognition: NoSoundASR(), vad: ForbiddenSoundVAD(), sessionID: "capture-ui",
            interactionSessionID: "listening-ui", residentListening: true, uiHome: ui.home,
            context: AgentContextRepository(
                agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState()))
        try await agent.start()
        var outputs = agent.outputs.makeAsyncIterator()
        try await ui.home.listeningRequests.submitControl(.setEnabled(true))
        let enabled = try #require(await outputs.next())
        guard case .actionCall(let call) = enabled.output else {
            Issue.record("Listening policy must select its protected Action")
            await agent.stop()
            return
        }
        #expect(call.actionPath.description == "Speech.Listening.update")
        #expect(call.parameters["enabled"] == "true")
        #expect(enabled.inputMetadata.generation == ui.home.listeningRequests.generation.uuidString)
        try await agent.pause()
        await #expect(throws: UIRequestError.unavailable) {
            try await ui.home.listeningRequests.submitControl(.setEnabled(false))
        }
        try await agent.resume()
        try await ui.home.listeningRequests.submitControl(.setEnabled(false))
        await agent.stop()
        await ui.stop()
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
    func listeningConsentRevocationDoesNotDependOnActiveUIOrAnInputConsumer() async throws {
        let ui = UIContainer()
        try ui.start()
        let agent = try SpeechPerceptionAgent(
            recognition: NoSoundASR(), vad: ForbiddenSoundVAD(), sessionID: "capture-revoke",
            interactionSessionID: "listening-revoke", residentListening: true, uiHome: ui.home,
            context: AgentContextRepository(
                agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState()))
        try await agent.start()
        var outputs = agent.outputs.makeAsyncIterator()
        try await ui.home.listeningRequests.submitControl(.setEnabled(true))
        _ = await outputs.next()
        _ = await outputs.next()
        ui.invalidate()
        try await agent.pause()
        try await agent.stopListening(sessionID: "listening-revoke")
        let disabled = try #require(await outputs.next())
        guard case .actionCall(let call) = disabled.output else {
            Issue.record("Revocation must select the protected listening Action")
            await agent.stop()
            return
        }
        #expect(call.parameters["enabled"] == "false")
        await #expect(throws: UIRequestError.unavailable) {
            try await ui.home.listeningRequests.submitControl(.setEnabled(true))
        }
        await agent.stop()
        await ui.stop()
    }
}

private actor ListeningConsentCommitGate {
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private var pending: CheckedContinuation<Void, Never>?
    private var held = false
    func hold() async {
        guard !held else { return }
        held = true
        await withCheckedContinuation {
            pending = $0
            entered.continuation.yield(())
        }
    }
    func release() {
        pending?.resume()
        pending = nil
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
    func consentRevocationRejectsAnEarlierEnableWaitingForContextCommit() async throws {
        let ui = UIContainer()
        try ui.start()
        let gate = ListeningConsentCommitGate()
        let context = try AgentContextRepository(
            agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState(),
            persistence: .init(
                load: { nil },
                commit: { value, _ in
                    if value.records.contains(where: { $0.kind == ListeningIntent.contract }) { await gate.hold() }
                }))
        let agent = try SpeechPerceptionAgent(
            recognition: NoSoundASR(), vad: ForbiddenSoundVAD(), sessionID: "capture-fence",
            interactionSessionID: "consent-fence", residentListening: true, uiHome: ui.home, context: context)
        try await agent.start()
        var entered = gate.entered.stream.makeAsyncIterator()
        let enabling = Task { try await ui.home.listeningRequests.submitControl(.setEnabled(true)) }
        await entered.next()
        try await agent.stopListening(sessionID: "consent-fence")
        await gate.release()
        await #expect(throws: CommunicationError.scopeClosed) { try await enabling.value }
        try await ui.home.listeningRequests.submitControl(.setEnabled(false))
        var outputs = agent.outputs.makeAsyncIterator()
        let disabled = try #require(await outputs.next())
        guard case .actionCall(let call) = disabled.output else {
            Issue.record("The retired enable must not emit a listening Action")
            await agent.stop()
            return
        }
        #expect(call.parameters["enabled"] == "false")
        await agent.stop()
        await ui.stop()
    }
}

private actor NativePacketVAD: VoiceActivitySession {
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private(set) var completed = false
    private var released = false
    private var position: Int64 = 0
    func process(_ frame: AudioFrame) async throws -> [VoiceActivityScore] {
        entered = true
        if !released { await withCheckedContinuation { waiter = $0 } }
        try Task.checkCancellation()
        completed = true
        defer { position += Int64(frame.sampleCount) }
        return [try VoiceActivityScore(startSample: position, sampleCount: frame.sampleCount, probability: 0)]
    }
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
    func finish() -> [VoiceActivityScore] { [] }
    func reset() { position = 0 }
    func cancel() { release() }
}
private struct NativePacketVADCapability: VoiceActivityCapability {
    let session: NativePacketVAD
    var availability: CapabilityAvailability { .available }
    func detectVoiceActivity(format: AudioFormat) -> any VoiceActivitySession { session }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog, .timeLimit(.minutes(1))) func nativeMicrophoneBackpressureKeepsOnlyTheNative64PacketFIFO()
        async throws
    {
        let microphone = DirectSoundMicrophone()
        let vad = NativePacketVAD()
        let session = UUID().uuidString
        let speech = try SpeechPerceptionAgent(
            recognition: NoSoundASR(), vad: NativePacketVADCapability(session: vad), sessionID: session,
            microphoneInput: microphone,
            context: AgentContextRepository(
                agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState()))
        try await speech.start()
        try await speech.startInput(sessionID: session)
        func frame(_ sequence: UInt64) -> MicrophoneFrame {
            MicrophoneFrame(
                samples: Array(repeating: 0.01, count: 1536), sampleRate: 16000, sequence: sequence,
                timestamp: Double(sequence) * 0.096)
        }
        try microphone.source.send(frame(0))
        try await waitForSound { await vad.entered }
        // The first packet is in model processing. No role-side backlog drains the native queue.
        for sequence in UInt64(1)...64 { try microphone.source.send(frame(sequence)) }
        #expect(throws: AudioIOError.overflow) { try microphone.source.send(frame(65)) }
        await vad.release()
        await #expect(throws: AudioIOError.overflow) { try await speech.waitForInput() }
        #expect(await speech.status().processedInputs > 0)
        await speech.stop()
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog, .timeLimit(.minutes(1))) func microphoneReplacementResetsNativeSequenceAndIsJoinedAtStop()
        async throws
    {
        let microphone = DirectSoundMicrophone()
        let session = UUID().uuidString
        let speech = try SpeechPerceptionAgent(
            recognition: NoSoundASR(), vad: ForbiddenSoundVAD(), sessionID: session,
            mode: .soundSourceOnly, microphoneInput: microphone,
            context: AgentContextRepository(
                agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState()))
        try await speech.start()
        try await speech.startInput(sessionID: session)
        try await microphone.send(10)
        try await waitForSound { await speech.status().processedInputs == 1 }
        await microphone.finishCapture()
        try await speech.waitForInput()
        await speech.stopInput()
        _ = await microphone.replaceCapture()
        try await speech.startInput(sessionID: session)
        try await microphone.send(0)
        try await waitForSound { await speech.status().processedInputs == 2 }
        #expect(await microphone.subscriptions == 2)
        await microphone.finishCapture(throwing: AudioIOError.interrupted)
        await #expect(throws: AudioIOError.interrupted) { try await speech.waitForInput() }
        await speech.stop()
        await #expect(throws: HarnessError.notRunning) { try await speech.startInput(sessionID: session) }
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog, .timeLimit(.minutes(1))) func nativeMicrophoneRetirementAndResumeJoinAcceptedProcessing()
        async throws
    {
        for resume in [false, true] {
            let microphone = DirectSoundMicrophone()
            let vad = NativePacketVAD()
            let session = UUID().uuidString
            let speech = try SpeechPerceptionAgent(
                recognition: NoSoundASR(), vad: NativePacketVADCapability(session: vad), sessionID: session,
                microphoneInput: microphone,
                context: AgentContextRepository(
                    agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState()))
            try await speech.start()
            try await speech.startInput(sessionID: session)
            try microphone.source.send(
                MicrophoneFrame(
                    samples: Array(repeating: 0.01, count: 1536), sampleRate: 16000, sequence: 0))
            try await waitForSound { await vad.entered }
            let retiring = Task {
                if resume {
                    try await speech.pauseAudioAdmission()
                    try await speech.resumeListening()
                } else {
                    await speech.stopInput()
                }
                return await vad.completed
            }
            try await Task.sleep(for: .milliseconds(20))
            await vad.release()
            #expect(try await retiring.value)
            await speech.stop()
        }
    }
}

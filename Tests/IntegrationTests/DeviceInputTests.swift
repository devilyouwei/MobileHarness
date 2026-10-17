import AgentBindings
import AgentCore
import Agents
import CallRuntime
import CoreVideo
import Foundation
import Gateway
import Testing

@testable import PlatformKit

@Test func deviceAudioIngressPreservesNativeLayoutAndBindsExternalIdentity() throws {
    let frame = MicrophoneFrame(
        samples: [1, 2, 3, 4], sampleRate: 48_000, sequence: 7,
        layout: .firstOrderAmbisonicsACNSN3D, timestamp: 2)
    let signal = try DeviceInputAdapter.audio(frame, sessionID: "capture", sequence: 13)
    #expect(signal.sessionID == "capture")
    #expect(signal.metadata.origin == .external)
    #expect(signal.metadata.source == "phone.microphone")
    #expect(signal.metadata.contract == "media.audio")
    #expect(signal.metadata.incarnation == nil)
    #expect(signal.metadata.rootID == signal.id)
    guard case .audio(let audio) = signal.payload else {
        Issue.record("Expected PCM")
        return
    }
    #expect(audio.sequence == 13)
    #expect(audio.layout == .firstOrderAmbisonicsACNSN3D)
    #expect(audio.frameCount == 1)
    #expect(audio.capturedAt == frame.capturedAt)
    #expect(throws: AudioValidationError.self) {
        try DeviceInputAdapter.audio(MicrophoneFrame(samples: [1], sampleRate: 1, sequence: 0), sessionID: "capture")
    }
}

@Test func nativeImageAttachmentRejectsWrongFrameAndExpiredExecution() throws {
    var buffer: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
    let pixels = try #require(buffer)
    func frame(at instant: ContinuousClock.Instant) -> CameraFrame {
        CameraFrame(
            width: 8, height: 8, pixels: pixels, gray64: Data(repeating: 0, count: 4096),
            sequence: 4, timestamp: 1, capturedAt: instant, rotation: 0)
    }
    let signal = try DeviceInputAdapter.image(frame(at: .now), sessionID: "camera")
    guard case .image(let image) = signal.payload else {
        Issue.record("Expected image")
        return
    }
    #expect(signal.metadata.source == "phone.camera")
    #expect(try DeviceInputAdapter.executionAttachment(image, sequence: 4) is CameraFrame)
    #expect(throws: CommunicationError.self) { try DeviceInputAdapter.executionAttachment(image, sequence: 5) }
    let stale = try DeviceInputAdapter.image(frame(at: .now.advanced(by: .seconds(-1))), sessionID: "camera")
    guard case .image(let old) = stale.payload else { return }
    #expect(throws: CommunicationError.self) { try DeviceInputAdapter.executionAttachment(old, sequence: 4) }
}

@Test func nativeBroadcastSeparatesSubscribersAndBoundsSlowConsumers() async throws {
    let source = NativeInputBroadcast<Int>()
    let first = try source.subscribe(.latest)
    let second = try source.subscribe(.latest)
    source.send(1)
    source.send(2)
    var a = first.makeAsyncIterator()
    var b = second.makeAsyncIterator()
    #expect(try await a.next() == 2)
    #expect(try await b.next() == 2)
    #expect(source.replacements == 2)
    source.finish()
    #expect(try await a.next() == nil)
    #expect(try await b.next() == nil)
}

@Test func nativeOrderedOverflowRetainsAcceptedPacketsAndFailsOnlySlowSubscriber() async throws {
    let source = NativeInputBroadcast<Int>()
    let ordered = try source.subscribe(.ordered)
    let latest = try source.subscribe(.latest)
    for value in 0...64 { source.send(value) }
    var packets = ordered.makeAsyncIterator()
    for value in 0..<64 { #expect(try await packets.next() == value) }
    await #expect(throws: NativeSubscriptionError.self) { try await packets.next() }
    var observation = latest.makeAsyncIterator()
    #expect(try await observation.next() == 64)
    source.send(65)
    #expect(try await observation.next() == 65)
    source.finish()
}

@Test func nativeBroadcastRejectsExcessSubscriptionsAndReleasesClosedGeneration() throws {
    let source = NativeInputBroadcast<Int>()
    let streams = try (0..<16).map { _ in try source.subscribe(.latest) }
    #expect(streams.count == 16)
    #expect(throws: NativeSubscriptionError.self) { try source.subscribe(.latest) }
    source.finish()
    _ = try source.subscribe(.latest)
    source.finish()
}

@Test func deviceInputConnectionJoinsAnIdleSourceOnCancellation() async throws {
    let frames = AsyncThrowingStream<CameraFrame, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let input = InputGateway(manager: AgentManager())
    let connection = DeviceInputConnection(frames: frames.stream, sessionID: "camera", input: input)
    let wait = Task { try await connection.wait() }
    wait.cancel()
    _ = await wait.result
    await connection.stop()
    await input.shutdown()
}

@Test func nativeSessionFencesLateCallbacksWithoutAffectingReplacement() async throws {
    let broadcast = NativeInputBroadcast<Int>()
    let old = NativeInputSession(broadcast: broadcast)
    var first = try broadcast.subscribe(.ordered).makeAsyncIterator()
    old.send(1)
    old.finish()
    #expect(try await first.next() == 1)
    #expect(try await first.next() == nil)
    let replacement = NativeInputSession(broadcast: broadcast)
    var next = try broadcast.subscribe(.ordered).makeAsyncIterator()
    old.send(99)
    old.finish()
    replacement.send(2)
    replacement.finish()
    #expect(try await next.next() == 2)
    #expect(try await next.next() == nil)
}

@Test func nativeSessionSlowObserverDoesNotStopAnotherConsumer() async throws {
    let broadcast = NativeInputBroadcast<Int>()
    let session = NativeInputSession(broadcast: broadcast)
    var slow = try broadcast.subscribe(.ordered).makeAsyncIterator()
    var fast = try broadcast.subscribe(.ordered).makeAsyncIterator()
    for value in 0..<65 {
        session.send(value)
        #expect(try await fast.next() == value)
    }
    for value in 0..<64 { #expect(try await slow.next() == value) }
    await #expect(throws: NativeSubscriptionError.self) { _ = try await slow.next() }
    session.send(65)
    #expect(try await fast.next() == 65)
    session.finish()
    #expect(try await fast.next() == nil)
}

@Test func nativeSessionPropagatesProducerFailureToObservers() async throws {
    let broadcast = NativeInputBroadcast<Int>()
    let session = NativeInputSession(broadcast: broadcast)
    var observer = try broadcast.subscribe(.ordered).makeAsyncIterator()
    session.finish(throwing: NativeSubscriptionError.overflow)
    await #expect(throws: NativeSubscriptionError.self) { _ = try await observer.next() }
}

/// A native-port substitute: no AVFoundation session or system permission request.
private actor CameraCaptureFixture: CameraCapturing {
    nonisolated let events = AsyncStream<CameraEvent> { $0.finish() }
    let captureRotation: CGFloat = 90
    private let frame: CameraFrame
    private var running = false
    init(frame: CameraFrame) { self.frame = frame }
    func requestPermission() -> Bool { true }
    func isRunning() -> Bool { running }
    func start(facing: CameraFacing) -> AsyncThrowingStream<CameraFrame, Error> {
        running = true
        return frames()
    }
    func switchCamera(facing: CameraFacing) -> AsyncThrowingStream<CameraFrame, Error> { frames() }
    func subscribeFrames() -> AsyncThrowingStream<CameraFrame, Error> { frames() }
    private func frames() -> AsyncThrowingStream<CameraFrame, Error> {
        let stream = AsyncThrowingStream<CameraFrame, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream.continuation.yield(frame)
        stream.continuation.finish()
        return stream.stream
    }
    func capturePhoto(rotation: CGFloat) throws -> Data { throw CameraError.photoFailed }
    func stop() { running = false }
    func stopAndWait() { running = false }
}

@Test func injectedCameraInterfaceFeedsTheExistingGatewayAndPreservesNativeFailures() async throws {
    var buffer: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
    let frame = CameraFrame(
        width: 8, height: 8, pixels: try #require(buffer), gray64: Data(repeating: 0, count: 4096),
        sequence: 8, timestamp: 1, capturedAt: .now, rotation: 1)
    let camera: any CameraCapturing = CameraCaptureFixture(frame: frame)
    #expect(!(await camera.isRunning()))
    #expect(await camera.requestPermission())
    #expect(await camera.captureRotation == 90)
    var stream = try await camera.start(facing: .front).makeAsyncIterator()
    let received = try await stream.next()
    let signal = try DeviceInputAdapter.image(try #require(received), sessionID: "injected-camera")
    #expect(signal.metadata.source == "phone.camera")
    #expect(signal.sessionID == "injected-camera")
    guard case .image(let image) = signal.payload else {
        Issue.record("Expected image Signal")
        return
    }
    #expect(image.sequence == 8)
    #expect(image.rotation == 1)
    guard case .attachment = image.content else {
        Issue.record("Injected camera must preserve an in-process native attachment")
        return
    }
    await #expect(throws: CameraError.photoFailed) { try await camera.capturePhoto(rotation: 90) }
    await camera.stopAndWait()
    #expect(!(await camera.isRunning()))
}

private struct SyntheticSensorInput: ExternalInputProviding, Codable, Equatable {
    let value: Double
    func externalInput(sessionID: String, sequence: UInt64) throws -> ExternalInputDraft {
        ExternalInputDraft(
            sessionID: sessionID,
            payload: .observation(
                AgentMessage(
                    contract: "sensor.sample", content: self, maximumBytes: 128,
                    validate: { guard $0.value.isFinite else { throw CommunicationError.invalidPayload } })),
            source: "phone.sensor", sequence: sequence)
    }
}

private func sensorContracts() throws -> CommunicationContracts {
    try CommunicationContracts(additional: [
        CommunicationContract(
            name: "sensor.sample", kind: .observation, maximumBytes: 128,
            validateMessage: { message in
                guard message.content(as: SyntheticSensorInput.self) != nil else {
                    throw CommunicationError.invalidPayload
                }
            })
    ])
}

private func sensorConfiguration(
    _ id: String, contracts: CommunicationContracts, sources: [String] = [], publishes: Bool = false
) throws -> AgentConfiguration {
    try AgentConfiguration(
        contracts: contracts,
        data: JSONSerialization.data(withJSONObject: [
            "version": 6, "id": id, "actions": [String: [String]](), "tools": [],
            "communication": [
                "inputs": [["contract": "sensor.sample", "version": 1, "kind": "observation"]],
                "subscriptions": sources.map {
                    ["contract": "sensor.sample", "topic": "sensor.sample", "source": $0]
                },
                "publications": publishes ? ["sensor.sample"] : [], "sends": [String](),
            ],
        ]))
}

@Test func unifiedExternalIngressPreservesBusinessIdentityAndCausality() throws {
    let session = "business-root"
    let photo = try PhotographerCameraIntent(.open, requestID: "photo-request").input(sessionID: session)
    #expect(photo.id == "photo-request")
    #expect(photo.metadata.rootID == photo.id)
    #expect(photo.metadata.source == "user")
    #expect(photo.payload.kind == .observation)
    let cancel = try PhotographerCameraIntent(.cancel, requestID: "photo-request").input(sessionID: session)
    #expect(cancel.id == photo.id)
    #expect(cancel.metadata.source == "runtime")
    let history = try MemoryHistoryIntent.query("history-request").input(sessionID: session)
    #expect(history.id == "history-request")
    let retired = try ModelResourceIntent.retire("resource-request").input(sessionID: session)
    #expect(retired.id == "resource-request")
    #expect(retired.metadata.source == "runtime")
    let failure = try ModelResourceHostFailure(
        requestID: "resource-request", phase: .admission, scope: .operation, message: "synthetic failure"
    ).input(sessionID: session)
    #expect(failure.metadata.parentID == "resource-request")
    #expect(failure.metadata.hops == 1)
    let fact = try AppEnvironmentFact(category: .scene, sequence: 17, value: "active").input(sessionID: session)
    #expect(fact.metadata.sequence == 17)
    #expect(fact.metadata.source == "app.environment")
    let observation = try ModelResourceObservation.changed(generation: 2).input(sessionID: session, sequence: 9)
    #expect(observation.metadata.sequence == 9)
    for signal in [photo, cancel, history, retired, failure, fact, observation] {
        #expect(signal.sessionID == session)
        #expect(signal.metadata.origin == .external)
        #expect(signal.metadata.incarnation == nil)
        #expect(signal.taskScope == nil)
    }
}

@Test func unifiedExternalIngressRejectsForgedFeedbackAndInvalidContent() throws {
    #expect(throws: CommunicationError.unauthorized) {
        try ExternalInputAdapter.signal(
            ExternalInputDraft(
                sessionID: "s", payload: .toolResult(ToolResult(callID: "fake", value: "success")), source: "user"))
    }
    #expect(throws: CommunicationError.invalidPayload) {
        try ExternalInputAdapter.signal(
            ExternalInputDraft(sessionID: "", payload: .text("hello"), source: "user"))
    }
    #expect(throws: CommunicationError.invalidPayload) {
        try ExternalInputAdapter.signal(
            ExternalInputDraft(sessionID: "s", payload: .text(String(repeating: "x", count: 4097)), source: "user"))
    }
    #expect(throws: CommunicationError.invalidPayload) {
        try SyntheticSensorInput(value: .infinity).input(sessionID: "s", sequence: 1)
    }
    #expect(throws: CommunicationError.invalidPayload) {
        try AppInteractionIntent(kind: .navigation, parameters: ["executable": "forbidden"]).input(sessionID: "s")
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    let signal = try ExternalInputAdapter.signal(
        ExternalInputDraft(
            id: "typed", sessionID: "s", payload: .text("hello"), source: "user", sequence: 4,
            rootID: "root", parentID: "parent", hops: 2, deadline: deadline))
    let withTurn = try ExternalInputAdapter.assigningTurn(AgentTurn(id: "turn", ordinal: 1), to: signal)
    #expect(withTurn.metadata.deadline == deadline)
    #expect(withTurn.metadata.rootID == "root")
    #expect(withTurn.metadata.parentID == "parent")
    #expect(withTurn.metadata.sequence == 4)
    #expect(withTurn.turn?.ordinal == 1)
    #expect(withTurn.id == signal.id)
}

@Test func unifiedExternalIngressRoutesRegisteredSensorAndCancelsDynamicSubscription() async throws {
    let contracts = try sensorContracts()
    let policy = try CommunicationPolicy(
        contracts: contracts, externalSources: ["phone.sensor"],
        configurations: [sensorConfiguration("sensorConsumer", contracts: contracts)])
    let manager = AgentManager()
    let consumer = ObservationRecorder(id: "sensorConsumer")
    try await manager.register(consumer, sessionID: "sensor-session")
    await consumer.start()
    let gateway = InputGateway(manager: manager, policy: policy)
    let owner = ExecutionOwner(
        agent: consumer.descriptor.id, incarnation: try await manager.identity(consumer.descriptor.id),
        sessionID: "sensor-session")
    let subscription = try await gateway.subscribe(owner: owner, contract: "sensor.sample", source: "phone.sensor")
    try await gateway.publish(SyntheticSensorInput(value: 0.25).externalInput(sessionID: "sensor-session", sequence: 8))
    await gateway.flushPublications()
    let received = try #require(await consumer.inputs.first)
    #expect(received.metadata.sequence == 8)
    #expect(received.metadata.origin == .external)
    if case .observation(let message) = received.payload {
        #expect(message.content(as: SyntheticSensorInput.self)?.value == 0.25)
    } else {
        Issue.record("Expected typed sensor observation")
    }
    let wrongType = AgentMessage(contract: "sensor.sample", content: "wrong type", validate: { _ in })
    await #expect(throws: CommunicationError.invalidPayload) {
        try await gateway.publish(
            ExternalInputDraft(sessionID: "sensor-session", payload: .observation(wrongType), source: "phone.sensor"))
    }
    let unknown = AgentMessage(contract: "sensor.unknown", content: SyntheticSensorInput(value: 1), validate: { _ in })
    await #expect(throws: CommunicationError.unsupportedContract) {
        try await gateway.publish(
            ExternalInputDraft(sessionID: "sensor-session", payload: .observation(unknown), source: "phone.sensor"))
    }
    await gateway.unsubscribe(subscription)
    try await gateway.publish(SyntheticSensorInput(value: 0.5).input(sessionID: "sensor-session", sequence: 9))
    await gateway.flushPublications()
    #expect(await consumer.inputs.count == 1)
    await gateway.shutdown()
    await #expect(throws: CommunicationError.scopeClosed) {
        try await gateway.subscribe(owner: owner, contract: "sensor.sample", source: "phone.sensor")
    }
    await #expect(throws: CommunicationError.scopeClosed) {
        try await gateway.publish(SyntheticSensorInput(value: 1).input(sessionID: "sensor-session"))
    }
    await manager.stopAll()
}

@Test func unifiedDynamicSubscriptionsFenceSessionAndReplacedIncarnation() async throws {
    let contracts = try sensorContracts()
    let policy = try CommunicationPolicy(
        contracts: contracts, externalSources: ["phone.sensor"],
        configurations: [sensorConfiguration("sensorConsumer", contracts: contracts)])
    let manager = AgentManager()
    let old = ObservationRecorder(id: "sensorConsumer")
    try await manager.register(old, sessionID: "old-session")
    await old.start()
    let gateway = InputGateway(manager: manager, policy: policy)
    let owner = ExecutionOwner(
        agent: old.descriptor.id, incarnation: try await manager.identity(old.descriptor.id), sessionID: "old-session")
    let token = try await gateway.subscribe(owner: owner, contract: "sensor.sample", source: "phone.sensor")
    try await gateway.publish(SyntheticSensorInput(value: 1).input(sessionID: "other-session"))
    await gateway.flushPublications()
    #expect(await old.attempts == 0)
    try await manager.remove(old.descriptor.id)
    let replacement = ObservationRecorder(id: "sensorConsumer")
    try await manager.register(replacement, sessionID: "old-session")
    await replacement.start()
    try await gateway.publish(SyntheticSensorInput(value: 2).input(sessionID: "old-session"))
    await gateway.flushPublications()
    #expect(await replacement.attempts == 0)
    await #expect(throws: CommunicationError.staleIncarnation) {
        try await gateway.subscribe(owner: owner, contract: "sensor.sample", source: "phone.sensor")
    }
    let newOwner = ExecutionOwner(
        agent: replacement.descriptor.id, incarnation: try await manager.identity(replacement.descriptor.id),
        sessionID: "old-session")
    _ = try await gateway.subscribe(owner: newOwner, contract: "sensor.sample", source: "phone.sensor")
    await gateway.unsubscribe(token)
    try await gateway.publish(SyntheticSensorInput(value: 3).input(sessionID: "old-session"))
    await gateway.flushPublications()
    #expect(await replacement.inputs.count == 1)
    await gateway.shutdown()
    await manager.stopAll()
}

@Test func unifiedDynamicSubscriptionsRejectUnsupportedSourcesSchemasAndDuplicateRelations() async throws {
    let contracts = try sensorContracts()
    let policy = try CommunicationPolicy(
        contracts: contracts, externalSources: ["phone.sensor"],
        configurations: [sensorConfiguration("sensorConsumer", contracts: contracts, sources: ["phone.sensor"])])
    let manager = AgentManager()
    let consumer = ObservationRecorder(id: "sensorConsumer")
    try await manager.register(consumer, sessionID: "s")
    await consumer.start()
    let gateway = InputGateway(manager: manager, policy: policy)
    let owner = ExecutionOwner(
        agent: consumer.descriptor.id, incarnation: try await manager.identity(consumer.descriptor.id), sessionID: "s")
    await #expect(throws: CommunicationError.invalidPayload) {
        try await gateway.subscribe(owner: owner, contract: "sensor.sample", source: "phone.sensor")
    }
    await #expect(throws: CommunicationError.unauthorized) {
        try await gateway.subscribe(owner: owner, contract: "sensor.sample", source: "unregistered")
    }
    await #expect(throws: CommunicationError.unsupportedContract) {
        try await gateway.subscribe(owner: owner, contract: "user.text", source: "phone.sensor")
    }
    await #expect(throws: CommunicationError.unsupportedContract) {
        try await gateway.subscribe(owner: owner, contract: "sensor.unknown", source: "phone.sensor")
    }
    // Static admission survives rejected mutations and dynamic cancellation of unrelated topics.
    let report = try await gateway.send(SyntheticSensorInput(value: 1).input(sessionID: "s"))
    #expect(report.delivered == [consumer.descriptor.id])
    await #expect(throws: CommunicationError.unauthorized) {
        try await gateway.publish(
            ExternalInputDraft(sessionID: "s", payload: .event("forged"), source: "unregistered"))
    }
    await gateway.shutdown()
    await manager.stopAll()
}

@Test func unifiedDynamicSubscriptionsCombineStaticAndDynamicAgentBroadcasts() async throws {
    let configurations = try [
        communicationConfiguration("producer", publishes: true),
        communicationConfiguration("consumer", subscribes: true), communicationConfiguration("direct"),
    ]
    let policy = try CommunicationPolicy(contracts: AgentContracts.communication, configurations: configurations)
    let manager = AgentManager()
    let producer = ObservationRecorder(id: "producer")
    let consumer = ObservationRecorder(id: "consumer")
    let dynamic = ObservationRecorder(id: "direct")
    for agent in [producer, consumer, dynamic] {
        try await manager.register(agent, sessionID: "s")
        await agent.start()
    }
    let gateway = InputGateway(manager: manager, policy: policy)
    let owner = ExecutionOwner(
        agent: dynamic.descriptor.id, incarnation: try await manager.identity(dynamic.descriptor.id), sessionID: "s")
    let token = try await gateway.subscribe(owner: owner, contract: "speech.final", source: "producer")
    await #expect(throws: CommunicationError.invalidPayload) {
        try await gateway.subscribe(owner: owner, contract: "speech.final", source: "producer")
    }
    let output = OutputGateway(
        manager: manager, requests: gateway, tools: ToolRegistry(), policy: policy, sink: { _ in })
    let port = try await output.messaging(for: producer.descriptor.id)
    let parent = AgentInput(id: "parent", sessionID: "s", payload: .text("synthetic"))
    try await port.publish(.transcript("first", final: true), parent: parent)
    await gateway.flushPublications()
    #expect(await consumer.inputs.count == 1)
    #expect(await dynamic.inputs.count == 1)
    let producerIdentity = try await manager.identity(producer.descriptor.id)
    #expect(await dynamic.inputs.first?.metadata.incarnation == producerIdentity)
    await gateway.unsubscribe(token)
    try await port.publish(.transcript("second", final: true), parent: parent)
    await gateway.flushPublications()
    #expect(await consumer.inputs.count == 2)
    #expect(await dynamic.inputs.count == 1)
    await gateway.shutdown()
    await manager.stopAll()
}

@Test func unifiedDynamicSubscriptionsBoundRelationsAndRecoverCapacity() async throws {
    let contracts = try sensorContracts()
    let sources = Set((0..<16).map { "sensor\($0)" })
    let policy = try CommunicationPolicy(
        contracts: contracts, externalSources: sources,
        configurations: [
            sensorConfiguration("sensorConsumer", contracts: contracts),
            sensorConfiguration("sensorProducer", contracts: contracts, publishes: true),
        ])
    let manager = AgentManager()
    let consumer = ObservationRecorder(id: "sensorConsumer")
    try await manager.register(consumer, sessionID: "s")
    await consumer.start()
    let gateway = InputGateway(manager: manager, policy: policy)
    let owner = ExecutionOwner(
        agent: consumer.descriptor.id, incarnation: try await manager.identity(consumer.descriptor.id), sessionID: "s")
    var tokens: [SignalSubscription] = []
    for source in sources.sorted() {
        tokens.append(try await gateway.subscribe(owner: owner, contract: "sensor.sample", source: source))
    }
    await #expect(throws: CommunicationError.capacityExceeded) {
        try await gateway.subscribe(owner: owner, contract: "sensor.sample", source: "sensorProducer")
    }
    await gateway.unsubscribe(tokens[0])
    _ = try await gateway.subscribe(owner: owner, contract: "sensor.sample", source: "sensorProducer")
    await gateway.shutdown()
    await manager.stopAll()
}

@Test func unifiedDynamicSubscriptionsBoundFanoutAndGlobalRelations() async throws {
    let contracts = try sensorContracts()
    let ids = (0..<17).map { "sensorConsumer\($0)" }
    let sources = Set((0..<16).map { "sensor\($0)" })
    let policy = try CommunicationPolicy(
        contracts: contracts, externalSources: sources,
        configurations: ids.map { try sensorConfiguration($0, contracts: contracts) }
            + [sensorConfiguration("sensorProducer", contracts: contracts, publishes: true)])
    let manager = AgentManager()
    let gateway = InputGateway(manager: manager, policy: policy)
    var owners: [ExecutionOwner] = []
    for id in ids {
        let consumer = ObservationRecorder(id: id)
        try await manager.register(consumer, sessionID: "s")
        await consumer.start()
        owners.append(
            ExecutionOwner(
                agent: consumer.descriptor.id, incarnation: try await manager.identity(consumer.descriptor.id),
                sessionID: "s"))
    }
    var tokens: [SignalSubscription] = []
    for owner in owners.prefix(16) {
        tokens.append(try await gateway.subscribe(owner: owner, contract: "sensor.sample", source: "sensor0"))
    }
    await #expect(throws: CommunicationError.capacityExceeded) {
        try await gateway.subscribe(owner: owners[16], contract: "sensor.sample", source: "sensor0")
    }
    for owner in owners.prefix(16) {
        for source in sources.sorted() where source != "sensor0" {
            _ = try await gateway.subscribe(owner: owner, contract: "sensor.sample", source: source)
        }
    }
    // The next relation has free target and fanout capacity but exceeds the global 256 bound.
    await #expect(throws: CommunicationError.capacityExceeded) {
        try await gateway.subscribe(owner: owners[16], contract: "sensor.sample", source: "sensorProducer")
    }
    await gateway.unsubscribe(tokens[0])
    _ = try await gateway.subscribe(owner: owners[16], contract: "sensor.sample", source: "sensorProducer")
    await gateway.shutdown()
    await manager.stopAll()
}

@Test func unifiedDynamicSubscriptionShutdownJoinsAcceptedPublication() async throws {
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication,
        configurations: [communicationConfiguration("consumer")])
    let manager = AgentManager()
    let consumer = ObservationRecorder(id: "consumer", blockText: "blocked")
    try await manager.register(consumer, sessionID: "s")
    await consumer.start()
    let gateway = InputGateway(manager: manager, policy: policy)
    let owner = ExecutionOwner(
        agent: consumer.descriptor.id, incarnation: try await manager.identity(consumer.descriptor.id), sessionID: "s")
    _ = try await gateway.subscribe(owner: owner, contract: "speech.final", source: "user")
    let signal = try ExternalInputAdapter.signal(
        ExternalInputDraft(
            sessionID: "s", payload: .observation(.transcript("blocked", final: true)), source: "user"))
    try await gateway.publish(signal)
    var admissions = consumer.admissions.stream.makeAsyncIterator()
    #expect(await admissions.next() == signal.id)
    await gateway.shutdown()
    #expect(await consumer.inputs.isEmpty)
    #expect(await consumer.attempts == 1)
    await manager.stopAll()
}

@Test(.actionCatalog) func unifiedExternalControlUsesGatewayAdmissionAndPreservesCompletionBarrier() async throws {
    let configurations = try [
        "Assistant", "SpeechPerception", "SpeechSynthesis", "VisionPerception", "Photographer", "Memory",
        "ApplicationControl",
    ].map {
        try AgentConfigurations.load(named: $0)
    }
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication,
        externalSources: [
            "user", "runtime", "phone.camera", "phone.microphone", "phone.bluetooth", "app.environment",
            "app.resources", "model.resources",
        ],
        configurations: configurations)
    let manager = AgentManager()
    let input = InputGateway(manager: manager, policy: policy)
    let output = OutputGateway(manager: manager, requests: input, tools: ToolRegistry(), policy: policy, sink: { _ in })
    let agent = try AssistantAgent(
        stateContext: try publicStateFixture(),
        context: try AgentContextRepository(agent: .assistant, scope: "control-root", state: AssistantContextState()))
    let runtime = AgentInteractionRuntime(
        agent: agent, manager: manager, input: input, output: output, startChildren: {})
    try await runtime.start()
    try await runtime.interruptConversation(sessionID: "session")
    try await runtime.cancelConversation(sessionID: "session")
    var snapshots = try await input.observeSignals().makeAsyncIterator()
    let records = try #require(await snapshots.next()).records.filter { $0.contract == "assistant.control" }
    #expect(records.count == 2)
    #expect(records.allSatisfy { $0.phase == .accepted && $0.source == "runtime" && $0.mode == .send })
    #expect(await agent.status().lifecycle == .running)
    await runtime.shutdown()
    await output.shutdown()
}

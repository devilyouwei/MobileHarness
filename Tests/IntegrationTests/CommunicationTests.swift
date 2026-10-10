import Actions
import AgentCore
import Agents
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import Testing

func communicationConfiguration(_ id: String, subscribes: Bool = false, publishes: Bool = false) throws
    -> AgentConfiguration
{
    let communication: [String: Any] = [
        "inputs": [
            ["contract": "speech.final", "version": 1, "kind": "observation"],
            ["contract": "speech.partial", "version": 1, "kind": "observation"],
        ],
        "subscriptions": subscribes
            ? [["contract": "speech.final", "topic": "speech.final", "source": "producer"]] : [],
        "publications": publishes ? ["speech.final", "speech.partial"] : [],
        "sends": publishes ? [["contract": "speech.final", "target": "direct"]] : [],
    ]
    return try AgentConfiguration(
        contracts: AgentContracts.communication,
        data: JSONSerialization.data(withJSONObject: [
            "version": 6, "id": id, "actions": [String: [String]](), "tools": [],
            "communication": communication,
        ]))
}

actor ObservationRecorder: Agent {
    nonisolated let descriptor: AgentDescriptor
    nonisolated let outputs = AsyncStream<OutputEnvelope> { $0.finish() }
    var inputs: [AgentInput] = []
    var lifecycle: AgentLifecycle = .registered
    let reject: Bool
    let blockText: String?
    nonisolated let admissions = AsyncStream<UUID>.makeStream(bufferingPolicy: .bufferingOldest(16))
    init(id: String, reject: Bool = false, blockText: String? = nil) {
        self.blockText = blockText
        self.reject = reject
        descriptor = AgentDescriptor(id: AgentID(rawValue: id), name: id, inputs: [.observation], outputs: [])
    }
    func start() { lifecycle = .running }
    func pause() { lifecycle = .paused }
    func resume() { lifecycle = .running }
    func stop() { lifecycle = .stopped }
    func status() -> AgentStatus { AgentStatus(lifecycle: lifecycle, queuedInputs: 0, processedInputs: inputs.count) }
    func receive(_ input: AgentInput) async throws {
        guard lifecycle == .running else { throw HarnessError.notRunning }
        guard !reject else { throw HarnessError.queueFull }
        admissions.continuation.yield(input.id)
        if case .transcript(let text, _)? = input.payload.perception, text == blockText {
            try await Task.sleep(for: .seconds(30))
        }
        try Task.checkCancellation()
        inputs.append(input)
    }
}

@Test func eventSubscriptionsDirectDeliveryAndIdentityFencing() async throws {
    let configurations = try [
        communicationConfiguration("producer", publishes: true),
        communicationConfiguration("consumer", subscribes: true), communicationConfiguration("direct"),
    ]
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication,
        externalSources: [
            "user", "runtime", "phone.microphone", "phone.camera", "model.resources", "app.resources",
            "app.environment",
        ], configurations: configurations)
    let manager = AgentManager()
    let source = ObservationRecorder(id: "producer")
    let consumer = ObservationRecorder(id: "consumer")
    let direct = ObservationRecorder(id: "direct")
    let session = UUID()
    for agent in [source, consumer, direct] {
        try await manager.register(agent, sessionID: session)
        await agent.start()
    }
    let input = InputGateway(manager: manager, policy: policy, allowsExternalSend: true)
    let output = OutputGateway(
        manager: manager, requests: input, tools: ToolRegistry(), policy: policy, sink: { _ in })
    let port = try await output.messaging(for: source.descriptor.id)
    let parent = AgentInput(sessionID: session, payload: .text("source"))
    try await port.publish(.transcript("hello", final: true), parent: parent)
    await input.flushPublications()
    #expect(await consumer.inputs.first?.metadata.origin == .agent)
    #expect(await direct.inputs.isEmpty)
    let sent = try await port.send(.transcript("direct", final: true), parent: parent, to: direct.descriptor.id)
    #expect(sent.delivered == [direct.descriptor.id])
    await #expect(throws: CommunicationError.unauthorized) {
        try await port.send(.transcript("forbidden", final: true), parent: parent, to: consumer.descriptor.id)
    }
    try await port.publish(.transcript("preview", final: false), parent: parent)
    try await manager.remove(source.descriptor.id)
    await #expect(throws: CommunicationError.staleIncarnation) {
        try await port.publish(.transcript("stale", final: true), parent: parent)
    }
    await manager.stopAll()
}

private func directFixture(blockText: String? = nil, reject: Bool = false) async throws
    -> (AgentManager, InputGateway, OutputGateway, AgentMessaging, ObservationRecorder, UUID)
{
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication,
        externalSources: [
            "user", "runtime", "phone.microphone", "phone.camera", "model.resources", "app.resources",
            "app.environment",
        ],
        configurations: [
            communicationConfiguration("producer", publishes: true),
            communicationConfiguration("consumer", subscribes: true), communicationConfiguration("direct"),
        ])
    let manager = AgentManager()
    let session = UUID()
    let source = ObservationRecorder(id: "producer")
    let consumer = ObservationRecorder(id: "consumer")
    let direct = ObservationRecorder(id: "direct", reject: reject, blockText: blockText)
    for agent in [source, consumer, direct] {
        try await manager.register(agent, sessionID: session)
        await agent.start()
    }
    let input = InputGateway(manager: manager, policy: policy, allowsExternalSend: true)
    let output = OutputGateway(manager: manager, requests: input, tools: ToolRegistry(), policy: policy, sink: { _ in })
    return (manager, input, output, try await output.messaging(for: source.descriptor.id), direct, session)
}

@Test func directMessagingRejectsExpiredParentWrongSessionAndStoppedTarget() async throws {
    let (manager, _, output, port, target, session) = try await directFixture()
    let payload = InputPayload.text("parent")
    let expired = AgentInput(
        sessionID: session, payload: payload,
        metadata: InputMetadata(payload: payload, deadline: .now.advanced(by: .seconds(-1))))
    await #expect(throws: CommunicationError.expired) {
        try await port.send(.transcript("hello", final: true), parent: expired, to: .init(rawValue: "direct"))
    }
    await #expect(throws: CommunicationError.scopeClosed) {
        try await port.publish(
            .transcript("wrong session", final: true), parent: AgentInput(sessionID: UUID(), payload: payload))
    }
    try await manager.stop(target.descriptor.id)
    let report = try await port.send(
        .transcript("stopped", final: true), parent: AgentInput(sessionID: session, payload: payload),
        to: target.descriptor.id)
    #expect(report.delivered.isEmpty && report.rejected[target.descriptor.id] != nil)
    await manager.stopAll()
    await output.shutdown()
}

@Test(.timeLimit(.minutes(1))) func directCallsOverlapAndCancellationBelongsToCaller() async throws {
    let (manager, _, output, port, target, session) = try await directFixture(blockText: "block")
    let parent = AgentInput(sessionID: session, payload: .text("parent"))
    let first = Task {
        try await port.send(.transcript("block", final: true), parent: parent, to: target.descriptor.id)
    }
    var events = target.admissions.stream.makeAsyncIterator()
    _ = await events.next()
    let second = try await port.send(.transcript("second", final: true), parent: parent, to: target.descriptor.id)
    #expect(second.delivered == [target.descriptor.id])
    #expect(await target.inputs.count == 1)
    first.cancel()
    #expect(try await first.value.rejected[target.descriptor.id] != nil)
    // Cancelling the first call does not retract the second accepted message.
    #expect(await target.inputs.count == 1)
    let third = try await port.send(.transcript("third", final: true), parent: parent, to: target.descriptor.id)
    #expect(third.delivered == [target.descriptor.id])
    await manager.stopAll()
    await output.shutdown()
}

@Test(.timeLimit(.minutes(1))) func directOutputCapacityRejectsAndRecoversAfterCallerCancellation() async throws {
    let (manager, _, output, port, target, session) = try await directFixture(blockText: "block")
    let parent = AgentInput(sessionID: session, payload: .text("parent"))
    var tasks: [Task<DeliveryReport, Error>] = []
    var events = target.admissions.stream.makeAsyncIterator()
    for _ in 0..<16 {
        tasks.append(
            Task { try await port.send(.transcript("block", final: true), parent: parent, to: target.descriptor.id) })
        _ = await events.next()
    }
    await #expect(throws: CommunicationError.capacityExceeded) {
        try await port.send(.transcript("overflow", final: true), parent: parent, to: target.descriptor.id)
    }
    for task in tasks { task.cancel() }
    for task in tasks { #expect(try await task.value.rejected[target.descriptor.id] != nil) }
    let report = try await port.send(.transcript("recovered", final: true), parent: parent, to: target.descriptor.id)
    #expect(report.delivered == [target.descriptor.id])
    await manager.stopAll()
    await output.shutdown()
}

@Test(.timeLimit(.minutes(1))) func inputCapacityIsSharedByExternalAndInternalAdmission() async throws {
    let (manager, input, output, port, target, session) = try await directFixture(blockText: "block")
    var tasks: [Task<DeliveryReport, Error>] = []
    var events = target.admissions.stream.makeAsyncIterator()
    for _ in 0..<128 {
        tasks.append(
            Task {
                try await input.send(
                    AgentInput(sessionID: session, payload: .observation(.transcript("block", final: true))),
                    to: target.descriptor.id)
            })
        _ = await events.next()
    }
    await #expect(throws: CommunicationError.capacityExceeded) {
        try await port.send(
            .transcript("overflow", final: true), parent: AgentInput(sessionID: session, payload: .text("parent")),
            to: target.descriptor.id)
    }
    for task in tasks { task.cancel() }
    for task in tasks { _ = try await task.value }
    let report = try await port.send(
        .transcript("recovered", final: true), parent: AgentInput(sessionID: session, payload: .text("parent")),
        to: target.descriptor.id)
    #expect(report.delivered == [target.descriptor.id])
    await manager.stopAll()
    await output.shutdown()
}

@Test func publicationReportsReceiverRejectionIndependently() async throws {
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication,
        externalSources: [
            "user", "runtime", "phone.microphone", "phone.camera", "model.resources", "app.resources",
            "app.environment",
        ],
        configurations: [
            communicationConfiguration("producer", publishes: true), communicationConfiguration("direct"),
            communicationConfiguration("good", subscribes: true), communicationConfiguration("full", subscribes: true),
        ])
    let manager = AgentManager()
    let session = UUID()
    let source = ObservationRecorder(id: "producer")
    let good = ObservationRecorder(id: "good")
    let full = ObservationRecorder(id: "full", reject: true)
    for agent in [source, good, full] {
        try await manager.register(agent, sessionID: session)
        await agent.start()
    }
    let input = InputGateway(manager: manager, policy: policy, allowsExternalSend: true)
    let output = OutputGateway(manager: manager, requests: input, tools: ToolRegistry(), policy: policy, sink: { _ in })
    let port = try await output.messaging(for: source.descriptor.id)
    try await port.publish(
        .transcript("hello", final: true), parent: AgentInput(sessionID: session, payload: .text("parent")))
    await input.flushPublications()
    #expect(await good.inputs.count == 1)
    #expect(await full.inputs.isEmpty)
    await manager.stopAll()
    await output.shutdown()
}

@Test func communicationSchemaRejectsOldVersionsUnknownFieldsAndUnknownSources() throws {
    let config = try communicationConfiguration("receiver")
    #expect(config.agentID.rawValue == "receiver")
    var root: [String: Any] = [
        "version": 3, "id": "receiver", "actions": [String: [String]](), "tools": [],
        "communication": ["inputs": [], "subscriptions": [], "publications": [], "sends": []],
    ]
    #expect(throws: AgentConfigurationError.unsupportedVersion(3)) {
        try AgentConfiguration(
            contracts: AgentContracts.communication, data: JSONSerialization.data(withJSONObject: root))
    }
    root["version"] = 6
    root["communication"] = ["inputs": [], "subscriptions": [], "publications": [], "sends": [], "requests": []]
    #expect(throws: AgentConfigurationError.self) {
        try AgentConfiguration(
            contracts: AgentContracts.communication, data: JSONSerialization.data(withJSONObject: root))
    }
    #expect(throws: CommunicationError.unauthorized) {
        try CommunicationPolicy(
            contracts: AgentContracts.communication,
            externalSources: [
                "user", "runtime", "phone.microphone", "phone.camera", "model.resources", "app.resources",
                "app.environment",
            ],
            configurations: [communicationConfiguration("receiver", subscribes: true)])
    }
}

@Test func gatewayRejectsMismatchedMetadataAndForgedInternalSource() async throws {
    let manager = AgentManager()
    let gateway = InputGateway(manager: manager, allowsExternalSend: true)
    let input = AgentInput(
        sessionID: UUID(), payload: .text("hello"), metadata: InputMetadata(payload: .event("wrong kind")))
    await #expect(throws: CommunicationError.invalidPayload) { try await gateway.send(input, to: .assistant) }
    let forged = AgentInput(
        sessionID: UUID(), payload: .text("hello"),
        metadata: InputMetadata(payload: .text("hello"), source: "speechPerception", incarnation: UUID()))
    await #expect(throws: CommunicationError.unauthorized) { try await gateway.send(forged, to: .assistant) }
}

@Test func domainValueErrorsPreserveCommunicationAdmissionRejection() throws {
    #expect(throws: SpeechValidationError.invalidRequest) { try SpeechSynthesisInput(text: "") }
    #expect(throws: VisionValidationError.invalidObservation) {
        try PoseObservation(width: 0, height: 480, sequence: 1, timestamp: 0, rotation: 0, people: [])
    }
    // Codable construction does not use the validating initializer: transport must still validate.
    let request = try JSONDecoder().decode(
        SpeechSynthesisInput.self,
        from: Data("{\"audioID\":\"00000000-0000-0000-0000-000000000001\",\"text\":\"\",\"locale\":\"auto\"}".utf8))
    #expect(throws: CommunicationError.invalidPayload) { try AgentMessage.speechSynthesis(request).validatedSize() }
    let pose = try JSONDecoder().decode(
        PoseObservation.self,
        from: Data("{\"width\":0,\"height\":480,\"sequence\":1,\"timestamp\":0,\"rotation\":0,\"people\":[]}".utf8))
    #expect(throws: CommunicationError.invalidPayload) { try AgentMessage.pose(pose).validatedSize() }
    let valid = AgentMessage.speechSynthesis(try SpeechSynthesisInput(text: "hello", locale: "en-US"))
    #expect(try JSONDecoder().decode(PerceptionMessage.self, from: valid.encodedContent()) == valid.perception)
    #expect(try valid.validatedSize() > 0)
}

private struct RegisteredFixtureMessage: Codable, Sendable, Equatable { let value: Int }
private func registeredFixtureContract(
    lifetime: TimeInterval = 2, startsNewWork: Bool = false, maximumBytes: Int = 64
) -> CommunicationContract {
    CommunicationContract(
        name: "fixture.custom", kind: .observation, lifetime: lifetime, maximumBytes: maximumBytes,
        startsNewWork: startsNewWork,
        validateMessage: { message in
            guard let value = message.content(as: RegisteredFixtureMessage.self), value.value >= 0 else {
                throw CommunicationError.invalidPayload
            }
        })
}
private func registeredFixtureConfiguration(
    _ id: String, contracts: CommunicationContracts, publishes: Bool
) throws -> AgentConfiguration {
    try AgentConfiguration(
        contracts: contracts,
        data: JSONSerialization.data(withJSONObject: [
            "version": 6, "id": id, "actions": [String: [String]](), "tools": [],
            "communication": [
                "inputs": [["contract": "fixture.custom", "version": 1, "kind": "observation"]],
                "subscriptions": publishes
                    ? [] : [["contract": "fixture.custom", "topic": "fixture.custom", "source": "producer"]],
                "publications": publishes ? ["fixture.custom"] : [], "sends": [],
            ],
        ]))
}

@Test(arguments: [false, true])
func registeredMessagesRouteAndUseDeclaredDeadlinePolicy(startsNewWork: Bool) async throws {
    let contracts = try CommunicationContracts(additional: [registeredFixtureContract(startsNewWork: startsNewWork)])
    let policy = try CommunicationPolicy(
        contracts: contracts,
        configurations: [
            registeredFixtureConfiguration("producer", contracts: contracts, publishes: true),
            registeredFixtureConfiguration("receiver", contracts: contracts, publishes: false),
        ])
    let manager = AgentManager()
    let session = UUID()
    let producer = ObservationRecorder(id: "producer")
    let receiver = ObservationRecorder(id: "receiver")
    for agent in [producer, receiver] {
        try await manager.register(agent, sessionID: session)
        await agent.start()
    }
    let gateway = InputGateway(manager: manager, policy: policy, allowsExternalSend: true)
    let output = OutputGateway(
        manager: manager, requests: gateway, tools: ToolRegistry(), policy: policy, sink: { _ in })
    let port = try await output.messaging(for: producer.descriptor.id)
    let payload = InputPayload.event("parent")
    let expired = AgentInput(
        sessionID: session, payload: payload,
        metadata: InputMetadata(payload: payload, deadline: .now.advanced(by: .seconds(-1))))
    let admittedAfter = ContinuousClock.now
    let content = RegisteredFixtureMessage(value: 7)
    let message = AgentMessage(contract: "fixture.custom", content: content, validate: { _ in })
    if startsNewWork {
        try await port.publish(message, parent: expired)
    } else {
        await #expect(throws: CommunicationError.expired) { try await port.publish(message, parent: expired) }
        try await port.publish(message, parent: AgentInput(sessionID: session, payload: payload))
    }
    await gateway.flushPublications()
    let delivered = try #require(await receiver.inputs.first)
    guard case .observation(let received) = delivered.payload else {
        Issue.record("Missing generic message")
        return
    }
    #expect(received.content(as: RegisteredFixtureMessage.self) == content)
    #expect(received.perception == nil)
    // Check the assigned deadline, independent of how long a loaded test executor takes to resume.
    #expect(delivered.metadata.deadline > admittedAfter)
    #expect(delivered.metadata.deadline <= ContinuousClock.now.advanced(by: .seconds(2)))
    await manager.stopAll()
}

@Test func registeredSchemasRejectUnknownSpoofedOversizedAndInvalidAssembly() throws {
    let contracts = try CommunicationContracts(additional: [registeredFixtureContract()])
    let spoof = AgentMessage(contract: "fixture.custom", content: "wrong type", validate: { _ in })
    #expect(throws: CommunicationError.invalidPayload) { try contracts.validatedSize(spoof) }
    let invalid = AgentMessage(
        contract: "fixture.custom", content: RegisteredFixtureMessage(value: -1), validate: { _ in })
    #expect(throws: CommunicationError.invalidPayload) { try contracts.validatedSize(invalid) }
    let unknown = AgentMessage(
        contract: "fixture.unknown", content: RegisteredFixtureMessage(value: 1), validate: { _ in })
    #expect(throws: CommunicationError.unsupportedContract) { try contracts.validatedSize(unknown) }
    let tiny = try CommunicationContracts(additional: [registeredFixtureContract(maximumBytes: 4)])
    let large = AgentMessage(
        contract: "fixture.custom", content: RegisteredFixtureMessage(value: 1), validate: { _ in })
    #expect(throws: CommunicationError.invalidPayload) { try tiny.validatedSize(large) }
    #expect(throws: CommunicationError.invalidPayload) {
        try CommunicationContracts(additional: [CommunicationContract(name: "fixture.custom", kind: .text)])
    }
    #expect(throws: CommunicationError.invalidPayload) {
        try CommunicationContracts(additional: [registeredFixtureContract(), registeredFixtureContract()])
    }
    #expect(throws: CommunicationError.invalidPayload) {
        try CommunicationContracts(additional: [registeredFixtureContract(lifetime: .nan)])
    }
    #expect(throws: CommunicationError.invalidPayload) {
        try CommunicationContracts(additional: [CommunicationContract(name: "fixture.custom", kind: .observation)])
    }
}

@Test(.timeLimit(.minutes(1))) func publicationReturnsBeforeSubscribersFinishAndShutdownJoinsDelivery() async throws {
    let session = UUID()
    let manager = AgentManager()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication,
        externalSources: ["user"],
        configurations: [
            communicationConfiguration("producer", publishes: true),
            communicationConfiguration("consumer", subscribes: true), communicationConfiguration("direct"),
        ])
    let source = ObservationRecorder(id: "producer")
    let receiver = ObservationRecorder(id: "consumer", blockText: "blocked")
    for agent in [source, receiver] {
        try await manager.register(agent, sessionID: session)
        await agent.start()
    }
    let input = InputGateway(manager: manager, policy: policy, allowsExternalSend: true)
    let output = OutputGateway(manager: manager, requests: input, tools: ToolRegistry(), policy: policy, sink: { _ in })
    let port = try await output.messaging(for: source.descriptor.id)
    let started = ContinuousClock.now
    try await port.publish(
        .transcript("blocked", final: true), parent: AgentInput(sessionID: session, payload: .text("parent")))
    #expect(started.duration(to: .now) < .seconds(2))
    var admissions = receiver.admissions.stream.makeAsyncIterator()
    #expect(await admissions.next() != nil)
    #expect(await receiver.inputs.isEmpty)
    // A missing subscriber is a valid publication; no receipt or producer-history feedback appears.
    try await port.publish(
        .transcript("partial", final: false), parent: AgentInput(sessionID: session, payload: .text("parent")))
    #expect(await port.history.snapshot().isEmpty)
    await output.shutdown()
    #expect(await source.status().lifecycle == .running)
    #expect(await receiver.inputs.isEmpty)
    await manager.stopAll()
}

@Test func signalLogPublicationRecordsBranchesWithoutPublisherAcknowledgment() async throws {
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, externalSources: ["producer"],
        configurations: [
            communicationConfiguration("consumer", subscribes: true),
            communicationConfiguration("reject", subscribes: true),
        ])
    let manager = AgentManager()
    let consumer = ObservationRecorder(id: "consumer")
    let rejected = ObservationRecorder(id: "reject", reject: true)
    for agent in [consumer, rejected] {
        try await manager.register(agent)
        await agent.start()
    }
    let gateway = InputGateway(manager: manager, policy: policy)
    let payload = InputPayload.observation(.transcript("hello", final: true))
    let input = AgentInput(
        sessionID: UUID(), payload: payload, metadata: InputMetadata(payload: payload, source: "producer"))
    try await gateway.publish(input)
    await gateway.flushPublications()
    var iterator = try await gateway.observeSignals().makeAsyncIterator()
    let snapshot = try #require(await iterator.next())
    let record = try #require(snapshot.records.first)
    #expect(snapshot.records.count == 1)
    #expect(record.id == input.id && record.mode == .publish && record.phase == .partial)
    #expect(record.branches.first { $0.target.rawValue == "consumer" }?.phase == .accepted)
    #expect(record.branches.first { $0.target.rawValue == "reject" }?.reason == "queueFull")
    #expect(await consumer.inputs.count == 1)
    await gateway.shutdown()
    _ = await iterator.next()
    #expect(await iterator.next() == nil)
}

@Test func signalLogBoundsHistoryAndAggregatesOnlyMatchingOutcomes() async throws {
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, externalSources: ["producer"],
        configurations: [communicationConfiguration("consumer")])
    let gateway = InputGateway(manager: AgentManager(), policy: policy, signalAggregation: { _ in true })
    let session = UUID()
    for _ in 0..<10 {
        let payload = InputPayload.observation(.transcript("partial", final: false))
        try await gateway.publish(
            .init(sessionID: session, payload: payload, metadata: .init(payload: payload, source: "producer")))
    }
    var iterator = try await gateway.observeSignals().makeAsyncIterator()
    let aggregate = try #require(await iterator.next())
    #expect(aggregate.records.count == 1)
    #expect(aggregate.records.first?.count == 10)
    #expect(aggregate.records.first?.phase == .unobserved)
    for _ in 0..<270 {
        let payload = InputPayload.observation(.transcript("partial", final: false))
        try await gateway.publish(
            .init(sessionID: UUID(), payload: payload, metadata: .init(payload: payload, source: "producer")))
    }
    let bounded = try #require(await iterator.next())
    #expect(bounded.records.count == 256 && bounded.evictedCount == 15)
    await gateway.shutdown()
}

@Test func signalLogDroppedPublicationRetainsFailureWithoutBackpressureResponse() async throws {
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, externalSources: ["producer"],
        configurations: [communicationConfiguration("consumer", subscribes: true)])
    let manager = AgentManager()
    let consumer = ObservationRecorder(id: "consumer", blockText: "block")
    try await manager.register(consumer)
    await consumer.start()
    let gateway = InputGateway(manager: manager, policy: policy)
    for _ in 0..<129 {
        let payload = InputPayload.observation(.transcript("block", final: true))
        try await gateway.publish(
            .init(sessionID: UUID(), payload: payload, metadata: .init(payload: payload, source: "producer")))
    }
    var iterator = try await gateway.observeSignals().makeAsyncIterator()
    let snapshot = try #require(await iterator.next())
    #expect(snapshot.records.contains { $0.phase == .dropped })
    await gateway.shutdown()
}

@Test func taskObservationIgnoresOrdinaryTrafficAndRetainsIndependentHistory() async throws {
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, externalSources: ["producer"],
        configurations: [communicationConfiguration("consumer")])
    let gateway = InputGateway(manager: AgentManager(), policy: policy)
    var observation = try await gateway.observeTasks().makeAsyncIterator()
    #expect(await observation.next()?.revision == 0)
    for _ in 0..<300 {
        let payload = InputPayload.observation(.transcript("partial", final: false))
        try await gateway.publish(
            .init(sessionID: UUID(), payload: payload, metadata: .init(payload: payload, source: "producer")))
    }
    var afterTraffic = try await gateway.observeTasks().makeAsyncIterator()
    let quiet = try #require(await afterTraffic.next())
    #expect(quiet.revision == 0 && quiet.records.isEmpty && quiet.evictedCount == 0)
    // A pending observer must not receive a media/ordinary update, even at shutdown.
    await gateway.shutdown()
    #expect(await observation.next() == nil)
    #expect(await afterTraffic.next() == nil)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func publicationDoesNotWaitForAppObserverOrTurnItsFailureIntoAReceipt(blocking: Bool) async throws {
    let session = UUID()
    let manager = AgentManager()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, externalSources: ["user"],
        configurations: [
            communicationConfiguration("producer", publishes: true),
            communicationConfiguration("consumer", subscribes: true),
            communicationConfiguration("direct"),
        ])
    let producer = ObservationRecorder(id: "producer")
    let consumer = ObservationRecorder(id: "consumer")
    for agent in [producer, consumer] {
        try await manager.register(agent, sessionID: session)
        await agent.start()
    }
    let observed = AsyncStream<UUID>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let input = InputGateway(manager: manager, policy: policy)
    let output = OutputGateway(
        manager: manager, requests: input, tools: ToolRegistry(), policy: policy,
        observedContracts: ["speech.final"],
        observeEvent: { value in
            observed.continuation.yield(value.id)
            if blocking { try await Task.sleep(for: .seconds(30)) }
            throw HarnessError.queueFull
        }, sink: { _ in })
    let port = try await output.messaging(for: producer.descriptor.id)
    let start = ContinuousClock.now
    try await port.publish(
        .transcript("hello", final: true),
        parent: AgentInput(sessionID: session, payload: .text("parent")))
    #expect(start.duration(to: .now) < .seconds(2))
    var observations = observed.stream.makeAsyncIterator()
    #expect(await observations.next() != nil)
    var admissions = consumer.admissions.stream.makeAsyncIterator()
    #expect(await admissions.next() != nil)
    #expect(await port.history.snapshot().isEmpty)
    #expect(await producer.inputs.isEmpty)
    await output.shutdown()
    await manager.stopAll()
}

@Test(.timeLimit(.minutes(1))) func publicationOverflowDoesNotWaitForDiagnosticCallbacks() async throws {
    let session = UUID()
    let manager = AgentManager()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, externalSources: ["user"],
        configurations: [
            communicationConfiguration("producer", publishes: true),
            communicationConfiguration("direct"),
        ])
    let producer = ObservationRecorder(id: "producer")
    try await manager.register(producer, sessionID: session)
    await producer.start()
    let input = InputGateway(
        manager: manager, policy: policy,
        publicationFailure: { _, _, _ in
            Issue.record("Overflow diagnostics must not call back into the publisher path")
        })
    let output = OutputGateway(
        manager: manager, requests: input, tools: ToolRegistry(), policy: policy,
        observedContracts: ["speech.partial"],
        observeEvent: { _ in
            try await Task.sleep(for: .seconds(30))
        }, sink: { _ in })
    let port = try await output.messaging(for: producer.descriptor.id)
    let observations = try await input.observeSignals()
    let start = ContinuousClock.now
    for _ in 0..<129 {
        try await port.publish(
            .transcript("preview", final: false),
            parent: AgentInput(sessionID: session, payload: .text("parent")))
    }
    #expect(start.duration(to: .now) < .seconds(2))
    var snapshots = observations.makeAsyncIterator()
    let latest = try #require(await snapshots.next())
    #expect(latest.records.last?.phase == .dropped)
    #expect(await port.history.snapshot().isEmpty)
    await output.shutdown()
    await manager.stopAll()
}

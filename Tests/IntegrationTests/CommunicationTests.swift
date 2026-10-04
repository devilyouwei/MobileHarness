import AgentCore
import Agents
import Foundation
import Gateway
import Testing
import ToolRuntime
import Tools
import Types

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
            "version": 5, "id": id, "actions": [String: [String]](), "tools": [],
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
        externalSources: ["user", "runtime", "phone.microphone", "phone.camera"], configurations: configurations)
    let manager = AgentManager()
    let source = ObservationRecorder(id: "producer")
    let consumer = ObservationRecorder(id: "consumer")
    let direct = ObservationRecorder(id: "direct")
    let session = UUID()
    for agent in [source, consumer, direct] {
        try await manager.register(agent, sessionID: session)
        await agent.start()
    }
    let input = InputGateway(manager: manager, policy: policy)
    let output = OutputGateway(
        manager: manager, requests: input, tools: ToolRegistry(), policy: policy, sink: { _ in })
    let port = try await output.messaging(for: source.descriptor.id)
    let parent = AgentInput(sessionID: session, payload: .text("source"))
    let published = try await port.publish(.transcript("hello", final: true), parent: parent)
    #expect(published.delivered == [consumer.descriptor.id])
    #expect(await direct.inputs.isEmpty)
    let sent = try await port.send(.transcript("direct", final: true), parent: parent, to: direct.descriptor.id)
    #expect(sent.delivered == [direct.descriptor.id])
    await #expect(throws: CommunicationError.unauthorized) {
        try await port.send(.transcript("forbidden", final: true), parent: parent, to: consumer.descriptor.id)
    }
    await #expect(throws: CommunicationError.noRecipients) {
        try await port.publish(.transcript("preview", final: false), parent: parent)
    }
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
        externalSources: ["user", "runtime", "phone.microphone", "phone.camera"],
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
    let input = InputGateway(manager: manager, policy: policy)
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
        externalSources: ["user", "runtime", "phone.microphone", "phone.camera"],
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
    let input = InputGateway(manager: manager, policy: policy)
    let output = OutputGateway(manager: manager, requests: input, tools: ToolRegistry(), policy: policy, sink: { _ in })
    let port = try await output.messaging(for: source.descriptor.id)
    let report = try await port.publish(
        .transcript("hello", final: true), parent: AgentInput(sessionID: session, payload: .text("parent")))
    #expect(report.delivered == [good.descriptor.id])
    #expect(report.rejected[full.descriptor.id] == String(describing: HarnessError.queueFull))
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
    root["version"] = 5
    root["communication"] = ["inputs": [], "subscriptions": [], "publications": [], "sends": [], "requests": []]
    #expect(throws: AgentConfigurationError.self) {
        try AgentConfiguration(
            contracts: AgentContracts.communication, data: JSONSerialization.data(withJSONObject: root))
    }
    #expect(throws: CommunicationError.unauthorized) {
        try CommunicationPolicy(
            contracts: AgentContracts.communication,
            externalSources: ["user", "runtime", "phone.microphone", "phone.camera"],
            configurations: [communicationConfiguration("receiver", subscribes: true)])
    }
}

@Test func gatewayRejectsMismatchedMetadataAndForgedInternalSource() async throws {
    let manager = AgentManager()
    let gateway = InputGateway(manager: manager)
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
    lifetime: TimeInterval = 0.2, startsNewWork: Bool = false, maximumBytes: Int = 64
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
            "version": 5, "id": id, "actions": [String: [String]](), "tools": [],
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
    let gateway = InputGateway(manager: manager, policy: policy)
    let output = OutputGateway(
        manager: manager, requests: gateway, tools: ToolRegistry(), policy: policy, sink: { _ in })
    let port = try await output.messaging(for: producer.descriptor.id)
    let payload = InputPayload.event("parent")
    let expired = AgentInput(
        sessionID: session, payload: payload,
        metadata: InputMetadata(payload: payload, deadline: .now.advanced(by: .seconds(-1))))
    let content = RegisteredFixtureMessage(value: 7)
    let message = AgentMessage(contract: "fixture.custom", content: content, validate: { _ in })
    if startsNewWork {
        let report = try await port.publish(message, parent: expired)
        #expect(report.delivered == [receiver.descriptor.id])
    } else {
        await #expect(throws: CommunicationError.expired) { try await port.publish(message, parent: expired) }
        let report = try await port.publish(message, parent: AgentInput(sessionID: session, payload: payload))
        #expect(report.delivered == [receiver.descriptor.id])
    }
    let delivered = try #require(await receiver.inputs.first)
    guard case .observation(let received) = delivered.payload else {
        Issue.record("Missing generic message")
        return
    }
    #expect(received.content(as: RegisteredFixtureMessage.self) == content)
    #expect(received.perception == nil)
    let remaining = ContinuousClock.now.duration(to: delivered.metadata.deadline)
    #expect(remaining > .zero && remaining <= .milliseconds(200))
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

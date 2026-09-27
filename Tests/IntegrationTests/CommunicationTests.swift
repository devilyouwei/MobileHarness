import AgentCore
import Foundation
import Gateway
import Testing
import ToolRuntime

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
        data: JSONSerialization.data(withJSONObject: [
            "schemaVersion": 4, "agentID": id, "channels": [], "textActions": [], "actions": [], "tools": [],
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
        if case .observation(.transcript(let text, _)) = input.payload, text == blockText {
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
    let policy = try CommunicationPolicy(configurations: configurations)
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
    let policy = try CommunicationPolicy(configurations: [
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
    let policy = try CommunicationPolicy(configurations: [
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
        "schemaVersion": 3, "agentID": "receiver", "channels": [], "textActions": [], "actions": [], "tools": [],
        "communication": ["inputs": [], "subscriptions": [], "publications": [], "sends": []],
    ]
    #expect(throws: AgentConfigurationError.unsupportedVersion(3)) {
        try AgentConfiguration(data: JSONSerialization.data(withJSONObject: root))
    }
    root["schemaVersion"] = 4
    root["communication"] = ["inputs": [], "subscriptions": [], "publications": [], "sends": [], "requests": []]
    #expect(throws: AgentConfigurationError.self) {
        try AgentConfiguration(data: JSONSerialization.data(withJSONObject: root))
    }
    #expect(throws: CommunicationError.unauthorized) {
        try CommunicationPolicy(configurations: [communicationConfiguration("receiver", subscribes: true)])
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

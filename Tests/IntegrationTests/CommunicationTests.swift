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
    init(id: String, reject: Bool = false) {
        self.reject = reject
        descriptor = AgentDescriptor(id: AgentID(rawValue: id), name: id, inputs: [.observation], outputs: [])
    }
    func start() { lifecycle = .running }
    func pause() { lifecycle = .paused }
    func resume() { lifecycle = .running }
    func stop() { lifecycle = .stopped }
    func status() -> AgentStatus { AgentStatus(lifecycle: lifecycle, queuedInputs: 0, processedInputs: inputs.count) }
    func receive(_ input: AgentInput) throws {
        guard lifecycle == .running else { throw HarnessError.notRunning }
        guard !reject else { throw HarnessError.queueFull }
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
    let bus = InternalSignalBus { value, target, incarnation in
        try await input.receiveInternal(value, target: target, incarnation: incarnation)
    }
    try await bus.openSession(session)
    let output = OutputGateway(
        manager: manager, requests: input, tools: ToolRegistry(), policy: policy, bus: bus, sink: { _ in })
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
    await bus.closeSession(session)
    await bus.shutdown()
    await manager.stopAll()
}

@Test func highFrequencyStatesDoNotConsumeDiscreteDeduplicationCapacity() async throws {
    let target = AgentID(rawValue: "consumer")
    let incarnation = UUID()
    let session = UUID()
    let recorder = ObservationRecorder(id: "consumer")
    await recorder.start()
    let bus = InternalSignalBus { input, _, _ in try await recorder.receive(input) }
    try await bus.openSession(session)
    for sequence in 0..<1100 {
        let payload = InputPayload.observation(.transcript("preview", final: false))
        let input = AgentInput(
            sessionID: session, payload: payload, metadata: InputMetadata(payload: payload, sequence: UInt64(sequence)))
        let report = try await bus.publish(input, targets: [(target, incarnation)])
        #expect(report.delivered == [target])
    }
    #expect(await recorder.inputs.count == 1100)
    await bus.closeSession(session)
    let input = AgentInput(sessionID: session, payload: .observation(.transcript("done", final: true)))
    await #expect(throws: CommunicationError.scopeClosed) {
        try await bus.publish(input, targets: [(target, incarnation)])
    }
}

@Test func eventFanoutRejectsOneDestinationWithoutSuppressingOthers() async throws {
    let session = UUID()
    let good = AgentID(rawValue: "good")
    let bad = AgentID(rawValue: "bad")
    let bus = InternalSignalBus { _, target, _ in if target == bad { throw HarnessError.queueFull } }
    try await bus.openSession(session)
    let input = AgentInput(sessionID: session, payload: .observation(.transcript("hello", final: true)))
    let result = try await bus.publish(input, targets: [(good, UUID()), (bad, UUID())])
    #expect(result.delivered == [good])
    #expect(result.rejected[bad] != nil)
    await #expect(throws: CommunicationError.messageConflict) {
        try await bus.publish(input, targets: [(good, UUID())])
    }
    let expired = AgentInput(
        sessionID: session, payload: input.payload,
        metadata: InputMetadata(payload: input.payload, deadline: .now.advanced(by: .seconds(-1))))
    await #expect(throws: CommunicationError.expired) { try await bus.publish(expired, targets: [(good, UUID())]) }
    await bus.shutdown()
}

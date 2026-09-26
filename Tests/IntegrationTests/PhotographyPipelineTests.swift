import ActionRuntime
import Actions
import AgentCore
import Agents
import Foundation
import Gateway
import ModelKit
import Testing
import ToolRuntime

private func image(_ value: UInt8, sequence: UInt64, rotation: Int = 1) throws -> ImageInput {
    try ImageInput(
        width: 4, height: 4, rgb: Data(repeating: value, count: 48),
        sequence: sequence, timestamp: Double(sequence), rotation: rotation)
}

@Test func grayscaleThresholdUsesPreviousExaminedFrame() throws {
    var filter = FrameChangeFilter(configuration: try FrameChangeConfiguration())
    #expect(try filter.accepts(image(0, sequence: 1)))
    #expect(try !filter.accepts(image(0, sequence: 2)))
    #expect(try !filter.accepts(image(7, sequence: 3)))  // 7/255 < 3%
    #expect(try !filter.accepts(image(14, sequence: 4)))  // Baseline advanced to 7, not last admitted 0.
    #expect(try filter.accepts(image(22, sequence: 5)))  // 8/255 > 3%
    #expect(throws: ImageInputError.outOfOrder) { try filter.accepts(image(22, sequence: 5)) }
    #expect(try filter.accepts(image(22, sequence: 6, rotation: 2)))
    #expect(throws: ImageInputError.invalidFrame) { try FrameChangeConfiguration(minimumChange: .nan) }
    #expect(throws: ImageInputError.invalidFrame) { try FrameChangeConfiguration(minimumChange: 1.1) }
    var zero = FrameChangeFilter(configuration: try FrameChangeConfiguration(minimumChange: 0))
    #expect(try zero.accepts(image(10, sequence: 1)))
    #expect(try !zero.accepts(image(10, sequence: 2)))
}

@Test func grayscaleIntervalDoesNotAdvanceComparisonBaseline() throws {
    var filter = FrameChangeFilter(configuration: try FrameChangeConfiguration(minimumInterval: 1))
    let first = try ImageInput(width: 1, height: 1, rgb: Data([0, 0, 0]), sequence: 1, timestamp: 0, rotation: 0)
    let skipped = try ImageInput(
        width: 1, height: 1, rgb: Data([100, 100, 100]), sequence: 2, timestamp: 0.5, rotation: 0)
    let next = try ImageInput(width: 1, height: 1, rgb: Data([100, 100, 100]), sequence: 3, timestamp: 1, rotation: 0)
    #expect(try filter.accepts(first))
    #expect(try !filter.accepts(skipped))
    #expect(try filter.accepts(next))
}

/// Gate each inference explicitly so mailbox/cancellation tests do not depend on model speed.
private actor ControlledPose: PoseCapability {
    nonisolated let availability: CapabilityAvailability = .available
    nonisolated let started: AsyncStream<UInt8>
    private let continuation: AsyncStream<UInt8>.Continuation
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var calls: [UInt8] = []
    private(set) var active = 0
    private(set) var maximumActive = 0
    init() {
        let pair = AsyncStream<UInt8>.makeStream(bufferingPolicy: .bufferingOldest(16))
        started = pair.stream
        continuation = pair.continuation
    }
    func estimatePose(_ request: PoseRequest) async throws -> PoseResult {
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        let value = request.image.rgb?.first ?? 0
        calls.append(value)
        await withCheckedContinuation { waiter in
            self.waiter = waiter
            continuation.yield(value)
        }
        return PoseResult(context: request.context, people: [])
    }
    func release() {
        waiter?.resume()
        waiter = nil
    }
}

@Test(.timeLimit(.minutes(1))) func visionKeepsOnlyLatestAndNeverOverlapsOrReplays() async throws {
    let model = ControlledPose()
    let session = UUID()
    let agent = try VisionPerceptionAgent(
        pose: model, sessionID: session, sampling: FrameChangeConfiguration(minimumChange: 0))
    let observations = AsyncStream<PerceptionObservation>.makeStream(bufferingPolicy: .bufferingOldest(8))
    try await agent.bind(
        AgentMessaging { value, _, _ in
            observations.continuation.yield(value)
            return DeliveryReport(delivered: [.photographer])
        })
    try await agent.start()
    var started = model.started.makeAsyncIterator()
    try await agent.receive(AgentInput(sessionID: session, payload: .image(image(1, sequence: 1))))
    #expect(await started.next() == 1)
    try await agent.receive(AgentInput(sessionID: session, payload: .image(image(2, sequence: 2))))
    try await agent.receive(AgentInput(sessionID: session, payload: .image(image(3, sequence: 3))))
    #expect(await agent.status().queuedInputs == 1)
    await #expect(throws: ImageInputError.outOfOrder) {
        try await agent.receive(AgentInput(sessionID: session, payload: .image(image(3, sequence: 3))))
    }
    await model.release()
    #expect(await started.next() == 3)
    await model.release()
    var stream = observations.stream.makeAsyncIterator()
    for sequence: UInt64 in [1, 3] {
        guard case .pose(let pose) = try #require(await stream.next()) else {
            Issue.record("Missing pose")
            return
        }
        #expect(pose.sequence == sequence)
    }
    #expect(await model.calls == [1, 3])
    #expect(await model.maximumActive == 1)
    #expect(await agent.replacements == 1)
    await agent.stop()
}

@Test(.timeLimit(.minutes(1))) func visionPauseKeepsLatestAndStopSuppressesLateModelOutput() async throws {
    let model = ControlledPose()
    let session = UUID()
    let agent = try VisionPerceptionAgent(
        pose: model, sessionID: session, sampling: FrameChangeConfiguration(minimumChange: 0))
    try await agent.bind(
        AgentMessaging { _, _, _ in
            Issue.record("Late output")
            return DeliveryReport()
        })
    try await agent.start()
    try await agent.pause()
    try await agent.receive(AgentInput(sessionID: session, payload: .image(image(1, sequence: 1))))
    try await agent.receive(AgentInput(sessionID: session, payload: .image(image(2, sequence: 2))))
    #expect(await model.calls.isEmpty)
    try await agent.resume()
    var started = model.started.makeAsyncIterator()
    #expect(await started.next() == 2)
    let stopping = Task { await agent.stop() }
    for _ in 0..<1000 {
        if await agent.status().lifecycle == .stopped { break }
        await Task.yield()
    }
    #expect(await agent.status().lifecycle == .stopped)
    await model.release()
    await stopping.value
    var output = agent.outputs.makeAsyncIterator()
    #expect(await output.next() == nil)
}

private struct EmptyPose: PoseCapability {
    var availability: CapabilityAvailability { .available }
    func estimatePose(_ request: PoseRequest) async throws -> PoseResult {
        PoseResult(context: request.context, people: [])
    }
}
private actor OverlayRecorder {
    var sequences: [UInt64] = []
    func record(_ value: UInt64) { sequences.append(value) }
}

@Test(.timeLimit(.minutes(1))) func sharedPoseFeedsTwoSubscribersWithOneInferenceAndClearsOverlay() async throws {
    let session = UUID()
    let manager = AgentManager()
    let model = ControlledPose()
    let photo = try PhotographerAgent(sessionID: session)
    let vision = try VisionPerceptionAgent(pose: model, sessionID: session)
    let second = ObservationRecorder(id: "second")
    let secondConfig = try AgentConfiguration(
        data: JSONSerialization.data(withJSONObject: [
            "schemaVersion": 4, "agentID": "second", "actions": [], "tools": [], "channels": [], "textActions": [],
            "communication": [
                "inputs": [["contract": "vision.pose", "version": 1, "kind": "observation"]],
                "subscriptions": [["contract": "vision.pose", "source": "visionPerception", "topic": "vision.pose"]],
                "publications": [], "sends": [],
            ],
        ]))
    let policy = try CommunicationPolicy(configurations: [
        AgentConfigurations.load(named: "Photographer"),
        AgentConfigurations.load(named: "VisionPerception"), secondConfig,
    ])
    try await manager.register(photo, sessionID: session)
    try await manager.register(vision, sessionID: session)
    try await manager.register(second, sessionID: session)
    await second.start()
    let input = InputGateway(manager: manager, policy: policy)
    let bus = InternalSignalBus { value, target, incarnation in
        try await input.receiveInternal(value, target: target, incarnation: incarnation)
    }
    try await bus.openSession(session)
    let recorder = OverlayRecorder()
    let actions = ChannelScheduler(
        registry: ActionRegistry(handlers: [
            ActionPath(module: "UI", function: "showPose"): { invocation in
                try await UIActions.showPose(invocation: invocation) { overlay, _ in
                    #expect(overlay.people.isEmpty)
                    await recorder.record(overlay.sequence)
                }
            }
        ]), maximumTrackedInputs: 1)
    let output = OutputGateway(
        manager: manager, requests: input, tools: ToolRegistry(), actions: actions, policy: policy, bus: bus,
        sink: { _ in })
    try await vision.bind(output.messaging(for: .visionPerception))
    try await photo.start()
    try await vision.start()
    var envelopes = photo.outputs.makeAsyncIterator()
    var started = model.started.makeAsyncIterator()
    for i: UInt64 in 1...3 {
        let report = try await input.publish(
            AgentInput(sessionID: session, payload: .image(image(UInt8(i * 40), sequence: i))))
        #expect(report.delivered == [.visionPerception])
        #expect(await started.next() == UInt8(i * 40))
        await model.release()
        for _ in 0..<2 { try await output.dispatch(try #require(await envelopes.next())) }
    }
    #expect(await recorder.sequences == [1, 2, 3])
    #expect(await second.inputs.count == 3)
    #expect(await model.calls.count == 3)
    await manager.stopAll()
    await bus.closeSession(session)
    await output.shutdown()
}

@Test func poseActionRejectsMalformedPayloadBeforePresentation() async throws {
    let input = AgentInput(sessionID: UUID(), payload: .text("test"))
    let call = ActionCall(
        actionPath: ActionPath(module: "UI", function: "showPose"), channel: "Vision",
        parameters: ["payload": "{\"sequence\":1,\"timestamp\":0,\"rotation\":9,\"people\":[]}"])
    let invocation = ActionInvocation(
        envelope: OutputEnvelope(source: .photographer, input: input, output: .actionCall(call)), call: call)
    await #expect(throws: UIActions.PoseError.invalidPayload) {
        try await UIActions.showPose(invocation: invocation) { _, _ in Issue.record("Invalid pose reached UI") }
    }
    let point = PoseOverlay.Joint(x: 2500, y: 7500, confidence: 1000)
    #expect(point.sensorPoint(rotation: 0).x == 0.25)
    #expect(point.sensorPoint(rotation: 1).x == 0.75)
    #expect(point.sensorPoint(rotation: 1).y == 0.75)
    #expect(point.sensorPoint(rotation: 2).y == 0.25)
    #expect(point.sensorPoint(rotation: 3).x == 0.25)
}

@Test func actionOnlyGeneratorUsesConfigurationAndRejectsUnmappedText() throws {
    let configuration = try AgentConfigurations.load(named: "Photographer")
    var generator = try AgentGenerator(capabilities: configuration.capabilities, textActions: [])
    let calls = try generator.append("<showPose payload='{}'/>") + generator.finish()
    #expect(calls.count == 1)
    #expect(calls[0].channel == "Vision")
    var text = try AgentGenerator(capabilities: configuration.capabilities, textActions: [])
    #expect(throws: GenerationError.unknownCapability) { try text.append("unexpected prose") }
}

private func poseInput(session: UUID, sequence: UInt64 = 1, people: Int = 8) throws -> AgentInput {
    let joints = (0..<17).map { _ in PoseObservation.Joint(x: 2, y: 3, confidence: 0.9) }
    return AgentInput(
        sessionID: session,
        payload: .observation(
            .pose(
                try PoseObservation(
                    width: 4, height: 4,
                    sequence: sequence, timestamp: Double(sequence), rotation: 1,
                    people: Array(repeating: joints, count: people)))))
}

@Test(.timeLimit(.minutes(1))) func photographerCrowdFitsActionProtocolAndRejectsForeignSession() async throws {
    let session = UUID()
    let agent = try PhotographerAgent(sessionID: session)
    try await agent.start()
    await #expect(throws: ImageInputError.wrongSession) {
        try await agent.receive(poseInput(session: UUID()))
    }
    try await agent.receive(poseInput(session: session))
    var stream = agent.outputs.makeAsyncIterator()
    let envelope = try #require(await stream.next())
    guard case .actionCall(let call) = envelope.output else {
        Issue.record("Missing skeleton Action")
        return
    }
    #expect((call.parameters["payload"]?.utf8.count ?? Int.max) <= 3000)
    try await UIActions.showPose(invocation: ActionInvocation(envelope: envelope, call: call)) { overlay, _ in
        #expect(overlay.people.count == 6)
        #expect(overlay.people.allSatisfy { $0.count == 17 })
        #expect(overlay.people[0][0] == PoseOverlay.Joint(x: 5000, y: 7500, confidence: 900))
    }
    await agent.stop()
}

@Test(.timeLimit(.minutes(1))) func photographerOutputOverflowFailsInsteadOfReplacingActions() async throws {
    let session = UUID()
    let photo = try PhotographerAgent(sessionID: session)
    try await photo.start()
    for i: UInt64 in 1...5 {
        try await photo.receive(poseInput(session: session, sequence: i))
        for _ in 0..<1000 {
            let status = await photo.status()
            if status.processedInputs >= Int(i) || status.lifecycle == .failed { break }
            await Task.yield()
        }
    }
    #expect(await photo.status().lifecycle == .failed)
    await photo.stop()
}

private struct PoseImageAttachment: ImageAttachment { let image: ImageFrame }
@Test(.timeLimit(.minutes(1))) func visionResolvesOpaqueInputWithoutCopyingMediaIntoObservation() async throws {
    let model = ControlledPose()
    let session = UUID()
    let agent = try VisionPerceptionAgent(
        pose: model, sessionID: session,
        resolveImage: { input in
            guard case .sampled(_, let attachment) = input.content, let attachment = attachment as? PoseImageAttachment
            else {
                throw ImageInputError.invalidFrame
            }
            return attachment.image
        })
    let observed = AsyncStream<PerceptionObservation>.makeStream(bufferingPolicy: .bufferingOldest(1))
    try await agent.bind(
        AgentMessaging { value, _, _ in
            observed.continuation.yield(value)
            return DeliveryReport(delivered: [.photographer])
        })
    try await agent.start()
    let frame = try ImageInput(
        width: 4, height: 4, gray64: Data(repeating: 22, count: 4096),
        attachment: PoseImageAttachment(image: ImageFrame(width: 4, height: 4, rgb: Data(repeating: 22, count: 48))),
        sequence: 1, timestamp: 1, rotation: 0)
    try await agent.receive(AgentInput(sessionID: session, payload: .image(frame)))
    var started = model.started.makeAsyncIterator()
    #expect(await started.next() == 22)
    await model.release()
    var values = observed.stream.makeAsyncIterator()
    guard case .pose(let pose) = try #require(await values.next()) else {
        Issue.record("Missing pose")
        return
    }
    #expect(pose.rotation == 0 && pose.sequence == 1 && pose.people.isEmpty)
    await agent.stop()
}

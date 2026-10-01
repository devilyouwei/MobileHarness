import Actions
import AgentCore
import Agents
import Foundation
import Gateway
import ModelKit
import Testing
import Tools

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
            return DeliveryReport()
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
    var stream = observations.stream.makeAsyncIterator()
    let first = try #require(await stream.next())
    guard case .pose(let firstPose) = first else {
        Issue.record("Missing pose")
        return
    }
    #expect(firstPose.sequence == 1)
    #expect(await started.next() == 3)
    await model.release()
    for sequence: UInt64 in [3] {
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

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func sharedPosePublishesAndVisualizesWithoutRequiringSubscribers(withSubscribers: Bool) async throws {
    let session = UUID()
    let manager = AgentManager()
    let model = ControlledPose()
    let vision = try VisionPerceptionAgent(pose: model, sessionID: session)
    let second = ObservationRecorder(id: "second")
    let third = ObservationRecorder(id: "third")
    let secondConfig = try AgentConfiguration(
        data: JSONSerialization.data(withJSONObject: [
            "version": 5, "id": "second", "actions": [String: [String]](), "tools": [],
            "communication": [
                "inputs": [["contract": "vision.pose", "version": 1, "kind": "observation"]],
                "subscriptions": [["contract": "vision.pose", "source": "visionPerception", "topic": "vision.pose"]],
                "publications": [], "sends": [],
            ],
        ]))
    let thirdConfig = try AgentConfiguration(
        data: JSONSerialization.data(withJSONObject: [
            "version": 5, "id": "third", "actions": [String: [String]](), "tools": [],
            "communication": [
                "inputs": [["contract": "vision.pose", "version": 1, "kind": "observation"]],
                "subscriptions": [["contract": "vision.pose", "source": "visionPerception", "topic": "vision.pose"]],
                "publications": [], "sends": [],
            ],
        ]))
    let policy = try CommunicationPolicy(
        configurations: [AgentConfigurations.load(named: "VisionPerception")]
            + (withSubscribers ? [secondConfig, thirdConfig] : []))
    try await manager.register(third, sessionID: session)
    await third.start()
    try await manager.register(vision, sessionID: session)
    try await manager.register(second, sessionID: session)
    await second.start()
    let input = InputGateway(manager: manager, policy: policy)
    let recorder = OverlayRecorder()
    let actions = ChannelScheduler(registry: try testActionRegistry(handlers: [:]), maximumTrackedInputs: 1)
    let tools = ToolRegistry()
    try await tools.registerCompletion("UI.moveEyes") { call, envelope in
        try await UITools.moveEyes(invocation: ToolInvocation(call: call, context: envelope)) { target, _ in
            #expect(target.x == 0 && target.y == 0)
        }
    }
    try await tools.registerCompletion("UI.showPose") { call, envelope in
        try await UITools.showPose(call: call, context: envelope) { overlay, _ in
            #expect(overlay.people.isEmpty)
            await recorder.record(overlay.sequence)
        }
    }
    let output = OutputGateway(
        manager: manager, requests: input, tools: tools, actions: actions, policy: policy,
        sink: { _ in })
    try await vision.bind(output.messaging(for: .visionPerception))
    try await vision.start()
    var envelopes = vision.outputs.makeAsyncIterator()
    var started = model.started.makeAsyncIterator()
    for i: UInt64 in 1...3 {
        let report = try await input.publish(
            AgentInput(sessionID: session, payload: .image(image(UInt8(i * 40), sequence: i))))
        #expect(report.delivered == [.visionPerception])
        #expect(await started.next() == UInt8(i * 40))
        await model.release()
        for _ in 0..<2 {
            let envelope = try #require(await envelopes.next())
            #expect(envelope.source == .visionPerception)
            try await output.dispatch(envelope)
            if case .actionCall = envelope.output {
                try await actions.finish(inputID: envelope.inputID, source: envelope.source)
            }
        }
        if withSubscribers {
            for _ in 0..<10000 {
                if await second.inputs.count == Int(i), await third.inputs.count == Int(i) { break }
                await Task.yield()
            }
        }
    }
    if withSubscribers {
        for _ in 0..<10000 {
            if await second.inputs.count == 3, await third.inputs.count == 3 { break }
            await Task.yield()
        }
    }
    #expect(await recorder.sequences == [1, 2, 3])
    #expect(await second.inputs.count == (withSubscribers ? 3 : 0))
    #expect(await third.inputs.count == (withSubscribers ? 3 : 0))
    #expect(await model.calls.count == 3)
    await manager.stopAll()
    await output.shutdown()
}

@Test func poseToolRejectsMalformedPayloadBeforePresentation() async throws {
    let input = AgentInput(sessionID: UUID(), payload: .text("test"))
    let call = ToolCall(
        toolPath: "UI.showPose", arguments: ["payload": "{\"sequence\":1,\"timestamp\":0,\"rotation\":9,\"people\":[]}"]
    )
    let envelope = OutputEnvelope(source: .visionPerception, input: input, output: .toolCall(call))
    await #expect(throws: UITools.PoseError.invalidPayload) {
        try await UITools.showPose(call: call.executionRequest, context: envelope.toolContext) { _, _ in
            Issue.record("Invalid pose reached UI")
        }
    }
    let point = PoseOverlay.Joint(x: 2500, y: 7500, confidence: 1000)
    #expect(point.sensorPoint(rotation: 0).x == 0.25)
    #expect(point.sensorPoint(rotation: 1).x == 0.75)
    #expect(point.sensorPoint(rotation: 1).y == 0.75)
    #expect(point.sensorPoint(rotation: 2).y == 0.25)
    #expect(point.sensorPoint(rotation: 3).x == 0.25)
}

@Test func visionOutputsAreCodeOwnedPermissions() throws {
    let config = try AgentConfigurations.load(named: "VisionPerception")
    #expect(config.capabilities.actions.isEmpty && config.capabilities.tools.isEmpty)
    let agent = try VisionPerceptionAgent(pose: CrowdPose(), sessionID: UUID())
    let registry = agent.descriptor.capabilities
    #expect(
        registry.permits(
            ToolCall(toolPath: "UI.moveEyes", arguments: ["x": "0", "y": "0"])))
    #expect(registry.permits(ToolCall(toolPath: "UI.showPose", arguments: ["payload": "{}"])))
}

private struct CrowdPose: PoseCapability {
    var availability: CapabilityAvailability { .available }
    func estimatePose(_ request: PoseRequest) async throws -> PoseResult {
        let points = BodyJoint.allCases.map { PoseKeypoint(joint: $0, x: 2, y: 3, confidence: 0.9) }
        let person = PersonPose(box: PoseBox(x: 0, y: 0, width: 4, height: 4), confidence: 0.9, keypoints: points)
        return PoseResult(context: request.context, people: Array(repeating: person, count: 8))
    }
}

@Test(.timeLimit(.minutes(1))) func visionCrowdFitsToolProtocolWithoutSubscribersAndRejectsForeignSession()
    async throws
{
    let session = UUID()
    let agent = try VisionPerceptionAgent(pose: CrowdPose(), sessionID: session)
    try await agent.bind(AgentMessaging { _, _, _ in throw CommunicationError.noRecipients })
    try await agent.start()
    await #expect(throws: ImageInputError.wrongSession) {
        try await agent.receive(AgentInput(sessionID: UUID(), payload: .image(image(40, sequence: 1))))
    }
    try await agent.receive(AgentInput(sessionID: session, payload: .image(image(40, sequence: 1))))
    var stream = agent.outputs.makeAsyncIterator()
    let envelope = try #require(await stream.next())
    #expect(envelope.source == .visionPerception)
    guard case .toolCall(let call) = envelope.output else {
        Issue.record("Missing skeleton Tool")
        return
    }
    #expect((call.arguments["payload"]?.utf8.count ?? Int.max) <= 3000)
    try await UITools.showPose(call: call.executionRequest, context: envelope.toolContext) { overlay, _ in
        #expect(overlay.people.count == 6)
        #expect(overlay.people.allSatisfy { $0.count == 17 })
        #expect(overlay.people[0][0] == ToolPoseOverlay.Joint(x: 5000, y: 7500, confidence: 900))
    }
    let gazeEnvelope = try #require(await stream.next())
    guard case .toolCall(let gazeCall) = gazeEnvelope.output else {
        Issue.record("Missing gaze Action after the skeleton")
        return
    }
    #expect(gazeEnvelope.sequence == 1 && gazeEnvelope.sessionID == session)
    try await UITools.moveEyes(invocation: ToolInvocation(call: gazeCall, envelope: gazeEnvelope)) { gaze, _ in
        #expect(abs(gaze.x) < 0.001 && gaze.y > 0)
    }
    await agent.stop()
}

@Test(.timeLimit(.minutes(1))) func visionSlowDisplayKeepsOnlyLatestWithoutFailingPerception() async throws {
    let session = UUID()
    let agent = try VisionPerceptionAgent(pose: EmptyPose(), sessionID: session)
    try await agent.bind(AgentMessaging { _, _, _ in throw CommunicationError.noRecipients })
    try await agent.start()
    for i: UInt64 in 1...9 {
        try await agent.receive(AgentInput(sessionID: session, payload: .image(image(UInt8(i * 20), sequence: i))))
        for _ in 0..<1000 {
            let status = await agent.status()
            if status.processedInputs >= Int(i) || status.lifecycle == .failed { break }
            await Task.yield()
        }
    }
    #expect(await agent.status().lifecycle == .running)
    #expect(await agent.overlayReplacements == 8)
    #expect(await agent.gazeReplacements == 8)
    var output = agent.outputs.makeAsyncIterator()
    let envelope = try #require(await output.next())
    guard case .toolCall(let call) = envelope.output else {
        Issue.record("Missing tool")
        return
    }
    try await UITools.showPose(call: call.executionRequest, context: envelope.toolContext) { overlay, _ in
        #expect(overlay.sequence == 9)
    }
    await agent.stop()
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
            return DeliveryReport()
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

@Test func boundedRefreshAdmitsNewFramesForSlowOrStationaryScenes() throws {
    var filter = FrameChangeFilter(configuration: try FrameChangeConfiguration(maximumRefreshInterval: 0.1))
    func frame(_ sequence: UInt64, _ time: Double, _ gray: UInt8) throws -> ImageInput {
        try ImageInput(
            width: 1, height: 1, rgb: Data(repeating: gray, count: 3),
            sequence: sequence, timestamp: time, rotation: 0)
    }
    #expect(try filter.accepts(frame(1, 0, 0)))
    #expect(try !filter.accepts(frame(2, 0.03, 1)))
    #expect(try !filter.accepts(frame(3, 0.06, 2)))
    #expect(try filter.accepts(frame(4, 0.11, 3)))
    #expect(try !filter.accepts(frame(5, 0.14, 3)))
    #expect(try filter.accepts(frame(6, 0.22, 3)))
    #expect(throws: ImageInputError.outOfOrder) { try filter.accepts(frame(6, 0.22, 3)) }
    #expect(throws: ImageInputError.invalidFrame) { try FrameChangeConfiguration(maximumRefreshInterval: .nan) }
    #expect(throws: ImageInputError.invalidFrame) {
        try FrameChangeConfiguration(minimumInterval: 0.2, maximumRefreshInterval: 0.1)
    }
}

private actor BlockedPosePublication {
    let started: AsyncStream<UInt64>
    private let continuation: AsyncStream<UInt64>.Continuation
    private var waiter: CheckedContinuation<Void, Never>?
    init() {
        let pair = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingOldest(8))
        started = pair.stream
        continuation = pair.continuation
    }
    func publish(_ observation: PerceptionObservation) async throws -> DeliveryReport {
        guard case .pose(let pose) = observation else { throw CommunicationError.invalidPayload }
        await withCheckedContinuation { waiter in
            self.waiter = waiter
            continuation.yield(pose.sequence)
        }
        try Task.checkCancellation()
        return DeliveryReport()
    }
    func release() {
        waiter?.resume()
        waiter = nil
    }
}

@Test(.timeLimit(.minutes(1))) func slowPublicationDoesNotBlockInferenceOrDisplayAndCoalescesLatest() async throws {
    let session = UUID()
    let port = BlockedPosePublication()
    let agent = try VisionPerceptionAgent(pose: EmptyPose(), sessionID: session)
    try await agent.bind(AgentMessaging { value, _, _ in try await port.publish(value) })
    try await agent.start()
    var receipts = port.started.makeAsyncIterator()
    var displays = agent.outputs.makeAsyncIterator()
    try await agent.receive(AgentInput(sessionID: session, payload: .image(image(30, sequence: 1))))
    #expect(await receipts.next() == 1)
    _ = try #require(await displays.next())
    _ = try #require(await displays.next())
    for i: UInt64 in 2...4 {
        try await agent.receive(AgentInput(sessionID: session, payload: .image(image(UInt8(i * 30), sequence: i))))
        let envelope = try #require(await displays.next())
        guard case .toolCall(let call) = envelope.output else {
            Issue.record("Missing tool")
            return
        }
        try await UITools.showPose(call: call.executionRequest, context: envelope.toolContext) { overlay, _ in
            #expect(overlay.sequence == i)
        }
        guard case .toolCall = try #require(await displays.next()).output else {
            Issue.record("Missing gaze Action")
            return
        }
    }
    #expect(await agent.publicationReplacements == 2)
    await port.release()
    #expect(await receipts.next() == 4)
    let stop = Task { await agent.stop() }
    for _ in 0..<10000 {
        if await agent.status().lifecycle == .stopped { break }
        await Task.yield()
    }
    await port.release()
    await stop.value
    #expect(await displays.next() == nil)
}

private struct FailingSecondPose: PoseCapability {
    var availability: CapabilityAvailability { .available }
    func estimatePose(_ request: PoseRequest) async throws -> PoseResult {
        if request.image.rgb?.first == 80 { throw CapabilityError.invalidRequest("test failure") }
        return PoseResult(context: request.context, people: [])
    }
}

@Test(.timeLimit(.minutes(1))) func visualTerminalErrorSurvivesPendingSkeletonReplacement() async throws {
    let session = UUID()
    let agent = try VisionPerceptionAgent(pose: FailingSecondPose(), sessionID: session)
    try await agent.bind(AgentMessaging { _, _, _ in throw CommunicationError.noRecipients })
    try await agent.start()
    try await agent.receive(AgentInput(sessionID: session, payload: .image(image(40, sequence: 1))))
    for _ in 0..<10000 {
        if await agent.status().processedInputs == 1 { break }
        await Task.yield()
    }
    try await agent.receive(AgentInput(sessionID: session, payload: .image(image(80, sequence: 2))))
    for _ in 0..<10000 {
        if await agent.status().lifecycle == .failed { break }
        await Task.yield()
    }
    #expect(await agent.status().lifecycle == .failed)
    var output = agent.outputs.makeAsyncIterator()
    // The bounded pair may retain one older display before the terminal error.
    var terminal = try #require(await output.next())
    if case .control = terminal.output {} else { terminal = try #require(await output.next()) }
    guard case .control(let value) = terminal.output else {
        Issue.record("Terminal error was lost behind display state")
        return
    }
    #expect(value.hasPrefix("agent.error:"))
    #expect(await output.next() == nil)
    await agent.stop()
}

@Test(.timeLimit(.minutes(1))) func visionAcceptsTerminalReceiptsWithoutBlockingFrameAdmission() async throws {
    let session = UUID()
    let agent = try VisionPerceptionAgent(pose: EmptyPose(), sessionID: session)
    let manager = AgentManager()
    try await manager.register(agent, sessionID: session)
    try await agent.bind(AgentMessaging { _, _, _ in DeliveryReport() })
    try await manager.start(.visionPerception)
    let input = InputGateway(manager: manager)
    let owner = ExecutionOwner(
        agent: .visionPerception, incarnation: try await manager.identity(.visionPerception), sessionID: session)
    let result = ActionResult(
        executionID: UUID(), owner: owner, inputID: UUID(), turn: nil,
        path: ActionPath(module: "UI", function: "moveEyes"),
        status: .succeeded, effect: .contractCompleted, completion: .completed)
    #expect(await input.deliverActionResult(result) == .accepted)
    #expect(await agent.actionResults() == [result])
    await #expect(throws: CommunicationError.unauthorized) {
        try await agent.receive(
            AgentInput(
                sessionID: session, payload: .actionResult(result),
                metadata: InputMetadata(payload: .actionResult(result), source: "untrusted")))
    }
    var outputs = agent.outputs.makeAsyncIterator()
    try await agent.receive(AgentInput(sessionID: session, payload: .image(image(30, sequence: 1))))
    _ = try #require(await outputs.next())
    _ = try #require(await outputs.next())
    #expect(await agent.status().lifecycle == .running)
    try await manager.remove(.visionPerception)
}

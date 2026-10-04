import ActionRuntime
import Actions
import AgentCore
import Agents
import Foundation
import Gateway
import ModelKit
import Testing
import ToolRuntime
import Tools
import Types
import UI

private func image(_ value: UInt8, sequence: UInt64, rotation: Int = 1) throws -> ImageInput {
    try ImageInput(
        width: 4, height: 4, rgb: Data(repeating: value, count: 48),
        sequence: sequence, timestamp: Double(sequence), rotation: rotation)
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
        pose: model, sessionID: session, sampling: FrameSamplingConfiguration(minimumInterval: 0))
    let observations = AsyncStream<AgentMessage>.makeStream(bufferingPolicy: .bufferingOldest(8))
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
    guard case .pose(let firstPose)? = first.perception else {
        Issue.record("Missing pose")
        return
    }
    #expect(firstPose.sequence == 1)
    #expect(await started.next() == 3)
    await model.release()
    for sequence: UInt64 in [3] {
        guard case .pose(let pose)? = try #require(await stream.next()).perception else {
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

@Test(.timeLimit(.minutes(1))) func visionInfersNewestCaptureRegardlessOfGrayscaleChange() async throws {
    let model = ControlledPose()
    let session = UUID()
    let agent = try VisionPerceptionAgent(pose: model, sessionID: session)
    try await agent.bind(AgentMessaging { _, _, _ in DeliveryReport() })
    try await agent.start()
    var started = model.started.makeAsyncIterator()
    try await agent.receive(AgentInput(sessionID: session, payload: .image(image(0, sequence: 1))))
    #expect(await started.next() == 0)
    // Frame 3 changes only 1/255 and must still replace the waiting frame.
    try await agent.receive(AgentInput(sessionID: session, payload: .image(image(100, sequence: 2))))
    try await agent.receive(AgentInput(sessionID: session, payload: .image(image(101, sequence: 3))))
    await model.release()
    #expect(await started.next() == 101)
    #expect(await model.calls == [0, 101])
    #expect(await model.maximumActive == 1)
    let stopping = Task { await agent.stop() }
    for _ in 0..<1000 {
        if await agent.status().lifecycle == .stopped { break }
        await Task.yield()
    }
    await model.release()
    await stopping.value
}

@Test(.timeLimit(.minutes(1))) func visionPauseKeepsLatestAndStopSuppressesLateModelOutput() async throws {
    let model = ControlledPose()
    let session = UUID()
    let agent = try VisionPerceptionAgent(
        pose: model, sessionID: session, sampling: FrameSamplingConfiguration(minimumInterval: 0))
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
        contracts: AgentContracts.communication,
        data: JSONSerialization.data(withJSONObject: [
            "version": 5, "id": "second", "actions": [String: [String]](), "tools": [],
            "communication": [
                "inputs": [["contract": "vision.pose", "version": 1, "kind": "observation"]],
                "subscriptions": [["contract": "vision.pose", "source": "visionPerception", "topic": "vision.pose"]],
                "publications": [], "sends": [],
            ],
        ]))
    let thirdConfig = try AgentConfiguration(
        contracts: AgentContracts.communication,
        data: JSONSerialization.data(withJSONObject: [
            "version": 5, "id": "third", "actions": [String: [String]](), "tools": [],
            "communication": [
                "inputs": [["contract": "vision.pose", "version": 1, "kind": "observation"]],
                "subscriptions": [["contract": "vision.pose", "source": "visionPerception", "topic": "vision.pose"]],
                "publications": [], "sends": [],
            ],
        ]))
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication,
        externalSources: ["user", "runtime", "phone.microphone", "phone.camera"],
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
            AgentInput(
                sessionID: session, payload: .image(image(UInt8(i * 40), sequence: i)),
                metadata: InputMetadata(payload: .image(image(UInt8(i * 40), sequence: i)), source: "phone.camera")))
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
        #expect(overlay.statistics?.isValid == true)
        #expect(overlay.statistics?.inferenceMilliseconds != nil)
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
            guard case .attachment(let value) = input.content, let sample = value as? SampledImageAttachment,
                let attachment = sample.source as? PoseImageAttachment
            else {
                throw ImageInputError.invalidFrame
            }
            return attachment.image
        })
    let observed = AsyncStream<AgentMessage>.makeStream(bufferingPolicy: .bufferingOldest(1))
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
    guard case .pose(let pose)? = try #require(await values.next()).perception else {
        Issue.record("Missing pose")
        return
    }
    #expect(pose.rotation == 0 && pose.sequence == 1 && pose.people.isEmpty)
    await agent.stop()
}

@Test func visionCadenceAdmitsStationaryFramesAndLimitsChangedFrames() throws {
    var cadence = FrameCadence(configuration: try FrameSamplingConfiguration())
    func frame(_ sequence: UInt64, _ time: Double, _ gray: UInt8) throws -> ImageInput {
        try ImageInput(
            width: 1, height: 1, rgb: Data(repeating: gray, count: 3),
            sequence: sequence, timestamp: time, rotation: 0)
    }
    #expect(try cadence.accepts(frame(1, 0, 0)))
    #expect(try !cadence.accepts(frame(2, 0.03, 255)))
    #expect(try !cadence.accepts(frame(3, 0.06, 0)))
    #expect(try cadence.accepts(frame(4, 0.11, 0)))
    #expect(try !cadence.accepts(frame(5, 0.14, 255)))
    #expect(try cadence.accepts(frame(6, 0.22, 0)))
    #expect(throws: ImageInputError.outOfOrder) { try cadence.accepts(frame(6, 0.22, 0)) }
    #expect(throws: ImageInputError.invalidFrame) { try FrameSamplingConfiguration(minimumInterval: .nan) }
    #expect(throws: ImageInputError.invalidFrame) { try FrameSamplingConfiguration(minimumInterval: -0.1) }
    #expect(throws: ImageInputError.invalidFrame) { try FrameSamplingConfiguration(minimumInterval: 1.1) }
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
    func publish(_ observation: AgentMessage) async throws -> DeliveryReport {
        guard case .pose(let pose)? = observation.perception else { throw CommunicationError.invalidPayload }
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

@Test(.timeLimit(.minutes(1))) func rejectingPhotographerCannotStopPoseDisplay() async throws {
    let session = UUID()
    let agent = try VisionPerceptionAgent(pose: CrowdPose(), sessionID: session)
    try await agent.bind(
        AgentMessaging { _, _, _ in
            DeliveryReport(rejected: [.photographer: "notRunning"])
        })
    try await agent.start()
    var output = agent.outputs.makeAsyncIterator()
    for sequence: UInt64 in 1...2 {
        try await agent.receive(
            AgentInput(
                sessionID: session,
                payload: .image(image(UInt8(sequence * 40), sequence: sequence))))
        let envelope = try #require(await output.next())
        guard case .toolCall(let call) = envelope.output else {
            Issue.record("Subscriber rejection stopped pose output")
            await agent.stop()
            return
        }
        #expect(call.toolPath == "UI.showPose")
        _ = await output.next()  // Independent gaze output.
    }
    for _ in 0..<10000 {
        if await agent.publicationRejections >= 2 { break }
        await Task.yield()
    }
    #expect(await agent.publicationRejections == 2)
    #expect(await agent.status().lifecycle == .running)
    await agent.stop()
}

@Test(.timeLimit(.minutes(1))) func visionStatisticsMeasureCaptureToResultThroughPoseTool() async throws {
    let session = UUID()
    let agent = try VisionPerceptionAgent(pose: EmptyPose(), sessionID: session)
    try await agent.bind(AgentMessaging { _, _, _ in DeliveryReport() })
    try await agent.start()
    let capturedAt = ContinuousClock.now.advanced(by: .milliseconds(-20))
    let frame = try ImageInput(
        width: 1, height: 1, rgb: Data([0, 0, 0]), sequence: 1, timestamp: 0, rotation: 0,
        capturedAt: capturedAt)
    try await agent.receive(AgentInput(sessionID: session, payload: .image(frame)))
    var output = agent.outputs.makeAsyncIterator()
    let envelope = try #require(await output.next())
    guard case .toolCall(let call) = envelope.output else {
        Issue.record("Missing pose Tool")
        await agent.stop()
        return
    }
    try await UITools.showPose(call: call.executionRequest, context: envelope.toolContext) { overlay, _ in
        let statistics = try #require(overlay.statistics)
        #expect(statistics.isValid)
        #expect(try #require(statistics.queueMilliseconds) >= 20)
        #expect(try #require(statistics.totalMilliseconds) >= 20)
        #expect(statistics.framesPerSecond == nil)
        let interval = try #require(statistics.detectionIntervalMilliseconds)
        #expect((0...250).contains(interval))
        #expect(statistics.replacements == 0)
    }
    await agent.stop()
}

@Test func poseStatisticsRemainOptionalAndRejectInvalidMeasurements() throws {
    let legacy = Data(#"{"sequence":1,"timestamp":0,"rotation":0,"people":[]}"#.utf8)
    #expect(try JSONDecoder().decode(PoseOverlay.self, from: legacy).statistics == nil)
    #expect(try JSONDecoder().decode(ToolPoseOverlay.self, from: legacy).statistics == nil)
    let valid = ToolPoseOverlay.Statistics(
        queueMilliseconds: 10, inferenceMilliseconds: 20, totalMilliseconds: 30,
        framesPerSecond: 10, replacements: 2)
    #expect(valid.isValid)
    let invalid = ToolPoseOverlay.Statistics(
        queueMilliseconds: 10, inferenceMilliseconds: 20, totalMilliseconds: 15,
        framesPerSecond: 10, replacements: 2)
    #expect(!invalid.isValid)
    #expect(
        !ToolPoseOverlay.Statistics(
            queueMilliseconds: nil, inferenceMilliseconds: .nan, totalMilliseconds: nil,
            framesPerSecond: nil, replacements: 0
        ).isValid)
}

private func cadencePose(
    time: Double, offsets: [Float] = [0], confidence: Float = 0.9, rotation: Int = 0
) throws -> PoseObservation {
    try PoseObservation(
        width: 640, height: 480, sequence: UInt64(time * 1000), timestamp: time, rotation: rotation,
        people: offsets.map { offset in
            (0..<17).map { index in
                PoseObservation.Joint(
                    x: 120 + Float(index % 4) * 20 + offset,
                    y: 100 + Float(index / 4) * 30, confidence: confidence)
            }
        })
}

@Test func visionAdaptiveCadenceSlowsStablePoseThenAcceleratesMotionAndConfidenceLoss() throws {
    var cadence = FrameCadence(configuration: try FrameSamplingConfiguration())
    for step in 0...20 {
        try cadence.observe(cadencePose(time: Double(step) * 0.1), inferenceDuration: 0.01)
    }
    #expect(cadence.interval > 0.2 && cadence.interval <= 0.25)
    try cadence.observe(cadencePose(time: 2.1, offsets: [30]), inferenceDuration: 0.01)
    #expect(cadence.interval == 0)
    // Low-confidence keypoints cannot be treated as stationary reliable evidence.
    try cadence.observe(cadencePose(time: 2.2, offsets: [30], confidence: 0.5), inferenceDuration: 0.01)
    #expect(cadence.interval == 0)
}

@Test func visionAdaptiveCadenceAssociatesReorderedPeopleAndIgnoresSmallJitter() throws {
    var cadence = FrameCadence(configuration: try FrameSamplingConfiguration())
    for step in 0...20 {
        let offsets: [Float] = step.isMultiple(of: 2) ? [0, 200] : [201, 1]
        try cadence.observe(cadencePose(time: Double(step) * 0.1, offsets: offsets), inferenceDuration: 0.01)
    }
    #expect(cadence.interval > 0.2)
    try cadence.observe(cadencePose(time: 2.1, offsets: [0, 200, 350]), inferenceDuration: 0.01)
    #expect(cadence.interval == 0)
}

@Test func visionAdaptiveCadenceRecoversLostPeopleThenKeepsSearching() throws {
    var cadence = FrameCadence(configuration: try FrameSamplingConfiguration())
    try cadence.observe(cadencePose(time: 0), inferenceDuration: 0.01)
    try cadence.observe(cadencePose(time: 0.1, offsets: []), inferenceDuration: 0.01)
    #expect(cadence.interval == 0)
    try cadence.observe(cadencePose(time: 0.4, offsets: []), inferenceDuration: 0.01)
    #expect(cadence.interval == 0)
    for step in 6...20 {
        try cadence.observe(cadencePose(time: Double(step) * 0.1, offsets: []), inferenceDuration: 0.01)
    }
    #expect(cadence.interval > 0.15 && cadence.interval <= 0.2)
    try cadence.observe(cadencePose(time: 2.1), inferenceDuration: 0.01)
    #expect(cadence.interval == 0)
}

@Test func visionAdaptiveCadenceRespectsInferenceCostBoundsAndResetsGeometry() throws {
    var cadence = FrameCadence(configuration: try FrameSamplingConfiguration())
    try cadence.observe(cadencePose(time: 0), inferenceDuration: 0.4, totalLatency: 0.6)
    #expect(cadence.interval == 0.25)
    try cadence.observe(cadencePose(time: 0.1, offsets: [30]), inferenceDuration: 0.01)
    #expect(cadence.interval == 0)
    for step in 2...25 {
        try cadence.observe(cadencePose(time: Double(step) * 0.1, offsets: [30]), inferenceDuration: 0.01)
    }
    #expect(cadence.interval > 0.2)
    try cadence.observe(cadencePose(time: 2.6, offsets: [30], rotation: 1), inferenceDuration: 0.01)
    #expect(cadence.interval < 0.1)
    try cadence.observe(cadencePose(time: 2.7, offsets: [30], rotation: 1), inferenceDuration: 20)
    #expect(cadence.interval == 0.25)
    #expect(throws: ImageInputError.invalidFrame) {
        try cadence.observe(cadencePose(time: 2.8), inferenceDuration: .nan)
    }
    #expect(throws: ImageInputError.invalidFrame) { try FrameSamplingConfiguration(maximumInterval: 0.01) }
    #expect(throws: ImageInputError.invalidFrame) { try FrameSamplingConfiguration(initialInterval: .infinity) }
}

@Test func visionAdaptiveCadenceUsesMonotonicStartGapWithoutReplayingSkippedFrames() throws {
    var cadence = FrameCadence(configuration: try FrameSamplingConfiguration())
    let now = ContinuousClock.now
    #expect(try cadence.accepts(image(0, sequence: 1), at: now))
    // Media timestamps can advance while delivery bursts. Actual start gap still limits admission.
    #expect(try !cadence.accepts(image(255, sequence: 2), at: now.advanced(by: .milliseconds(10))))
    #expect(try cadence.accepts(image(0, sequence: 3), at: now.advanced(by: .milliseconds(110))))
    #expect(throws: ImageInputError.outOfOrder) {
        try cadence.accepts(image(255, sequence: 2), at: now.advanced(by: .milliseconds(220)))
    }
}

@Test func visionAdaptiveUrgentCadenceAdmitsNextFreshFrameWithoutArtificialGap() throws {
    var cadence = FrameCadence(configuration: try FrameSamplingConfiguration())
    let now = ContinuousClock.now
    let baseline = [UInt8](repeating: 100, count: 4096)
    #expect(try cadence.accepts(motionFrame(baseline, sequence: 1, time: 0, capturedAt: now), at: now))
    try cadence.observe(cadencePose(time: 0), inferenceDuration: 0.007, totalLatency: 0.009)
    #expect(cadence.interval == 0)
    #expect(
        try cadence.accepts(
            motionFrame(baseline, sequence: 2, time: 0.008, capturedAt: now.advanced(by: .milliseconds(8))),
            at: now.advanced(by: .milliseconds(8))))
    // Both consecutive fresh frames are admitted; the Agent's single worker owns non-overlap.
    try cadence.observe(cadencePose(time: 0.008, offsets: [30]), inferenceDuration: 0.007)
    #expect(cadence.interval == 0)
    #expect(
        try cadence.accepts(
            motionFrame(baseline, sequence: 3, time: 0.016, capturedAt: now.advanced(by: .milliseconds(16))),
            at: now.advanced(by: .milliseconds(16))))
}

@Test func poseAdaptiveIntervalStatisticsPreserveLegacyPayloadsAndBounds() throws {
    let legacy = PoseOverlay(
        sequence: 1, timestamp: 0, rotation: 0, people: [],
        statistics: PoseOverlay.Statistics(
            queueMilliseconds: 1, inferenceMilliseconds: 2, totalMilliseconds: 3,
            framesPerSecond: 10, replacements: 0))
    let decoded = try JSONDecoder().decode(ToolPoseOverlay.self, from: JSONEncoder().encode(legacy))
    #expect(decoded.statistics?.detectionIntervalMilliseconds == nil)
    #expect(decoded.statistics?.imageMotion == nil)
    #expect(decoded.statistics?.isValid == true)
    #expect(
        !ToolPoseOverlay.Statistics(
            queueMilliseconds: nil, inferenceMilliseconds: 1, totalMilliseconds: nil,
            framesPerSecond: nil, replacements: 0, detectionIntervalMilliseconds: 1001
        ).isValid)
    let maximum = PoseOverlay(
        sequence: UInt64.max, timestamp: 123456.789, rotation: 3,
        people: Array(
            repeating: Array(repeating: PoseOverlay.Joint(x: -10000, y: 20000, confidence: 1000), count: 17), count: 6),
        statistics: PoseOverlay.Statistics(
            queueMilliseconds: 100, inferenceMilliseconds: 150, totalMilliseconds: 250,
            framesPerSecond: 6.666666666666667, replacements: Int.max, detectionIntervalMilliseconds: 250,
            imageMotion: 1))
    #expect(try JSONEncoder().encode(maximum).count <= 3000)
}

private struct MotionAttachment: ImageAttachment {}
private func motionFrame(
    _ pixels: [UInt8], sequence: UInt64, time: Double, capturedAt: ContinuousClock.Instant? = nil,
    rotation: Int = 0
) throws -> ImageInput {
    try ImageInput(
        width: 640, height: 480, gray64: Data(pixels), attachment: MotionAttachment(),
        sequence: sequence, timestamp: time, rotation: rotation, capturedAt: capturedAt)
}
private func quietMotionCadence() throws -> FrameCadence {
    var cadence = FrameCadence(configuration: try FrameSamplingConfiguration())
    for step in 0...20 {
        try cadence.observe(cadencePose(time: Double(step) * 0.1), inferenceDuration: 0.01)
    }
    return cadence
}
private func motionPatch(_ value: UInt8, x: ClosedRange<Int>, y: ClosedRange<Int>) -> [UInt8] {
    var pixels = [UInt8](repeating: 100, count: 4096)
    for row in y {
        for column in x { pixels[row * 64 + column] = value }
    }
    return pixels
}

@Test func visionImageMotionWeightsPersonRegionsAndDiscoversGlobalChanges() throws {
    let baseline = [UInt8](repeating: 100, count: 4096)
    var person = try quietMotionCadence()
    #expect(try person.accepts(motionFrame(baseline, sequence: 1, time: 2)))
    #expect(try person.accepts(motionFrame(motionPatch(120, x: 13...17, y: 16...20), sequence: 2, time: 2.1)))
    #expect(person.interval < 0.1)
    #expect(try #require(person.imageActivity) >= 0.5)

    var background = try quietMotionCadence()
    #expect(try background.accepts(motionFrame(baseline, sequence: 1, time: 2)))
    #expect(try !background.accepts(motionFrame(motionPatch(120, x: 45...49, y: 40...44), sequence: 2, time: 2.1)))
    #expect(background.interval > 0.2)
    #expect(try background.accepts(motionFrame(motionPatch(160, x: 40...47, y: 40...47), sequence: 3, time: 2.15)))
    #expect(background.interval < 0.1)
}

@Test func visionImageMotionAccumulatesAgainstInferenceReferenceInsteadOfSkippedFrames() throws {
    var cadence = try quietMotionCadence()
    #expect(try cadence.accepts(motionFrame([UInt8](repeating: 100, count: 4096), sequence: 1, time: 2)))
    for (sequence, change) in [(2, 2), (3, 4), (4, 6)] {
        let sample = motionPatch(UInt8(100 + change), x: 13...17, y: 16...20)
        #expect(
            try !cadence.accepts(motionFrame(sample, sequence: UInt64(sequence), time: 2 + Double(sequence - 1) * 0.03))
        )
    }
    #expect(try cadence.accepts(motionFrame(motionPatch(110, x: 13...17, y: 16...20), sequence: 5, time: 2.15)))
    #expect(try #require(cadence.imageActivity) >= 0.1)
}

@Test func visionImageMotionSuppressesExposureContrastNoiseAndGeometryMismatch() throws {
    var cadence = try quietMotionCadence()
    let baseline = (0..<4096).map { UInt8(30 + ($0 % 64) * 2) }
    #expect(try cadence.accepts(motionFrame(baseline, sequence: 1, time: 2)))
    let exposed = baseline.map { UInt8((Double($0) * 1.1 + 12).rounded()) }
    #expect(try !cadence.accepts(motionFrame(exposed, sequence: 2, time: 2.1)))
    #expect(try #require(cadence.imageActivity) < 0.1)
    let noisy = baseline.enumerated().map { index, value in UInt8(Int(value) + (index.isMultiple(of: 2) ? 2 : -2)) }
    #expect(try !cadence.accepts(motionFrame(noisy, sequence: 3, time: 2.15)))
    #expect(try #require(cadence.imageActivity) < 0.1)
    #expect(try cadence.accepts(motionFrame(exposed, sequence: 4, time: 2.2, rotation: 1)))
    #expect(cadence.imageActivity == nil)
}

@Test func visionImageMotionCannotOverrideComputeOrFreshnessBudgets() throws {
    var cadence = try quietMotionCadence()
    try cadence.observeTiming(inferenceDuration: 0.4, totalLatency: 0.6)
    let now = ContinuousClock.now
    let baseline = [UInt8](repeating: 100, count: 4096)
    #expect(try cadence.accepts(motionFrame(baseline, sequence: 1, time: 2, capturedAt: now), at: now))
    let moving = motionPatch(180, x: 13...20, y: 16...26)
    #expect(
        try !cadence.accepts(
            motionFrame(moving, sequence: 2, time: 2.1, capturedAt: now), at: now.advanced(by: .milliseconds(100))))
    #expect(cadence.interval >= 0.2)
    #expect(
        try !cadence.accepts(
            motionFrame(moving, sequence: 3, time: 2.9, capturedAt: now), at: now.advanced(by: .milliseconds(800))))
    #expect(cadence.staleInputs == 1)
    #expect(
        try cadence.accepts(
            motionFrame(moving, sequence: 4, time: 3, capturedAt: now.advanced(by: .seconds(1))),
            at: now.advanced(by: .seconds(1))))
}

@Test func visionLatencyFeedbackDistinguishesUpstreamDelayFromInferencePressure() throws {
    var delayed = try quietMotionCadence()
    try delayed.observe(cadencePose(time: 2.1), inferenceDuration: 0.01, totalLatency: 0.6)
    #expect(delayed.interval <= 0.1)
    var compute = FrameCadence(configuration: try FrameSamplingConfiguration(maximumObservationLatency: 0.2))
    try compute.observe(cadencePose(time: 0), inferenceDuration: 0.12, totalLatency: 0.18)
    #expect(abs(compute.interval - 0.18) < 0.0001)
    #expect(throws: ImageInputError.invalidFrame) {
        try compute.observeTiming(inferenceDuration: 0.2, totalLatency: 0.1)
    }
    #expect(throws: ImageInputError.invalidFrame) { try FrameSamplingConfiguration(maximumObservationLatency: .nan) }
}

@Test(.timeLimit(.minutes(1))) func visionDiscardsOverBudgetResultsWithoutPublishingAndRecovers() async throws {
    let model = ControlledPose()
    let session = UUID()
    let agent = try VisionPerceptionAgent(
        pose: model, sessionID: session, sampling: FrameSamplingConfiguration(maximumObservationLatency: 0.03),
        resolveImage: { _ in try ImageFrame(width: 640, height: 480, rgb: Data(repeating: 0, count: 640 * 480 * 3)) })
    try await agent.bind(
        AgentMessaging { _, parent, _ in
            guard case .image(let frame) = parent.payload else { throw CommunicationError.invalidPayload }
            #expect(frame.sequence == 2)
            return DeliveryReport()
        })
    try await agent.start()
    var started = model.started.makeAsyncIterator()
    let pixels = [UInt8](repeating: 100, count: 4096)
    try await agent.receive(
        AgentInput(sessionID: session, payload: .image(motionFrame(pixels, sequence: 1, time: 0, capturedAt: .now))))
    #expect(await started.next() == 0)
    try await Task.sleep(for: .milliseconds(50))
    await model.release()
    for _ in 0..<10000 {
        if await agent.expiredInputs == 1 { break }
        await Task.yield()
    }
    #expect(await agent.expiredInputs == 1)
    try await Task.sleep(for: .milliseconds(200))
    try await agent.receive(
        AgentInput(sessionID: session, payload: .image(motionFrame(pixels, sequence: 2, time: 1, capturedAt: .now))))
    #expect(await started.next() == 0)
    await model.release()
    var outputs = agent.outputs.makeAsyncIterator()
    let first = try #require(await outputs.next())
    #expect(first.sequence == 2)
    #expect(await model.maximumActive == 1)
    await agent.stop()
}

@Test func poseImageMotionStatisticsRejectOutOfRangeAndNonfiniteActivity() throws {
    for activity in [-0.1, 1.1, Double.nan, Double.infinity] {
        let statistics = ToolPoseOverlay.Statistics(
            queueMilliseconds: nil, inferenceMilliseconds: 1, totalMilliseconds: nil,
            framesPerSecond: nil, replacements: 0, imageMotion: activity)
        #expect(!statistics.isValid)
    }
    let overlay = PoseOverlay(
        sequence: 1, timestamp: 0, rotation: 0, people: [],
        statistics: PoseOverlay.Statistics(
            queueMilliseconds: nil, inferenceMilliseconds: 1, totalMilliseconds: nil,
            framesPerSecond: nil, replacements: 0, imageMotion: 0.5))
    let decoded = try JSONDecoder().decode(ToolPoseOverlay.self, from: JSONEncoder().encode(overlay))
    #expect(decoded.statistics?.imageMotion == 0.5)
    #expect(decoded.statistics?.isValid == true)
}

@Test func poseSharedJointRejectsMalformedArraysWithoutAgentErrors() throws {
    let decoder = JSONDecoder()
    #expect(
        try decoder.decode(PoseOverlay.Joint.self, from: Data("[1,2,3]".utf8))
            == PoseOverlay.Joint(x: 1, y: 2, confidence: 3))
    #expect(throws: DecodingError.self) {
        try decoder.decode(PoseOverlay.Joint.self, from: Data("[1,2,3,4]".utf8))
    }
    #expect(throws: DecodingError.self) {
        try decoder.decode(PoseOverlay.Joint.self, from: Data("[1,2]".utf8))
    }
}

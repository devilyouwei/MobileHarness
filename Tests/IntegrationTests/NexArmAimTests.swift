import ActionRuntime
import Actions
import AgentCore
import Agents
import Foundation
import ModelKit
import PlatformKit
import Testing

private struct ScriptedPose: PoseCapability {
    var availability: CapabilityAvailability { .available }
    let people: [PersonPose]
    func estimatePose(_ request: PoseRequest) async throws -> PoseResult {
        PoseResult(context: request.context, people: people)
    }
}

private actor MemoryTransport: ExternalDeviceTransport {
    private(set) var sent: [[UInt8]] = []
    private(set) var stopped = false
    func connect() async throws {}
    func send(_ bytes: [UInt8]) async throws { sent.append(bytes) }
    func emergencyStop() async { stopped = true }
    func disconnect() async {}
}

private func frameImage(sequence: UInt64, timestamp: TimeInterval) throws -> ImageInput {
    try ImageInput(
        width: 100, height: 100, rgb: Data(repeating: 0, count: 30_000),
        sequence: sequence, timestamp: timestamp, rotation: 1)
}

private func person(noseX: Float, noseY: Float) -> PersonPose {
    let joints = BodyJoint.allCases.map { joint in
        PoseKeypoint(
            joint: joint, x: joint == .nose ? noseX : 50, y: joint == .nose ? noseY : 50, confidence: 0.9)
    }
    return PersonPose(
        box: PoseBox(x: 0, y: 0, width: 100, height: 100), confidence: 0.9, keypoints: joints)
}

private func positions(in frame: [UInt8]) -> [Int] {
    stride(from: 5, to: 17, by: 2).map { Int(frame[$0]) | (Int(frame[$0 + 1]) << 8) }
}

@Test func provisionalHomeFrameWritesSixMidpoints() throws {
    let frame = try NexArmJointCommand.frame(positions: Array(repeating: 2048, count: 6))
    #expect(frame.count == 19)
    #expect(frame.starts(with: [UInt8(0xFF), 0xFF, 0xFF, 14, 97]))
    #expect(positions(in: frame) == Array(repeating: 2048, count: 6))
    let sum = frame.dropFirst(2).dropLast().reduce(0) { $0 + Int($1) }
    #expect(frame.suffix(1) == [UInt8(truncatingIfNeeded: ~sum)])
}

@Test func leftAndHighTargetsMoveOnlyPanAndWrist() throws {
    let left = try NexArmJointCommand.positions(base: -0.32, pitch: 0)
    #expect(left[0] < 2048)
    #expect(left[1] == 2048)
    #expect(left[2] == 2048)
    #expect(left[3] == 2048)
    #expect(left[4] == 2048)
    #expect(left[5] == 2048)
    let high = try NexArmJointCommand.positions(base: 0, pitch: -0.32)
    #expect(high[0] == 2048)
    #expect(high[1] == 2048)
    #expect(high[2] == 2048)
    #expect(high[3] < 2048)
    #expect(high[4] == 2048)
    #expect(high[5] == 2048)
    #expect(throws: NexArmControlError.invalidAngle) { try NexArmJointCommand.positions(base: .nan, pitch: 0) }
}

@Test func photographerOnTheLeftAimsBaseAndHoldsTheOtherJoints() async throws {
    let session = UUID()
    let agent = try PhotographerAgent(
        pose: ScriptedPose(people: [person(noseX: 10, noseY: 50)]), sessionID: session, controlsArm: true)
    try await agent.start()
    try await agent.receive(
        AgentInput(sessionID: session, payload: .image(frameImage(sequence: 1, timestamp: 0))))
    var stream = agent.outputs.makeAsyncIterator()
    let skeleton = try #require(await stream.next())
    guard case .actionCall(let shown) = skeleton.output else {
        Issue.record("Missing skeleton")
        return
    }
    #expect(shown.actionPath == ActionPath(module: "UI", function: "showPose"))
    let aimed = try #require(await stream.next())
    guard case .actionCall(let call) = aimed.output else {
        Issue.record("Missing aim")
        return
    }
    #expect(call.actionPath == ActionPath(module: "Robot", function: "aim"))
    #expect(call.channel == "arm")
    let transport = MemoryTransport()
    let arm = NexArmController(transport: transport)
    try await RobotActions.aim(
        invocation: ActionInvocation(envelope: aimed, call: call)
    ) { base, pitch, _ in
        #expect(base < 0)
        #expect(abs(pitch) < 0.001)
        try await arm.aim(base: base, pitch: pitch)
    }
    let frame = try #require(await transport.sent.first)
    let joints = positions(in: frame)
    #expect(joints[0] < 2048)
    #expect(joints[1] == 2048)
    #expect(joints[2] == 2048)
    #expect(joints[3] == 2048)
    #expect(joints[4] == 2048)
    #expect(joints[5] == 2048)
    let finished = try #require(await stream.next())
    guard case .control(let state) = finished.output else {
        Issue.record("Missing finish")
        return
    }
    #expect(state == "agent.finished")
    await #expect(throws: NexArmControlError.provisionalHome) { try await arm.home() }
    await agent.stop()
}

@Test func emptyPoseDoesNotAim() async throws {
    let session = UUID()
    let agent = try PhotographerAgent(pose: ScriptedPose(people: []), sessionID: session, controlsArm: true)
    try await agent.start()
    try await agent.receive(
        AgentInput(sessionID: session, payload: .image(frameImage(sequence: 1, timestamp: 0))))
    var stream = agent.outputs.makeAsyncIterator()
    _ = try #require(await stream.next())
    let finished = try #require(await stream.next())
    guard case .control(let state) = finished.output else {
        Issue.record("Expected finish without aim")
        return
    }
    #expect(state == "agent.finished")
    await agent.stop()
}

@Test func aimWaitsForTimeAndMovement() async throws {
    let session = UUID()
    let agent = try PhotographerAgent(
        pose: ScriptedPose(people: [person(noseX: 10, noseY: 50)]), sessionID: session, controlsArm: true)
    try await agent.start()
    try await agent.receive(
        AgentInput(sessionID: session, payload: .image(frameImage(sequence: 1, timestamp: 0))))
    try await agent.receive(
        AgentInput(sessionID: session, payload: .image(frameImage(sequence: 2, timestamp: 0.1))))
    var stream = agent.outputs.makeAsyncIterator()
    var aimCount = 0
    for _ in 0..<5 {
        let envelope = try #require(await stream.next())
        if case .actionCall(let call) = envelope.output, call.actionPath.function == "aim" { aimCount += 1 }
    }
    #expect(aimCount == 1)
    await agent.stop()
}

@Test func aimActionRejectsANonFiniteAngleBeforeSend() async throws {
    let input = AgentInput(sessionID: UUID(), payload: .text("test"))
    let call = ActionCall(
        actionPath: ActionPath(module: "Robot", function: "aim"), channel: "arm",
        parameters: ["base": "nan", "pitch": "0"])
    let envelope = OutputEnvelope(source: .photographer, input: input, output: .actionCall(call))
    await #expect(throws: RobotActions.AimError.invalidAngle) {
        try await RobotActions.aim(invocation: ActionInvocation(envelope: envelope, call: call)) { _, _, _ in
            Issue.record("Invalid angle was sent")
        }
    }
}

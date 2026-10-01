import Actions
import AgentCore
import Agents
import Foundation
import PlatformKit
import Testing

private actor MemoryTransport: ExternalDeviceTransport {
    private(set) var sent: [[UInt8]] = []
    func connect() async throws {}
    func send(_ bytes: [UInt8]) async throws { sent.append(bytes) }
    func emergencyStop() async {}
    func disconnect() async {}
}

private func pose(
    noseX: Float, noseY: Float, noseConfidence: Float = 0.9, others: Float = 50,
    sequence: UInt64, timestamp: TimeInterval, people: Int = 1
) throws -> PoseObservation {
    let joints = (0..<17).map { index in
        PoseObservation.Joint(
            x: index == 0 ? noseX : others, y: index == 0 ? noseY : others,
            confidence: index == 0 ? noseConfidence : 0.9)
    }
    return try PoseObservation(
        width: 100, height: 100, sequence: sequence, timestamp: timestamp, rotation: 1,
        people: Array(repeating: joints, count: people))
}

private func observation(_ pose: PoseObservation, session: UUID) -> AgentInput {
    let payload = InputPayload.observation(.pose(pose))
    return AgentInput(
        sessionID: session, payload: payload,
        metadata: InputMetadata(payload: payload, source: "visionPerception", sequence: pose.sequence))
}

private func positions(in frame: [UInt8]) -> [Int] {
    stride(from: 5, to: 17, by: 2).map { Int(frame[$0]) | (Int(frame[$0 + 1]) << 8) }
}

@Test func provisionalHomeFrameWritesSixMidpoints() throws {
    let frame = try NexArmJointCommand.frame(positions: Array(repeating: 2048, count: 6))
    #expect(frame.count == 18)
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
    #expect(high[3] < 2048)
    #expect(throws: NexArmControlError.invalidAngle) { try NexArmJointCommand.positions(base: .nan, pitch: 0) }
}

@Test func photographerPolicyAcceptsVisionPose() throws {
    let policy = try CommunicationPolicy(configurations: [
        AgentConfigurations.load(named: "VisionPerception"),
        AgentConfigurations.load(named: "Photographer"),
    ])
    let input = observation(try pose(noseX: 50, noseY: 50, sequence: 1, timestamp: 0), session: UUID())
    #expect(policy.destinations(for: input) == [.photographer])
}

@Test func photographerOnTheLeftAimsBaseAndHoldsTheOtherJoints() async throws {
    let session = UUID()
    let agent = try PhotographerAgent(sessionID: session, controlsArm: true)
    try await agent.start()
    try await agent.receive(observation(try pose(noseX: 10, noseY: 50, sequence: 1, timestamp: 0), session: session))
    var stream = agent.outputs.makeAsyncIterator()
    let aimed = try #require(await stream.next())
    guard case .actionCall(let call) = aimed.output else {
        Issue.record("Missing aim")
        return
    }
    #expect(call.actionPath == ActionPath(module: "Robot", function: "aim"))
    #expect(call.channel == "arm")
    let transport = MemoryTransport()
    let arm = NexArmController(transport: transport)
    try await RobotActions.aim(invocation: ActionInvocation(envelope: aimed)) { base, pitch, _ in
        #expect(base < 0)
        #expect(abs(pitch) < 0.001)
        try await arm.aim(base: base, pitch: pitch)
    }
    let frame = try #require(await transport.sent.first)
    let joints = positions(in: frame)
    #expect(joints[0] < 2048)
    #expect(joints.dropFirst().allSatisfy { $0 == 2048 })
    await #expect(throws: NexArmControlError.provisionalHome) { try await arm.home() }
    await agent.stop()
}

@Test func hiddenNoseUsesTheVisibleJointMidpoint() async throws {
    let session = UUID()
    let agent = try PhotographerAgent(sessionID: session, controlsArm: true)
    try await agent.start()
    let body = try pose(noseX: 0, noseY: 0, noseConfidence: 0.1, others: 80, sequence: 1, timestamp: 0)
    try await agent.receive(observation(body, session: session))
    var stream = agent.outputs.makeAsyncIterator()
    let aimed = try #require(await stream.next())
    guard case .actionCall(let call) = aimed.output else {
        Issue.record("Missing aim")
        return
    }
    let base = try #require(Double(call.parameters["base"] ?? ""))
    let pitch = try #require(Double(call.parameters["pitch"] ?? ""))
    #expect(abs(base - 0.24) < 0.001)
    #expect(abs(pitch - 0.24) < 0.001)
    await agent.stop()
}

@Test func emptyPoseDoesNotAim() async throws {
    let session = UUID()
    let agent = try PhotographerAgent(sessionID: session, controlsArm: true)
    try await agent.start()
    let empty = try PoseObservation(width: 100, height: 100, sequence: 1, timestamp: 0, rotation: 1, people: [])
    try await agent.receive(observation(empty, session: session))
    var stream = agent.outputs.makeAsyncIterator()
    await agent.stop()
    #expect(await stream.next() == nil)
}

@Test func aimWaitsForTimeAndMovement() async throws {
    let session = UUID()
    let agent = try PhotographerAgent(sessionID: session, controlsArm: true)
    try await agent.start()
    try await agent.receive(observation(try pose(noseX: 10, noseY: 50, sequence: 1, timestamp: 0), session: session))
    try await agent.receive(observation(try pose(noseX: 10, noseY: 50, sequence: 2, timestamp: 0.1), session: session))
    var stream = agent.outputs.makeAsyncIterator()
    _ = try #require(await stream.next())
    await agent.stop()
    #expect(await stream.next() == nil)
}

@Test func aimActionRejectsANonFiniteAngleBeforeSend() async throws {
    let input = AgentInput(sessionID: UUID(), payload: .text("test"))
    let call = ActionCall(
        actionPath: ActionPath(module: "Robot", function: "aim"), channel: "arm",
        parameters: ["base": "nan", "pitch": "0"])
    let envelope = OutputEnvelope(source: .photographer, input: input, output: .actionCall(call))
    await #expect(throws: RobotActions.AimError.invalidAngle) {
        try await RobotActions.aim(invocation: try ActionInvocation(envelope: envelope)) { _, _, _ in
            Issue.record("Invalid angle was sent")
        }
    }
}

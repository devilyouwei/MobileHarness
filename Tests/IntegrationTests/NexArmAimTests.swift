import ActionRuntime
import Actions
import AgentCore
import Agents
import Foundation
import PlatformKit
import Testing
import ToolRuntime
import Tools

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

private func armTargets(in frame: [UInt8]) throws -> [Int] {
    var decoder = NexArmDecoder()
    try decoder.append(frame)
    let decoded = try decoder.next()
    let packet = try #require(decoded)
    #expect(packet.isSynchronousPositionWrite)
    #expect(packet.payload.count == 42)
    let ids = (0..<5).map { packet.payload[2 + $0 * 8] }
    #expect(ids == [1, 2, 3, 4, 5])
    return (0..<5).map { Int(packet.payload[4 + $0 * 8]) | Int(packet.payload[5 + $0 * 8]) << 8 }
}

private func armSpeeds(in frame: [UInt8]) throws -> [Int] {
    var decoder = NexArmDecoder()
    try decoder.append(frame)
    let decoded = try decoder.next()
    let packet = try #require(decoded)
    return (0..<5).map { Int(packet.payload[8 + $0 * 8]) | Int(packet.payload[9 + $0 * 8]) << 8 }
}

@Test func aimFrameAddressesFiveArmMotorsAtHome() throws {
    let frame = try NexArmJointCommand.frame(positions: NexArmJointCommand.armHome)
    #expect(try armTargets(in: frame) == [2048, 2087, 1198, 1238, 2048])
    #expect(throws: NexArmControlError.invalidPosition) {
        try NexArmJointCommand.frame(positions: NexArmJointCommand.armHome + [1122])
    }
}

@Test func followUpStepUsesItsOwnDistanceForSpeed() throws {
    let home = NexArmJointCommand.armHome
    var previous = home
    previous[0] = home[0] - 200
    var positions = previous
    positions[0] -= 10
    let packet = try NexArmJointCommand.packet(positions: positions, previous: previous)
    let speeds = try armSpeeds(in: packet.bytes)
    #expect(speeds[0] == 63)
    #expect(speeds[1] == 1)
    #expect(speeds[2] == 1)
    #expect(speeds[3] == 1)
    #expect(speeds[4] == 1)
}

@Test func leftAndHighTargetsMoveOnlyPanAndWrist() throws {
    let home = NexArmJointCommand.armHome
    let left = try NexArmJointCommand.positions(base: -0.32, pitch: 0)
    #expect(left[0] < home[0])
    #expect(left[1] == home[1])
    #expect(left[2] == home[2])
    #expect(left[3] == home[3])
    #expect(left[4] == home[4])
    let high = try NexArmJointCommand.positions(base: 0, pitch: -0.32)
    #expect(high[3] < home[3])
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
    guard case .toolCall(let call) = aimed.output else {
        Issue.record("Missing aim")
        return
    }
    #expect(call.toolPath == "Robot.aim")
    try await RobotTools.aim(
        invocation: ToolInvocation(
            call: ToolRequest(toolPath: call.toolPath, arguments: call.arguments),
            context: ToolExecutionContext(
                source: aimed.source.rawValue, sessionID: aimed.sessionID, inputID: aimed.inputID))
    ) { base, pitch, _ in
        #expect(base < 0)
        #expect(abs(pitch) < 0.001)
        let frame = try NexArmJointCommand.aimFrame(base: base, pitch: pitch)
        let joints = try armTargets(in: frame)
        let home = NexArmJointCommand.armHome
        #expect(joints[0] < home[0])
        #expect(joints[1] == home[1])
        #expect(joints[2] == home[2])
        #expect(joints[3] == home[3])
        #expect(joints[4] == home[4])
    }
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
    guard case .toolCall(let call) = aimed.output else {
        Issue.record("Missing aim")
        return
    }
    let base = try #require(Double(call.arguments["base"] ?? ""))
    let pitch = try #require(Double(call.arguments["pitch"] ?? ""))
    #expect(base > 0)
    #expect(pitch > 0)
    #expect(base < 0.2)
    #expect(pitch < 0.2)
    #expect(base > pitch)
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

@Test func centeredPersonDoesNotAim() async throws {
    let session = UUID()
    let agent = try PhotographerAgent(sessionID: session, controlsArm: true)
    try await agent.start()
    try await agent.receive(observation(try pose(noseX: 50, noseY: 50, sequence: 1, timestamp: 0), session: session))
    var stream = agent.outputs.makeAsyncIterator()
    await agent.stop()
    #expect(await stream.next() == nil)
}

@Test func baseKeepsSteppingWhileThePersonStaysOffCenter() async throws {
    let session = UUID()
    let agent = try PhotographerAgent(sessionID: session, controlsArm: true)
    try await agent.start()
    try await agent.receive(observation(try pose(noseX: 10, noseY: 50, sequence: 1, timestamp: 0), session: session))
    try await agent.receive(observation(try pose(noseX: 10, noseY: 50, sequence: 2, timestamp: 0.25), session: session))
    var stream = agent.outputs.makeAsyncIterator()
    let first = try #require(await stream.next())
    let second = try #require(await stream.next())
    guard case .toolCall(let firstCall) = first.output, case .toolCall(let secondCall) = second.output else {
        Issue.record("Missing aim")
        return
    }
    let firstBase = try #require(Double(firstCall.arguments["base"] ?? ""))
    let secondBase = try #require(Double(secondCall.arguments["base"] ?? ""))
    #expect(firstBase < 0)
    #expect(secondBase < firstBase)
    #expect(secondBase > -0.3)
    await agent.stop()
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
    let call = ToolCall(toolPath: "Robot.aim", arguments: ["base": "nan", "pitch": "0"])
    let envelope = OutputEnvelope(source: .photographer, input: input, output: .toolCall(call))
    await #expect(throws: RobotTools.AimError.invalidAngle) {
        try await RobotTools.aim(
            invocation: ToolInvocation(
                call: ToolRequest(toolPath: call.toolPath, arguments: call.arguments),
                context: ToolExecutionContext(
                    source: envelope.source.rawValue, sessionID: envelope.sessionID, inputID: envelope.inputID))
        ) { _, _, _ in
            Issue.record("Invalid angle was sent")
        }
    }
}

private actor AimLink: NexArmWritableLink {
    private var failWrite = false
    func setWriteFailure(_ value: Bool) { failWrite = value }
    private(set) var exchanges = 0
    private(set) var writes: [NexArmPacket] = []
    func exchange(_ packet: NexArmPacket, replyID: UInt8, replyCommand: UInt8, replyCount: Int) async throws
        -> NexArmPacket
    {
        exchanges += 1
        guard packet.command == 11, replyCommand == 11, replyCount == 24 else { throw NexArmError.invalidPacket }
        var payload = [UInt8](repeating: 0, count: 24)
        for (index, value) in [200, -1, 197, -10, 0, -81].enumerated() {
            let bits = UInt16(bitPattern: Int16(value))
            payload[index * 2] = UInt8(truncatingIfNeeded: bits)
            payload[index * 2 + 1] = UInt8(truncatingIfNeeded: bits >> 8)
        }
        for (index, value) in [2050, 2088, 1196, 1248, 2051, 1122].enumerated() {
            payload[12 + index * 2] = UInt8(value & 255)
            payload[13 + index * 2] = UInt8(value >> 8)
        }
        return try NexArmPacket(id: 255, command: 11, payload: payload)
    }
    func write(_ packet: NexArmPacket) throws {
        writes.append(packet)
        if failWrite { throw NexArmError.disconnected }
    }
    func close() {}
}

@Test func controllerAimWritesFiveAxesAfterVerification() async throws {
    let link = AimLink()
    let controller = NexArmActionController(link: link, compatibilityPolicy: .nexArmBLEProtocol)
    await #expect(throws: NexArmError.firmwareUnavailable) {
        try await controller.aim(base: 0, pitch: 0)
    }
    #expect(await link.writes.isEmpty)
    #expect(try await controller.verifyCompatibility() == .poseProtocol)
    let reads = await link.exchanges
    try await controller.aim(base: -0.32, pitch: 0)
    let writes = await link.writes
    let packet = try #require(writes.first)
    #expect(try armTargets(in: packet.bytes) == NexArmJointCommand.positions(base: -0.32, pitch: 0))
    #expect(await link.exchanges == reads)
}

@Test func trackingWriteFailureRequiresExplicitRecoveryAndNeverReplays() async throws {
    let link = AimLink()
    let controller = NexArmActionController(link: link, compatibilityPolicy: .nexArmBLEProtocol)
    _ = try await controller.verifyCompatibility()
    await link.setWriteFailure(true)
    await #expect(throws: NexArmActionError.uncertainMotion) { try await controller.aim(base: 0, pitch: 0) }
    await link.setWriteFailure(false)
    await #expect(throws: NexArmActionError.uncertainMotion) { try await controller.aim(base: 0.1, pitch: 0) }
    #expect(await link.writes.count == 1)
    _ = try await controller.recoverState()
    #expect(await link.writes.count == 1)
    try await controller.aim(base: 0.1, pitch: 0)
    #expect(await link.writes.count == 2)
}

@Test func photographerOverflowRejectsWithoutStoppingOrReplacingAcceptedAims() async throws {
    let session = UUID()
    let agent = try PhotographerAgent(sessionID: session, controlsArm: true)
    try await agent.start()
    for index in 0..<8 {
        try await agent.receive(
            observation(
                try pose(
                    noseX: index.isMultiple(of: 2) ? 10 : 90, noseY: 50,
                    sequence: UInt64(index + 1), timestamp: Double(index)), session: session))
    }
    await #expect(throws: HarnessError.queueFull) {
        try await agent.receive(
            observation(
                try pose(noseX: 10, noseY: 50, sequence: 9, timestamp: 8), session: session))
    }
    #expect(await agent.status().lifecycle == .running)
    await agent.stop()
    var accepted = 0
    for await _ in agent.outputs { accepted += 1 }
    #expect(accepted == 8)
}

@Test func photographerRejectsMalformedDecodedPoseBeforeIndexingJoints() async throws {
    let session = UUID()
    let agent = try PhotographerAgent(sessionID: session, controlsArm: true)
    try await agent.start()
    let pose = try JSONDecoder().decode(
        PoseObservation.self,
        from: Data(
            #"{"width":100,"height":100,"sequence":1,"timestamp":0,"rotation":1,"people":[[]]}"#.utf8))
    await #expect(throws: CommunicationError.invalidPayload) {
        try await agent.receive(observation(pose, session: session))
    }
    #expect(await agent.status().processedInputs == 0)
    await agent.stop()
}

@Test func robotAimDeclaresEveryControlledMotorBeforeGatewayDispatch() async throws {
    let module = RobotToolModule { _, _, _ in }
    let registry = try ToolRegistry(modules: [module])
    let resources = await registry.resources(for: "Robot.aim")
    #expect(resources == Set((1...5).map { ToolResource(rawValue: "nexarm.motor.\($0)") }))
}

private actor ArmAvailability {
    var ready = false
    func enable() { ready = true }
}

@Test func photographerSuppressesOfflineCommandsAndResumesFromFreshPose() async throws {
    let session = UUID()
    let availability = ArmAvailability()
    let agent = try PhotographerAgent(
        sessionID: session, controlsArm: true, controlAvailable: { await availability.ready })
    try await agent.start()
    try await agent.receive(observation(try pose(noseX: 10, noseY: 50, sequence: 1, timestamp: 0), session: session))
    await availability.enable()
    try await agent.receive(observation(try pose(noseX: 10, noseY: 50, sequence: 2, timestamp: 0.1), session: session))
    await agent.stop()
    var sequences: [UInt64] = []
    for await output in agent.outputs { sequences.append(output.sequence) }
    #expect(sequences == [2])
}

@Test func controllerTrackingSpeedUsesPreviousAcceptedTarget() async throws {
    let link = AimLink()
    let controller = NexArmActionController(link: link, compatibilityPolicy: .nexArmBLEProtocol)
    _ = try await controller.verifyCompatibility()
    try await controller.aim(base: -0.32, pitch: 0)
    try await controller.aim(base: -0.33, pitch: 0)
    let packets = await link.writes
    let prior = try armTargets(in: packets[0].bytes)
    let target = try armTargets(in: packets[1].bytes)
    let speeds = try armSpeeds(in: packets[1].bytes)
    #expect(speeds[0] == Int(ceil(Double(abs(target[0] - prior[0])) * 1250 / 200)))
    #expect(speeds[0] < 100)
    #expect(speeds.dropFirst().allSatisfy { $0 == 1 })
}

@Test func rejectedTrackingOutputDoesNotAdvanceAccumulatedTarget() async throws {
    let session = UUID()
    let agent = try PhotographerAgent(sessionID: session, controlsArm: true)
    try await agent.start()
    for sequence in 1...8 {
        try await agent.receive(
            observation(
                try pose(noseX: 43, noseY: 50, sequence: UInt64(sequence), timestamp: Double(sequence)),
                session: session))
    }
    await #expect(throws: HarnessError.queueFull) {
        try await agent.receive(
            observation(try pose(noseX: 43, noseY: 50, sequence: 9, timestamp: 9), session: session))
    }
    var iterator = agent.outputs.makeAsyncIterator()
    var lastBase = 0.0
    for _ in 0..<8 {
        let output = try #require(await iterator.next())
        guard case .toolCall(let call) = output.output else {
            Issue.record("Missing aim")
            return
        }
        lastBase = try #require(Double(call.arguments["base"] ?? ""))
    }
    try await agent.receive(observation(try pose(noseX: 43, noseY: 50, sequence: 10, timestamp: 10), session: session))
    let resumed = try #require(await iterator.next())
    guard case .toolCall(let call) = resumed.output else {
        Issue.record("Missing aim")
        return
    }
    let resumedBase = try #require(Double(call.arguments["base"] ?? ""))
    // Filtered error -0.0225, gain1.15, elapsed capped0.4: only one admitted step.
    #expect(abs(resumedBase - lastBase + 0.01035) < 0.000001)
    await agent.stop()
}

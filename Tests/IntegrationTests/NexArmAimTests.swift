import Actions
import AgentCore
import Agents
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import PlatformKit
import StorageCore
import StorageState
import Testing

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

private func observation(_ pose: PoseObservation, session: String) -> AgentInput {
    let payload = InputPayload.observation(.pose(pose))
    return AgentInput(
        id: UUID().uuidString,
        sessionID: session, payload: payload,
        metadata: InputMetadata(
            payload: payload, source: "visionPerception", sequence: pose.sequence, rootID: UUID().uuidString)
    )
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

@Test(.actionCatalog) func aimFrameAddressesFiveArmMotorsAtHome() throws {
    let frame = try NexArmJointCommand.frame(positions: NexArmJointCommand.armHome)
    #expect(try armTargets(in: frame) == [2047, 2087, 1984, 2045, 2048])
    #expect(throws: NexArmControlError.invalidPosition) {
        try NexArmJointCommand.frame(positions: NexArmJointCommand.armHome + [1122])
    }
}

@Test(.actionCatalog) func followUpStepUsesItsOwnDistanceForSpeed() throws {
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

@Test(.actionCatalog) func leftAndHighTargetsMoveOnlyPanAndWrist() throws {
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

@Test(.actionCatalog) func lookingDownExtendsTheArmAndTheElbowKeepsTheForearmLevel() throws {
    let home = NexArmJointCommand.armHome
    let level = NexArmJointCommand.forearmLevelSum
    #expect(level == 4071)
    let shallow = try NexArmJointCommand.positions(base: 0, pitch: 0.2)
    #expect(shallow[1] == home[1] && shallow[2] == home[2])
    let up = try NexArmJointCommand.positions(base: 0, pitch: -0.7)
    #expect(up[1] == home[1] && up[2] == home[2])
    var previous = home[1]
    for pitch in [0.3, 0.4, 0.5, 0.6] {
        let joints = try NexArmJointCommand.positions(base: 0, pitch: pitch)
        #expect(joints[1] < previous)
        #expect(joints[1] + joints[2] == level)
        #expect(joints[4] == home[4])
        previous = joints[1]
    }
    let low = try NexArmJointCommand.positions(base: 0, pitch: 0.7)
    #expect(low[1] == NexArmJointCommand.reachLiftMinimum)
    #expect(low[1] + low[2] == level)
    _ = try NexArmJointCommand.packet(positions: low)
}

@Test(.actionCatalog) func forearmLevelerLeadsOnlyWhileTheArmExtends() {
    var leveler = NexArmForearmLeveler()
    let home = NexArmJointCommand.armHome
    #expect(leveler.elbow(forLift: home[1]) == home[2])
    #expect(leveler.elbow(forLift: home[1] - 100) == home[2] + 100 + NexArmForearmLeveler.lead)
    #expect(leveler.elbow(forLift: home[1] - 103) == home[2] + 103 + NexArmForearmLeveler.lead)
    #expect(leveler.elbow(forLift: home[1] - 50) == home[2] + 50)
}

@Test(.actionCatalog) func photographerPolicyAcceptsVisionPose() throws {
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication,
        configurations: AgentConfigurations.all())
    let input = observation(
        try pose(noseX: 50, noseY: 50, sequence: 1, timestamp: 0), session: UUID().uuidString)
    #expect(policy.destinations(for: input) == [.photographer])
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func photographerOnTheLeftAimsBaseAndHoldsTheOtherJoints() async throws {
        let session = UUID().uuidString
        let agent = try PhotographerAgent(
            sessionID: session, controlsArm: true,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "photographer"), scope: UUID().uuidString, state: PhotographerContextState())
        )
        try await agent.start()
        try await agent.receive(
            observation(try pose(noseX: 10, noseY: 50, sequence: 1, timestamp: 0), session: session))
        var stream = agent.outputs.makeAsyncIterator()
        let aimed = try #require(await stream.next())
        guard case .toolCall(let call) = aimed.output else {
            Issue.record("Missing aim")
            return
        }
        #expect(call.toolPath == "NexArm.Tracking.aim")
        try await NexArmActions.aim(
            invocation: ActionInvocation(
                call: ToolRequest(id: UUID().uuidString, toolPath: call.toolPath, arguments: call.arguments),
                context: ActionExecutionContext(
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
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func photographerFreshnessUsesActualPoseAdmissionAndStopsWithLifecycle() async throws {
        let session = UUID().uuidString
        let agent = try PhotographerAgent(
            sessionID: session, controlsArm: true,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "photographer"), scope: UUID().uuidString, state: PhotographerContextState())
        )
        try await agent.start()
        #expect(await !agent.hasFreshPose())
        // A future sensor timestamp cannot prolong physical input freshness.
        try await agent.receive(
            observation(try pose(noseX: 50, noseY: 50, sequence: 1, timestamp: 1e12), session: session))
        #expect(await agent.hasFreshPose(maximumAge: .milliseconds(200)))
        try await Task.sleep(for: .milliseconds(250))
        #expect(await !agent.hasFreshPose(maximumAge: .milliseconds(200)))
        try await agent.receive(
            observation(try pose(noseX: 50, noseY: 50, sequence: 2, timestamp: 1e12, people: 0), session: session))
        #expect(await !agent.hasFreshPose(maximumAge: .milliseconds(200)))
        try await agent.receive(
            observation(try pose(noseX: 50, noseY: 50, sequence: 3, timestamp: 1e12), session: session))
        #expect(await agent.hasFreshPose())
        try await agent.pause()
        #expect(await !agent.hasFreshPose())
        await agent.stop()
        #expect(await !agent.hasFreshPose())
        var outputs = agent.outputs.makeAsyncIterator()
        #expect(await outputs.next() == nil)
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func hiddenNoseUsesTheVisibleJointMidpoint() async throws {
        let session = UUID().uuidString
        let agent = try PhotographerAgent(
            sessionID: session, controlsArm: true,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "photographer"), scope: UUID().uuidString, state: PhotographerContextState())
        )
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
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func emptyPoseDoesNotAim() async throws {
        let session = UUID().uuidString
        let agent = try PhotographerAgent(
            sessionID: session, controlsArm: true,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "photographer"), scope: UUID().uuidString, state: PhotographerContextState())
        )
        try await agent.start()
        let empty = try PoseObservation(width: 100, height: 100, sequence: 1, timestamp: 0, rotation: 1, people: [])
        try await agent.receive(observation(empty, session: session))
        var stream = agent.outputs.makeAsyncIterator()
        await agent.stop()
        #expect(await stream.next() == nil)
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func centeredPersonDoesNotAim() async throws {
        let session = UUID().uuidString
        let agent = try PhotographerAgent(
            sessionID: session, controlsArm: true,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "photographer"), scope: UUID().uuidString, state: PhotographerContextState())
        )
        try await agent.start()
        try await agent.receive(
            observation(try pose(noseX: 50, noseY: 50, sequence: 1, timestamp: 0), session: session))
        var stream = agent.outputs.makeAsyncIterator()
        await agent.stop()
        #expect(await stream.next() == nil)
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func baseKeepsSteppingWhileThePersonStaysOffCenter() async throws {
        let session = UUID().uuidString
        let agent = try PhotographerAgent(
            sessionID: session, controlsArm: true,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "photographer"), scope: UUID().uuidString, state: PhotographerContextState())
        )
        try await agent.start()
        try await agent.receive(
            observation(try pose(noseX: 10, noseY: 50, sequence: 1, timestamp: 0), session: session))
        try await agent.receive(
            observation(try pose(noseX: 10, noseY: 50, sequence: 2, timestamp: 0.25), session: session))
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
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func aimWaitsForTimeAndMovement() async throws {
        let session = UUID().uuidString
        let agent = try PhotographerAgent(
            sessionID: session, controlsArm: true,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "photographer"), scope: UUID().uuidString, state: PhotographerContextState())
        )
        try await agent.start()
        try await agent.receive(
            observation(try pose(noseX: 10, noseY: 50, sequence: 1, timestamp: 0), session: session))
        try await agent.receive(
            observation(try pose(noseX: 10, noseY: 50, sequence: 2, timestamp: 0.1), session: session))
        var stream = agent.outputs.makeAsyncIterator()
        _ = try #require(await stream.next())
        await agent.stop()
        #expect(await stream.next() == nil)
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func aimActionRejectsANonFiniteAngleBeforeSend() async throws {
        let input = AgentInput(
            id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("test"))
        let call = ToolCall(
            id: UUID().uuidString, toolPath: "NexArm.Tracking.aim", arguments: ["base": "nan", "pitch": "0"])
        let envelope = OutputEnvelope(
            source: .photographer, context: input.context, output: .toolCall(call), taskScope: input.taskScope)
        await #expect(throws: NexArmActions.AimError.invalidAngle) {
            try await NexArmActions.aim(
                invocation: ActionInvocation(
                    call: ToolRequest(id: UUID().uuidString, toolPath: call.toolPath, arguments: call.arguments),
                    context: ActionExecutionContext(
                        source: envelope.source.rawValue, sessionID: envelope.sessionID, inputID: envelope.inputID))
            ) { _, _, _ in
                Issue.record("Invalid angle was sent")
            }
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

extension LiveRuntimeTests {
    @Test(.actionCatalog) func controllerAimWritesFiveAxesAfterVerification() async throws {
        let link = AimLink()
        let controller = NexArmActionController(link: link, compatibilityPolicy: .nexArmBLEProtocol)
        await #expect(throws: NexArmExecutionError.firmwareUnavailable) {
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
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func trackingWriteFailureRequiresExplicitRecoveryAndNeverReplays() async throws {
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
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func photographerOverflowRejectsWithoutStoppingOrReplacingAcceptedAims() async throws {
        let session = UUID().uuidString
        let agent = try PhotographerAgent(
            sessionID: session, controlsArm: true, outputCapacity: 8,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "photographer"), scope: UUID().uuidString, state: PhotographerContextState())
        )
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
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func photographerRejectsMalformedDecodedPoseBeforeIndexingJoints() async throws {
        let session = UUID().uuidString
        let agent = try PhotographerAgent(
            sessionID: session, controlsArm: true,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "photographer"), scope: UUID().uuidString, state: PhotographerContextState())
        )
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
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func robotAimPublishesIntentWithoutHoldingTheWorkersMotorFence() async throws {
        let module = NexArmTrackingModule { _, _, _ in }
        let registry = try ToolRegistry(modules: [module])
        let resources = await registry.resources(for: "NexArm.Tracking.aim")
        #expect(resources.isEmpty)
    }
}

private actor ArmAvailability {
    var ready = false
    func enable() { ready = true }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func photographerSuppressesOfflineCommandsAndResumesFromFreshPose() async throws {
        let session = UUID().uuidString
        let availability = ArmAvailability()
        let agent = try PhotographerAgent(
            sessionID: session, controlsArm: true, controlAvailable: { await availability.ready },
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "photographer"), scope: UUID().uuidString, state: PhotographerContextState())
        )
        try await agent.start()
        try await agent.receive(
            observation(try pose(noseX: 10, noseY: 50, sequence: 1, timestamp: 0), session: session))
        await availability.enable()
        try await agent.receive(
            observation(try pose(noseX: 10, noseY: 50, sequence: 2, timestamp: 0.1), session: session))
        await agent.stop()
        var sequences: [UInt64] = []
        for await output in agent.outputs { sequences.append(output.inputMetadata.sequence) }
        #expect(sequences == [2])
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func controllerTrackingSpeedUsesPreviousAcceptedTarget() async throws {
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
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func rejectedTrackingOutputDoesNotAdvanceAccumulatedTarget() async throws {
        let session = UUID().uuidString
        let agent = try PhotographerAgent(
            sessionID: session, controlsArm: true, outputCapacity: 8,
            context: try AgentContextRepository(
                agent: AgentID(rawValue: "photographer"), scope: UUID().uuidString, state: PhotographerContextState())
        )
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
        try await agent.receive(
            observation(try pose(noseX: 43, noseY: 50, sequence: 10, timestamp: 10), session: session))
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
}

@Test func aimCommandSendsMotorsOneAndFourOncePerAdmittedTarget() throws {
    var command = NexArmAimCommand()
    let start = ContinuousClock.now
    #expect(throws: NexArmExecutionError.invalidArguments) {
        try command.command(base: 2100, pitch: 2100, at: start)
    }
    #expect(throws: NexArmExecutionError.invalidArguments) { try command.seed(base: 1, pitch: 2045) }
    try command.seed(base: 2047, pitch: 2045)
    let level = try #require(try command.command(base: 2067, pitch: 2045, at: start))
    command.accept(level)
    for _ in 0..<8 {
        let step = try #require(try command.command(base: 2067, pitch: 2045, at: start))
        #expect(step.packet.isLiveControl)
        command.accept(step)
    }
    let first = try #require(try command.command(base: 2067, pitch: 2045, at: start))
    #expect(first.packet.isTrackingSpeedControl)
    let speeds = try speedPair(first.packet)
    // 20 counts in 0.2s toward a higher count: reverse bit, magnitude 220.
    #expect(speeds.base == (220 | 0x8000) && speeds.pitch == 0)
    command.accept(first)
    #expect(try command.command(base: 2067, pitch: 2045, at: start.advanced(by: .milliseconds(200))) == nil)
    let faster = try #require(
        try command.command(base: 2207, pitch: 2045, at: start.advanced(by: .milliseconds(200))))
    #expect(try speedPair(faster.packet).base == (600 | 0x8000))
    command.accept(faster)
}

@Test func aimCommandHoldsSpeedUntilTheTargetChangesOrGoesQuiet() throws {
    var command = NexArmAimCommand()
    let start = ContinuousClock.now
    try command.seed(base: 2047, pitch: 2045)
    try admitPreparation(&command, at: start)
    let moving = try #require(try command.command(base: 2067, pitch: 2045, at: start))
    #expect(try speedPair(moving.packet).base == (220 | 0x8000))
    command.accept(moving)
    for offset in [30, 60, 120, 200] {
        #expect(
            try command.command(base: 2067, pitch: 2045, at: start.advanced(by: .milliseconds(offset))) == nil)
    }
    let stopped = try #require(
        try command.command(base: 2067, pitch: 2045, at: start.advanced(by: .milliseconds(350))))
    let stoppedSpeeds = try speedPair(stopped.packet)
    #expect(stoppedSpeeds.base == 0 && stoppedSpeeds.pitch == 0)
    command.accept(stopped)
    #expect(try command.command(base: 2067, pitch: 2045, at: start.advanced(by: .milliseconds(400))) == nil)
    let resumed = try #require(
        try command.command(base: 2087, pitch: 2045, at: start.advanced(by: .milliseconds(500))))
    let speeds = try speedPair(resumed.packet)
    #expect(speeds.base & 0x8000 != 0)
    #expect((speeds.base & 0x7FFF) > 0)
    #expect(speeds.pitch == 0)
}

@Test func aimCommandAddsCatchUpWhenTheHeldSpeedUndershoots() throws {
    var command = NexArmAimCommand()
    let start = ContinuousClock.now
    try command.seed(base: 2047, pitch: 2045)
    try admitPreparation(&command, at: start)
    let clamped = try #require(try command.command(base: 2187, pitch: 2045, at: start))
    #expect(try speedPair(clamped.packet).base == (600 | 0x8000))
    command.accept(clamped)
    let corrected = try #require(
        try command.command(base: 2197, pitch: 2045, at: start.advanced(by: .milliseconds(200))))
    // 140 counts clamp to 272.7 count/s and cover 54.5 counts. The 85.5 count lag corrects at the 80 count/s cap.
    // The next 10 counts over 0.2 seconds add 50. Combined 130 count/s encodes as 286 with the reverse bit.
    let correctedSpeeds = try speedPair(corrected.packet)
    #expect(correctedSpeeds.base == (286 | 0x8000) && correctedSpeeds.pitch == 0)
}

@Test func aimCommandReplacesUnadmittedTargetAndResetDropsOldGoals() throws {
    var command = NexArmAimCommand()
    let start = ContinuousClock.now
    try command.seed(base: 2047, pitch: 2045)
    try admitPreparation(&command, at: start)
    let superseded = try #require(try command.command(base: 2147, pitch: 2045, at: start))
    let latest = try #require(
        try command.command(base: 1947, pitch: 2085, at: start.advanced(by: .milliseconds(200))))
    command.accept(superseded)
    #expect(try command.command(base: 1947, pitch: 2085, at: start.advanced(by: .milliseconds(230))) == latest)
    command.accept(latest)
    #expect(try command.command(base: 1947, pitch: 2085, at: start.advanced(by: .milliseconds(260))) == nil)
    command.reset()
    #expect(throws: NexArmExecutionError.invalidArguments) {
        try command.command(base: 1947, pitch: 2085, at: start.advanced(by: .seconds(1)))
    }
    try command.seed(base: 2047, pitch: 2045)
    let restarted = try #require(
        try command.command(base: 1947, pitch: 2085, at: start.advanced(by: .seconds(1))))
    #expect(restarted.levelsForearm)
}

@Test func trackingCommandLevelsTheForearmOnceThenAimsWithMotorsOneAndFour() throws {
    var command = NexArmAimCommand()
    let start = ContinuousClock.now
    try command.seed(base: 2047, pitch: 2045)
    let levelOnly = try #require(try command.command(base: 2050, pitch: 2045, at: start))
    let levelTargets = try #require(levelOnly.packet.motorTargets)
    #expect(levelOnly.levelsForearm)
    #expect(Set(levelTargets.keys) == Set([2, 3]))
    #expect(levelTargets[2] == NexArmJointCommand.armHome[1])
    #expect(levelTargets[3] == NexArmJointCommand.armHome[2])
    command.accept(levelOnly)
    try admitSpeedMode(&command, at: start)
    let later = try #require(
        try command.command(base: 2300, pitch: 2100, at: start.advanced(by: .milliseconds(200))))
    #expect(!later.levelsForearm)
    #expect(later.packet.isTrackingSpeedControl)
    let speeds = try speedPair(later.packet)
    // Higher base count sets bit 15. Higher pitch count looks down and leaves bit 15 clear.
    #expect(speeds.base == (600 | 0x8000) && speeds.pitch == 600)
}

@Test func trackingLevelPreparationRetriesUntilAdmissionAndResetsWithControl() throws {
    var command = NexArmAimCommand()
    let start = ContinuousClock.now
    try command.seed(base: 2047, pitch: 2045)
    let first = try #require(try command.command(base: 2047, pitch: 2045, at: start))
    let retry = try #require(
        try command.command(base: 2047, pitch: 2045, at: start.advanced(by: .milliseconds(30))))
    #expect(retry == first && retry.levelsForearm)
    #expect(try registeredSpeed(first.packet, motor: 2) == 400)
    #expect(try registeredSpeed(first.packet, motor: 3) == 400)
    command.accept(retry)
    try admitSpeedMode(&command, at: start.advanced(by: .milliseconds(60)))
    #expect(try command.command(base: 2047, pitch: 2045, at: start.advanced(by: .milliseconds(60))) == nil)
    let pan = try #require(
        try command.command(base: 2100, pitch: 2045, at: start.advanced(by: .milliseconds(90))))
    #expect(!pan.levelsForearm)
    #expect(pan.packet.isTrackingSpeedControl)
    command.accept(pan)
    command.reset()
    #expect(throws: NexArmExecutionError.invalidArguments) {
        try command.command(base: 2100, pitch: 2045, at: start.advanced(by: .seconds(1)))
    }
    try command.seed(base: 2100, pitch: 2045)
    let restarted = try #require(
        try command.command(base: 2100, pitch: 2045, at: start.advanced(by: .seconds(1))))
    #expect(restarted.levelsForearm)
    #expect(Set(try #require(restarted.packet.motorTargets).keys) == Set([2, 3]))
}

private func admitPreparation(_ command: inout NexArmAimCommand, at time: ContinuousClock.Instant) throws {
    let level = try #require(try command.command(base: 2047, pitch: 2045, at: time))
    #expect(level.levelsForearm)
    command.accept(level)
    try admitSpeedMode(&command, at: time)
}

private func admitSpeedMode(_ command: inout NexArmAimCommand, at time: ContinuousClock.Instant) throws {
    for _ in 0..<8 {
        let step = try #require(try command.command(base: 2047, pitch: 2045, at: time))
        #expect(!step.levelsForearm)
        command.accept(step)
    }
}

private func speedPair(_ packet: NexArmPacket) throws -> (base: Int, pitch: Int) {
    #expect(packet.payload.count == 8 && packet.payload[2] == 1 && packet.payload[5] == 4)
    let base = Int(packet.payload[3]) | Int(packet.payload[4]) << 8
    let pitch = Int(packet.payload[6]) | Int(packet.payload[7]) << 8
    return (base, pitch)
}

private func registeredSpeed(_ packet: NexArmPacket, motor: Int) throws -> Int {
    let payload = packet.payload
    let start = try #require(stride(from: 2, to: payload.count, by: 8).first { payload[$0] == UInt8(motor) })
    return Int(payload[start + 6]) | Int(payload[start + 7]) << 8
}

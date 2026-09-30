import Actions
import AgentCore
import Agents
import BehaviorAssembly
import Foundation
import Gateway
import PlatformKit
import Testing
import Tools

private actor NexArmFixture: NexArmLink {
    var position = 2110
    var writes = 0
    var roll = 5
    var failWrite = false
    var wrongFirmware = false
    var speed = 0
    func configure(fail: Bool = false, wrong: Bool = false, moving: Bool = false) {
        failWrite = fail
        wrongFirmware = wrong
        speed = moving ? 1 : 0
    }
    func exchange(_ packet: NexArmPacket, replyID: UInt8, replyCommand: UInt8, replyCount: Int) async throws
        -> NexArmPacket
    {
        if packet.command == 1 {
            return try NexArmPacket(command: 1, payload: wrongFirmware ? [0, 0, 0, 0, 0, 0] : [1, 0, 2, 1, 0, 2])
        }
        if packet.command == 0x32 {
            writes += 1
            if failWrite { throw NexArmError.timeout }
            #expect(packet.id == 255)
            #expect(Array(packet.payload.prefix(8)) == Array(repeating: 0, count: 8))
            #expect(Array(packet.payload.suffix(4)) == [0, 0, 0xE8, 0x03])
            let delta = Int(Int16(bitPattern: UInt16(packet.payload[8]) | UInt16(packet.payload[9]) << 8))
            roll += delta
            position += Int((Double(delta) * 4096 / 360).rounded())
            return try telemetry()
        }
        #expect(packet.command == 11)
        position += speed * 10
        return try telemetry()
    }
    private func telemetry() throws -> NexArmPacket {
        var p = [UInt8](repeating: 0, count: 24)
        p[8] = UInt8(roll)
        for (i, value) in [2048, 2048, 2048, 2048, position, 1647].enumerated() {
            p[12 + i * 2] = UInt8(value & 255)
            p[13 + i * 2] = UInt8(value >> 8)
        }
        return try NexArmPacket(command: 11, payload: p)
    }
    func close() {}
}

@Test func nexArmFramingHandlesFragmentationLogsAndChecksum() throws {
    let request = try NexArmPacket(command: 1)
    #expect(request.bytes == [255, 255, 255, 2, 1, 253])
    let response = try NexArmPacket(command: 1, payload: [1, 0, 2, 1, 0, 2])
    var decoder = NexArmDecoder()
    var bad = response.bytes
    bad[bad.count - 1] ^= 1
    try decoder.append(Array("[FW] status\n".utf8) + bad)
    #expect(try decoder.next() == nil)
    for byte in response.bytes.dropLast() {
        try decoder.append([byte])
        #expect(try decoder.next() == nil)
    }
    try decoder.append([response.bytes.last!])
    #expect(try decoder.next() == response)
    #expect(throws: NexArmError.overflow) { try decoder.append(Array(repeating: 1, count: 4097)) }
    #expect(throws: NexArmError.invalidPacket) {
        try NexArmPacket(command: 1, payload: Array(repeating: 0, count: 254))
    }
}

private func nexArmInvocation(_ parameters: [String: String]) -> ActionInvocation {
    ActionInvocation(
        source: .assistant, input: AgentInput(sessionID: UUID(), payload: .event("diagnostic")),
        call: ActionCall(
            actionPath: ActionPath(module: "NexArm", function: "nudgeWrist"), channel: "Arm", parameters: parameters))
}

@Test func nexArmActionRejectsInvalidParametersBeforeEffects() async throws {
    for parameters in [
        ["degrees": "0"], ["degrees": "3"], ["degrees": "-3"], ["degrees": "nan"], [:],
        ["degrees": "1", "speed": "1000"],
    ] {
        await #expect(throws: NexArmActions.NudgeError.invalidDelta) {
            try await NexArmActions.nudgeWrist(invocation: nexArmInvocation(parameters)) { _, _ in
                Issue.record("Invalid input reached the device")
            }
        }
    }
}

@Test func nexArmMotionVerifiesAndAllowsOnlyOneNudge() async throws {
    let link = NexArmFixture()
    let controller = NexArmController(link: link)
    let assembly = try BehaviorAssembly(
        actionModules: [
            NexArmActionModule { delta, _ in
                try await controller.nudgeWrist(delta: delta)
            }
        ], toolModules: [], capabilities: [])
    try await ActionExecutor(registry: assembly.actions).execute(nexArmInvocation(["degrees": "1"]))
    #expect(await controller.lastMotion?.start == 2110)
    #expect(await controller.lastMotion?.observed == 2121)
    await #expect(throws: NexArmError.alreadyUsed) { try await controller.nudgeWrist(delta: 1) }
    #expect(await link.writes == 1)
}

@Test func nexArmMotionRefusesUnknownFirmwareAndMovingDevice() async throws {
    let wrong = NexArmFixture()
    await wrong.configure(wrong: true)
    await #expect(throws: NexArmError.unsupportedFirmware) {
        try await NexArmController(link: wrong).nudgeWrist(delta: 1)
    }
    #expect(await wrong.writes == 0)
    let moving = NexArmFixture()
    await moving.configure(moving: true)
    await #expect(throws: NexArmError.moving) { try await NexArmController(link: moving).nudgeWrist(delta: 1) }
    #expect(await moving.writes == 0)
}

@Test func nexArmUncertainWriteIsNeverRetried() async throws {
    let link = NexArmFixture()
    await link.configure(fail: true)
    let controller = NexArmController(link: link)
    await #expect(throws: NexArmError.uncertainMotion) { try await controller.nudgeWrist(delta: 1) }
    await #expect(throws: NexArmError.uncertainMotion) { try await controller.nudgeWrist(delta: 1) }
    #expect(await link.writes == 1)
}

/// Diagnostic fixture only: no model generation and no production Agent capability changes.
private actor NexArmDiagnosticAgent: Agent {
    nonisolated let descriptor: AgentDescriptor
    nonisolated let outputs = AsyncStream<OutputEnvelope> { $0.finish() }
    private(set) var accepted: AgentInput?
    private(set) var result: ActionResult?
    init() throws {
        descriptor = AgentDescriptor(
            id: .assistant, name: "NexArm supervised diagnostic", inputs: [.event, .actionResult],
            outputs: [.actionCall, .control],
            capabilities: try CapabilityRegistry(internalActions: [
                InternalAction(module: "NexArm", function: "nudgeWrist", channel: "Arm", required: ["degrees"])
            ]))
    }
    func start() {}
    func pause() {}
    func resume() {}
    func stop() {}
    func status() -> AgentStatus {
        AgentStatus(lifecycle: .running, queuedInputs: 0, processedInputs: accepted == nil ? 0 : 1)
    }
    func receive(_ input: AgentInput) throws {
        if case .actionResult(let value) = input.payload {
            result = value
            return
        }
        guard accepted == nil else { throw HarnessError.queueFull }
        accepted = input
    }
}

private func runNexArmGatewayDiagnostic(link: any NexArmLink) async throws -> NexArmController.Motion {
    let controller = NexArmController(link: link)
    let manager = AgentManager()
    let agent = try NexArmDiagnosticAgent()
    let session = UUID()
    try await manager.register(agent, sessionID: session)
    let input = InputGateway(manager: manager)
    let assembly = try BehaviorAssembly(
        actionModules: [
            NexArmActionModule { delta, _ in
                try await controller.nudgeWrist(delta: delta)
            }
        ], toolModules: [], capabilities: [agent.descriptor.capabilities])
    let scheduler = ChannelScheduler(registry: assembly.actions, capacityPerChannel: 1, maximumTrackedInputs: 1)
    let output = OutputGateway(
        manager: manager, requests: input, tools: assembly.tools, actions: scheduler,
        actionFeedback: .terminal, sink: { _ in })
    do {
        let external = AgentInput(sessionID: session, payload: .event("supervised one-degree wrist nudge"))
        let delivery = try await input.send(external, to: .assistant)
        #expect(delivery.rejected.isEmpty)
        let accepted = try #require(await agent.accepted)
        let call = ActionCall(
            actionPath: ActionPath(module: "NexArm", function: "nudgeWrist"), channel: "Arm",
            parameters: ["degrees": "1"])
        try await output.dispatch(OutputEnvelope(source: .assistant, input: accepted, output: .actionCall(call)))
        try await output.dispatch(
            OutputEnvelope(source: .assistant, input: accepted, output: .control("agent.finished"), sequence: 1))
        let motion = try #require(await controller.lastMotion)
        #expect(abs(motion.observed - motion.target) <= 6)
        await output.shutdown()
        await link.close()
        return motion
    } catch {
        print(
            "NEXARM diagnostic failure: target=\(String(describing: await controller.attemptedTarget)) observed=\(String(describing: await controller.lastObserved)) cause=\(String(describing: await controller.lastFailure))"
        )
        await output.shutdown()
        await link.close()
        throw error
    }
}
@Test func nexArmGatewayDiagnosticAwaitsActionCompletion() async throws {
    let link = NexArmFixture()
    let motion = try await runNexArmGatewayDiagnostic(link: link)
    #expect(motion.observed == 2121)
    #expect(await link.writes == 1)
}
#if os(macOS)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXARM_MOTION_TEST"] == "1"))
    func nexArmUSBPhysicalAction() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["NEXARM_PORT"])
        let serial = try NexArmSerial(path: path)
        let motion = try await runNexArmGatewayDiagnostic(link: serial)
        print("NEXARM PHYSICAL WRIST: start=\(motion.start) target=\(motion.target) observed=\(motion.observed)")
    }
#endif

@Test func nexArmCancellationJoinsCommittedMotionAndRejectsConcurrentCommands() async throws {
    let link = NexArmFixture()
    let controller = NexArmController(link: link)
    let operation = Task { try await controller.nudgeWrist(delta: 1) }
    for _ in 0..<100 {
        if await link.writes == 1 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await link.writes == 1)
    await #expect(throws: NexArmError.busy) { try await controller.nudgeWrist(delta: 1) }
    operation.cancel()
    await #expect(throws: CancellationError.self) { try await operation.value }
    #expect(await controller.lastMotion?.observed == 2121)
    #expect(await link.writes == 1)
}

/// Controller simulation for base tests only; no hardware is touched by default checks.
private actor NexArmBaseFixture: NexArmLink {
    private var x = 270
    private var y = 0
    private var base = 2048
    private var readCount = 0
    private let fail: Bool
    private let wrongFirmware: Bool
    private let moving: Bool
    private(set) var writes = 0
    init(fail: Bool = false, wrongFirmware: Bool = false, moving: Bool = false) {
        self.fail = fail
        self.wrongFirmware = wrongFirmware
        self.moving = moving
    }
    func exchange(_ packet: NexArmPacket, replyID: UInt8, replyCommand: UInt8, replyCount: Int) throws -> NexArmPacket {
        if packet.command == 1 {
            return try NexArmPacket(command: 1, payload: wrongFirmware ? [0, 0, 0, 0, 0, 0] : [1, 0, 2, 1, 0, 2])
        }
        if packet.command == 0x32 {
            writes += 1
            if fail { throw NexArmError.timeout }
            #expect(Array(packet.payload[4..<12]) == Array(repeating: 0, count: 8))
            #expect(Array(packet.payload.suffix(2)) == [220, 5])
            let values = stride(from: 0, to: 4, by: 2).map {
                Int(Int16(bitPattern: UInt16(packet.payload[$0]) | UInt16(packet.payload[$0 + 1]) << 8))
            }
            x += values[0]
            y += values[1]
            base = 2048 - Int((atan2(Double(y), Double(x)) * 4096 / (2 * .pi)).rounded())
        }
        readCount += 1
        let values = [x, y, 350, -180, 0, -35, base + (moving ? readCount * 10 : 0), 2048, 2048, 2048, 2048, 1647]
        let payload = values.flatMap { value -> [UInt8] in
            let bits = UInt16(bitPattern: Int16(value))
            return [UInt8(bits & 255), UInt8(bits >> 8)]
        }
        return try NexArmPacket(command: 11, payload: payload)
    }
    func close() {}
}

@Test func nexArmBaseValidatesCyclesAndRejectsExtraParameters() async throws {
    for parameters in [
        [:], ["cycles": "0"], ["cycles": "4"], ["cycles": "1.5"], ["cycles": "-1"], ["cycles": "1", "degrees": "90"],
    ] {
        await #expect(throws: NexArmActions.ShakeError.invalidCycles) {
            try await NexArmActions.shakeBase(invocation: nexArmInvocation(parameters)) { _, _ in
                Issue.record("Invalid cycle request reached hardware")
            }
        }
    }
}

@Test func nexArmBaseRejectsPreflightAndLatchesUncertainWrite() async throws {
    let wrong = NexArmBaseFixture(wrongFirmware: true)
    await #expect(throws: NexArmError.unsupportedFirmware) {
        try await NexArmController(link: wrong).shakeBase(cycles: 1)
    }
    #expect(await wrong.writes == 0)
    let moving = NexArmBaseFixture(moving: true)
    await #expect(throws: NexArmError.moving) {
        try await NexArmController(link: moving).shakeBase(cycles: 1)
    }
    #expect(await moving.writes == 0)
    let link = NexArmBaseFixture(fail: true)
    let controller = NexArmController(link: link)
    for _ in 0..<2 {
        await #expect(throws: NexArmError.uncertainMotion) { try await controller.shakeBase(cycles: 1) }
    }
    #expect(await link.writes == 1)
    #expect(await controller.baseBaseline.count == 12)
    #expect(await controller.baseTarget.count == 6)
}

@Test func nexArmBaseCancellationJoinsOneLegAndDoesNotStartTheNext() async throws {
    let link = NexArmBaseFixture()
    let controller = NexArmController(link: link)
    let task = Task { try await controller.shakeBase(cycles: 3) }
    for _ in 0..<100 {
        if await link.writes == 1 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await link.writes == 1)
    await #expect(throws: NexArmError.busy) { try await controller.shakeBase(cycles: 1) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await link.writes == 1)
    #expect(await controller.lastBaseSweep == nil)
}

private struct NexArmAssistantUIModule: ActionModule {
    var definitions: [ActionDefinition] {
        ["express", "beginReplyTurn", "print"].map {
            ActionDefinition(
                path: ActionPath(module: "UI", function: $0), kind: .state,
                completion: "Test presentation accepted.", handler: { _ in })
        } + [
            ActionDefinition(
                path: ActionPath(module: "Speech", function: "speak"), kind: .finite,
                completion: "Test must never request speech.", handler: { _ in Issue.record("Unexpected speech") })
        ]
    }
}

/// Real Assistant/parser/Gateways/Action, with deterministic model output and test-only UI.
private func runNexArmAssistantBase(link: any NexArmLink, cycles: Int) async throws -> NexArmController.BaseSweep {
    let controller = NexArmController(link: link)
    do {
        try await runNexArmAssistantAction(cycles: cycles) { try await controller.shakeBase(cycles: $0) }
        let sweep = try #require(await controller.lastBaseSweep)
        await link.close()
        return sweep
    } catch {
        print(
            "NEXARM BASE failure: \(String(describing: await controller.lastFailure)) legs=\(await controller.completedBaseLegs)"
        )
        print(
            "baseline=\(await controller.baseBaseline) target=\(await controller.baseTarget) observed=\(await controller.baseObserved)"
        )
        await link.close()
        throw error
    }
}

func runNexArmAssistantAction(cycles: Int, move: @escaping @Sendable (Int) async throws -> Void) async throws {
    try await runNexArmAssistantMarkup("<shakeBase cycles=\"\(cycles)\"/>", function: "shakeBase", move: move)
}

private func runNexArmAssistantMarkup(
    _ markup: String, function: String, move: @escaping @Sendable (Int) async throws -> Void,
    gesture: @escaping @Sendable (NexArmActions.GestureRequest, ActionInvocation) async throws -> Void = { _, _ in
        throw NexArmError.invalidMotion
    }
) async throws {
    let assistant = try AssistantAgent(chat: FixedTextChat(text: markup))
    let manager = AgentManager()
    let session = UUID()
    try await manager.register(assistant, sessionID: session)
    let policy = try CommunicationPolicy(
        configurations: ["Assistant", "SpeechPerception", "SpeechSynthesis", "VisionPerception"].map {
            try AgentConfigurations.load(named: $0)
        })
    let input = InputGateway(manager: manager, policy: policy)
    let assembly = try BehaviorAssembly(
        actionModules: [
            NexArmBaseActionModule { count, _ in try await move(count) },
            NexArmGestureActionModule(perform: gesture),
            NexArmAssistantUIModule(),
        ],
        toolModules: [], capabilities: [])
    try assembly.actions.validate(capabilities: assistant.descriptor.capabilities)
    let scheduler = ChannelScheduler(registry: assembly.actions, capacityPerChannel: 1, maximumTrackedInputs: 1) {
        await input.deliverActionResult($0)
    }
    let output = OutputGateway(
        manager: manager, requests: input, tools: assembly.tools, actions: scheduler, policy: policy,
        actionFeedback: .terminal, sink: { _ in })
    do {
        try await assistant.bind(output.messaging(for: .assistant))
        try await assistant.start()
        let report = try await input.send(
            AgentInput(sessionID: session, payload: .text("执行请求的机械臂动作")), to: .assistant)
        #expect(report.rejected.isEmpty)
        for await envelope in assistant.outputs {
            try await output.dispatch(envelope)
            if envelope.output == .control("assistant.finished") { break }
            if case .control(let token) = envelope.output, token.hasPrefix("assistant.error") {
                throw NexArmError.invalidMotion
            }
        }
        var results = await assistant.actionResults()
        for _ in 0..<100 {
            if results.contains(where: { $0.path == ActionPath(module: "NexArm", function: function) }) { break }
            try await Task.sleep(for: .milliseconds(10))
            results = await assistant.actionResults()
        }
        #expect(
            results.contains {
                $0.path == ActionPath(module: "NexArm", function: function) && $0.status == .succeeded
            })
        await output.shutdown()
        await assistant.stop()
    } catch {
        await output.shutdown()
        await assistant.stop()
        throw error
    }
}

@Test func nexArmAssistantRegisteredBaseActionRunsRequestedCyclesAndReturns() async throws {
    let link = NexArmBaseFixture()
    let sweep = try await runNexArmAssistantBase(link: link, cycles: 2)
    #expect(sweep.cycles == 2)
    #expect(sweep.observed == [2026, 2070, 2048, 2026, 2070, 2048])
    #expect(await link.writes == 6)
}

#if os(macOS)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXARM_BASE_TEST"] == "1"))
    func nexArmUSBPhysicalBaseAction() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["NEXARM_PORT"])
        let raw = ProcessInfo.processInfo.environment["NEXARM_CYCLES"] ?? "1"
        let cycles = try #require(Int(raw))
        guard (1...3).contains(cycles) else { throw NexArmError.invalidMotion }
        let serial = try NexArmSerial(path: path)
        let sweep = try await runNexArmAssistantBase(link: serial, cycles: cycles)
        print("NEXARM PHYSICAL BASE: cycles=\(sweep.cycles) start=\(sweep.start) left/right/origin=\(sweep.observed)")
    }
#endif

private actor NexArmFirmwareFixture: NexArmLink {
    private let missingReplies: Int
    private let transportFailure: Bool
    private(set) var reads = 0
    init(missingReplies: Int, transportFailure: Bool = false) {
        self.missingReplies = missingReplies
        self.transportFailure = transportFailure
    }
    func close() {}
    func exchange(_ packet: NexArmPacket, replyID: UInt8, replyCommand: UInt8, replyCount: Int) throws -> NexArmPacket {
        #expect(packet.command == 1 && packet.payload.isEmpty)
        reads += 1
        if transportFailure { throw NexArmError.timeout }
        return try NexArmPacket(
            command: 1, payload: reads <= missingReplies ? [1, 0, 2, 0, 0, 0] : [1, 0, 2, 1, 0, 2])
    }
}

@Test func nexArmFirmwareReadRetriesOnlyExplicitMissingSubcontrollerVersion() async throws {
    let link = NexArmFirmwareFixture(missingReplies: 3)
    let controller = NexArmController(link: link)
    try await controller.verifyCompatibility()
    #expect(await link.reads == 4)
    try await controller.verifyCompatibility()
    #expect(await link.reads == 4)  // Reuse verified identity for this live connection only.
    let exhausted = NexArmFirmwareFixture(missingReplies: 10)
    await #expect(throws: NexArmError.firmwareUnavailable) {
        try await NexArmController(link: exhausted).verifyCompatibility()
    }
    #expect(await exhausted.reads == 4)
}

@Test func nexArmFirmwareReadDoesNotRetryTransportFailure() async throws {
    let link = NexArmFirmwareFixture(missingReplies: 0, transportFailure: true)
    await #expect(throws: NexArmError.timeout) {
        try await NexArmController(link: link).verifyCompatibility()
    }
    #expect(await link.reads == 1)
}

/// Telemetry simulator only: never opens Bluetooth or serial hardware.
private actor GestureArmFixture: NexArmWritableLink {
    private(set) var joints = [2048, 2087, 1225, 1238, 2048, 2048]
    private(set) var pose = [197, 0, 196, -12, 0, 0]
    private(set) var reached: [[Int]] = []
    private(set) var commands: [NexArmPacket] = []
    private var firstWriteWaiter: CheckedContinuation<Void, Never>?
    private var writeRelease: CheckedContinuation<Void, Never>?
    private var holdFirst = false
    private var failWrite = false
    private var disturbOtherJoint = false
    private var ignoreTarget = false
    private var ignoreFromWrite: Int?
    private var measuredPoseBias = false
    private var preparationPoseBias = false
    private var endingPoseBias = false
    private var emulateCartesianOwnership = false
    private var cartesianUntil = ContinuousClock.now
    private var cartesianTarget: [Int]?
    private(set) var overwrittenServoWrites = 0
    func configure(
        hold: Bool = false, fail: Bool = false, disturb: Bool = false, ignore: Bool = false, wrist: Int = 2048,
        ignoreFrom: Int? = nil, measuredBias: Bool = false, preparationBias: Bool = false, endingBias: Bool = false,
        cartesianOwnership: Bool = false
    ) {
        holdFirst = hold
        failWrite = fail
        disturbOtherJoint = disturb
        ignoreTarget = ignore
        ignoreFromWrite = ignoreFrom
        measuredPoseBias = measuredBias
        preparationPoseBias = preparationBias
        endingPoseBias = endingBias
        emulateCartesianOwnership = cartesianOwnership
        joints[4] = wrist
        if wrist == 4000 { pose[2] = 0 }
        if wrist == 2700 { pose = [150, 80, 290, 100, 20, 0] }
    }
    func waitForFirstWrite() async {
        if !commands.isEmpty { return }
        await withCheckedContinuation { firstWriteWaiter = $0 }
    }
    func releaseWrite() {
        writeRelease?.resume()
        writeRelease = nil
    }
    func write(_ packet: NexArmPacket) async throws {
        guard commands.count < 22 else { throw NexArmError.overflow }
        if packet.command == 3 && (packet.id == 4 || packet.id == 5) && packet.payload.count == 8 {
            commands.append(packet)
            if emulateCartesianOwnership && ContinuousClock.now < cartesianUntil {
                overwrittenServoWrites += 1
                return
            }
            if !ignoreTarget && (ignoreFromWrite.map { commands.count < $0 } ?? true) {
                joints[Int(packet.id) - 1] = Int(packet.payload[2]) | Int(packet.payload[3]) << 8
                // A native write changes physical pose without updating the Cartesian planner target.
                // This is a regression sentinel, not a forward-kinematics simulation.
                if emulateCartesianOwnership { pose[3] = -60 }
            }
            return
        }
        guard packet.id == 255, packet.command == 8, packet.payload.count == 14
        else { throw NexArmError.invalidPacket }
        commands.append(packet)
        if holdFirst && commands.count == 1 {
            await withCheckedContinuation {
                writeRelease = $0
                firstWriteWaiter?.resume()
                firstWriteWaiter = nil
            }
        } else {
            firstWriteWaiter?.resume()
            firstWriteWaiter = nil
        }
        if failWrite { throw NexArmError.timeout }
        if !ignoreTarget && (ignoreFromWrite.map { commands.count < $0 } ?? true) {
            let values = stride(from: 0, to: 12, by: 2).map {
                Int(Int16(bitPattern: UInt16(packet.payload[$0]) | UInt16(packet.payload[$0 + 1]) << 8))
            }
            let target = [values[1], values[2], values[3], values[0], values[4], values[5]]
            if emulateCartesianOwnership {
                let duration = Int(packet.payload[12]) | Int(packet.payload[13]) << 8
                cartesianUntil = .now.advanced(by: .milliseconds(duration))
                if cartesianTarget == target { return }
                cartesianTarget = target
            }
            pose = target
            if measuredPoseBias {
                pose[2] -= pose[2] == 200 ? 3 : 9
                pose[3] -= pose[2] < 200 ? 7 : 22
            }
            if (preparationPoseBias && commands.count == 1) || (endingPoseBias && commands.count > 1) {
                pose[2] -= 10
                pose[3] -= 30
            }
            // This arm has a different ID3 home encoder than the vendor example.
            joints = [2048 + pose[1], 2087, 1225 + pose[2] - 200, 1238, 2048 + pose[4] * 11, 2048]
            reached.append(pose)
        }
        if disturbOtherJoint { pose[2] += 20 }
    }
    func exchange(_ packet: NexArmPacket, replyID: UInt8, replyCommand: UInt8, replyCount: Int) throws -> NexArmPacket {
        guard packet.command == 11 else { throw NexArmError.invalidPacket }
        let values = pose + joints
        return try NexArmPacket(
            command: 11,
            payload: values.flatMap {
                let value = UInt16(bitPattern: Int16($0))
                return [UInt8(value & 255), UInt8(value >> 8)]
            })
    }
    func close() {}
}

@Test(arguments: ["waveWrist", "lookAround", "celebrate", "dance", "tiltWrist", "nodHead", "shakeHead"])
func nexArmGestureActionsRejectMalformedArgumentsBeforeEffects(_ function: String) async throws {
    let key = function == "waveWrist" ? "count" : "cycles"
    let invalid =
        function == "tiltWrist"
        ? [[:], ["direction": "up"], ["direction": "left", "speed": "50"]]
        : [[:], [key: "0"], [key: "4"], [key: "1.5"], [key: "nan"], [key: "1", "speed": "50"]]
    let registry = try ActionRegistry(modules: [
        NexArmGestureActionModule { _, _ in
            Issue.record("Invalid gesture reached physical binding")
        }
    ])
    for parameters in invalid {
        let invocation = ActionInvocation(
            source: .assistant, input: AgentInput(sessionID: UUID(), payload: .event("fixture")),
            call: ActionCall(
                actionPath: ActionPath(module: "NexArm", function: function), channel: "Robot", parameters: parameters))
        await #expect(throws: (any Error).self) {
            try await ActionExecutor(registry: registry).execute(invocation)
        }
    }
}

@Test(arguments: NexArmGesture.allCases.filter { $0 != .baseSway })
func nexArmAssistantGesturesReachTelemetryAndReturn(_ gesture: NexArmGesture) async throws {
    let fixture = GestureArmFixture()
    let controller = NexArmController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
    let function: String
    let parameters: String
    let expectedFrames: Int
    switch gesture {
    case .baseSway: return
    case .nod:
        function = "nodHead"
        parameters = "cycles='1'"
        expectedFrames = 8
    case .shakeHead:
        function = "shakeHead"
        parameters = "cycles='1'"
        expectedFrames = 8
    case .wave:
        function = "waveWrist"
        parameters = "count='1'"
        expectedFrames = 8
    case .tiltLeft:
        function = "tiltWrist"
        parameters = "direction='left'"
        expectedFrames = 5
    case .tiltRight:
        function = "tiltWrist"
        parameters = "direction='right'"
        expectedFrames = 5
    case .lookAround:
        function = "lookAround"
        parameters = "cycles='1'"
        expectedFrames = 7
    case .celebrate:
        function = "celebrate"
        parameters = "cycles='1'"
        expectedFrames = 8
    case .dance:
        function = "dance"
        parameters = "cycles='1'"
        expectedFrames = 10
    }
    try await runNexArmAssistantMarkup(
        "<wait><\(function) \(parameters)/></wait>", function: function,
        move: { _ in Issue.record("Unexpected base Action") },
        gesture: { request, _ in
            #expect(request.repetitions == 1)
            let expected: NexArmActions.Gesture
            switch gesture {
            case .baseSway: return
            case .nod: expected = .nod
            case .shakeHead: expected = .shakeHead
            case .wave: expected = .wave
            case .tiltLeft: expected = .tiltLeft
            case .tiltRight: expected = .tiltRight
            case .lookAround: expected = .lookAround
            case .celebrate: expected = .celebrate
            case .dance: expected = .dance
            }
            #expect(request.gesture == expected)
            try await controller.performGesture(gesture, repetitions: request.repetitions)
        })
    #expect(await fixture.pose == [200, 0, 200, 0, 0, 0])
    let commands = await fixture.commands
    #expect(commands.count == expectedFrames)
    let positions = await fixture.reached
    #expect(positions.first == [200, 0, 200, 0, 0, 0])
    #expect(positions.last == [200, 0, 200, 0, 0, 0])
    if let motor = gesture.motorID {
        #expect(commands.dropFirst(2).dropLast().allSatisfy { $0.id == motor && $0.command == 3 })
        let targets = commands.dropFirst(2).dropLast().map { Int($0.payload[2]) | Int($0.payload[3]) << 8 }
        #expect((targets.max() ?? 0) - (targets.min() ?? 0) == (motor == 4 ? 760 : 1000))
    } else {
        #expect(positions.contains { abs($0[1]) >= 40 && abs($0[4]) >= 15 })
    }
    #expect(await fixture.joints[2] == 1225)  // Calibration mismatch must not block completed motion.
    if gesture.motorID == nil {
        #expect(commands.dropFirst().dropLast().allSatisfy { $0.payload.suffix(2) == [0x20, 0x03] })
    }

}

@Test func nexArmGestureCancellationJoinsCommittedLegAndRejectsConcurrentOwner() async throws {
    let fixture = GestureArmFixture()
    await fixture.configure(hold: true)
    let controller = NexArmController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
    let task = Task { try await controller.performGesture(.dance, repetitions: 3) }
    await fixture.waitForFirstWrite()
    await #expect(throws: NexArmError.busy) { try await controller.performGesture(.wave, repetitions: 1) }
    task.cancel()
    await fixture.releaseWrite()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await fixture.commands.count == 1)
    #expect(await fixture.pose == [200, 0, 200, 0, 0, 0])  // Only preparation was committed.
}

@Test(arguments: [false, true])
func nexArmGestureFailureStopsSequenceButNextExplicitRequestCanStart(_ disturb: Bool) async throws {
    let fixture = GestureArmFixture()
    await fixture.configure(fail: !disturb, disturb: disturb)
    let controller = NexArmController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
    await #expect(throws: NexArmError.uncertainMotion) { try await controller.performGesture(.dance, repetitions: 3) }
    await #expect(throws: NexArmError.uncertainMotion) { try await controller.performGesture(.wave, repetitions: 1) }
    #expect(await fixture.commands.count == 2)
    #expect(await controller.motionFailure == (disturb ? .completionTimeout : .sending))
    await fixture.configure()
    try await controller.performGesture(.tiltLeft, repetitions: 1)
    #expect(await fixture.commands.count == 7)
    #expect(await fixture.pose == [200, 0, 200, 0, 0, 0])
    #expect(await controller.lastFailure == nil)
}

@Test func nexArmGestureValidatesWholePlanAndCountBeforeFirstWrite() async throws {
    let fixture = GestureArmFixture()
    await fixture.configure(wrist: 4000)
    let controller = NexArmController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
    await #expect(throws: NexArmError.invalidMotion) { try await controller.performGesture(.dance, repetitions: 1) }
    await #expect(throws: NexArmError.invalidMotion) { try await controller.performGesture(.wave, repetitions: 4) }
    await #expect(throws: NexArmError.invalidMotion) { try await controller.performGesture(.tiltLeft, repetitions: 2) }
    #expect(await fixture.commands.isEmpty == true)
}

@Test func nexArmGestureWriteAcknowledgmentCannotSubstituteForArrival() async throws {
    let fixture = GestureArmFixture()
    await fixture.configure(ignore: true, wrist: 2700)
    let controller = NexArmController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
    await #expect(throws: NexArmError.uncertainMotion) {
        try await controller.performGesture(.wave, repetitions: 1)
    }
    #expect(await fixture.commands.count == 1)
    let sample = try await controller.recoverState()
    #expect(sample.joints[4] == 2700)
    #expect(await fixture.commands.count == 1)  // Read-only recovery does not replay the failed wave.
    await fixture.configure()
    try await controller.performGesture(.tiltLeft, repetitions: 1)
    #expect(await fixture.commands.count == 6)
}

@Test func nexArmGestureMaximumRepetitionsRemainBoundedAndDoNotAccumulateOffset() async throws {
    let fixture = GestureArmFixture()
    let controller = NexArmController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
    try await controller.performGesture(.dance, repetitions: 3)
    #expect(await fixture.commands.count == 22)
    #expect(await fixture.pose == [200, 0, 200, 0, 0, 0])
}

@Test func nexArmChoreographyTargetsAreIndependentOfStartingPose() async throws {
    let first = GestureArmFixture()
    let second = GestureArmFixture()
    await second.configure(wrist: 2700)
    async let a: Void = NexArmController(link: first, compatibilityPolicy: .nexArmBLEProtocol)
        .performGesture(.wave, repetitions: 1)
    async let b: Void = NexArmController(link: second, compatibilityPolicy: .nexArmBLEProtocol)
        .performGesture(.wave, repetitions: 1)
    _ = try await (a, b)
    #expect(await first.reached == second.reached)

}

@Test func nexArmGestureMissedBodyWaypointCannotBeHiddenByReturningHome() async throws {
    let fixture = GestureArmFixture()
    await fixture.configure(ignoreFrom: 3)
    let controller = NexArmController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
    await #expect(throws: NexArmError.uncertainMotion) {
        try await controller.performGesture(.wave, repetitions: 1)
    }
    // Preparation and ready succeeded, but body did not move: stop before remaining body/home.
    #expect(await fixture.commands.count == 3)
    #expect(await fixture.pose != [200, 0, 200, 0, 0, 0])
}

@Test func nexArmBasePerformanceIsLargeFastAndIndependentOfEncoderCalibration() async throws {
    let fixture = GestureArmFixture()
    let controller = NexArmController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
    try await controller.performGesture(.baseSway, repetitions: 1)
    let reached = await fixture.reached
    #expect(reached.contains { $0[1] == -100 })
    #expect(reached.contains { $0[1] == 100 })
    #expect(reached.last == [200, 0, 200, 0, 0, 0])
    #expect(await fixture.commands.count == 7)
    #expect(
        await fixture.commands.dropFirst().dropLast().allSatisfy {
            $0.command == 8 && $0.payload.suffix(2) == [0x20, 0x03]
        })
}

#if os(macOS)
    /// Opt-in hardware acceptance uses the exact iPhone controller; only the link is serial.
    private actor NexArmPhysicalTrace: NexArmObservableLink {
        let serial: NexArmSerial
        private let started = ContinuousClock.now
        private var leg = 0
        init(path: String) throws { serial = try NexArmSerial(path: path) }
        func write(_ packet: NexArmPacket) async throws {
            let values = stride(from: 0, to: packet.payload.count - 1, by: 2).map {
                Int(Int16(bitPattern: UInt16(packet.payload[$0]) | UInt16(packet.payload[$0 + 1]) << 8))
            }
            print("PHYSICAL command=\(packet.command) values=\(values)")
            try await serial.write(packet)
        }
        func exchange(_ packet: NexArmPacket, replyID: UInt8, replyCommand: UInt8, replyCount: Int) async throws
            -> NexArmPacket
        {
            let reply = try await serial.exchange(
                packet, replyID: replyID, replyCommand: replyCommand, replyCount: replyCount)
            if reply.command == 11 {
                let values = stride(from: 0, to: 24, by: 2).map {
                    Int(Int16(bitPattern: UInt16(reply.payload[$0]) | UInt16(reply.payload[$0 + 1]) << 8))
                }
                print("PHYSICAL pose+joints=\(values)")
            }
            return reply
        }
        func beginObservation() async throws -> UUID { try await serial.beginObservation() }
        func sendObserved(_ packet: NexArmPacket, session: UUID) async throws -> Bool {
            if packet.command == 8 {
                leg += 1
                let values = stride(from: 0, to: packet.payload.count - 1, by: 2).map {
                    Int(Int16(bitPattern: UInt16(packet.payload[$0]) | UInt16(packet.payload[$0 + 1]) << 8))
                }
                print(
                    "OBSERVED MOTION leg=\(leg) elapsed=\(ContinuousClock.now - started) pitch/XYZ/roll/claw/ms=\(values)"
                )
            }
            if packet.command == 3 && packet.payload.count == 8 {
                leg += 1
                let target = Int(packet.payload[2]) | Int(packet.payload[3]) << 8
                let speed = Int(packet.payload[6]) | Int(packet.payload[7]) << 8
                print(
                    "OBSERVED MOTOR leg=\(leg) elapsed=\(ContinuousClock.now - started) id=\(packet.id) target=\(target) speed=\(speed)"
                )
            }
            return try await serial.sendObserved(packet, session: session)
        }
        func latestObservation(after sequence: UInt64, session: UUID) async throws -> NexArmTelemetry? {
            let sample = try await serial.latestObservation(after: sequence, session: session)
            if let sample {
                let values = stride(from: 0, to: 24, by: 2).map {
                    Int(
                        Int16(
                            bitPattern: UInt16(sample.packet.payload[$0]) | UInt16(sample.packet.payload[$0 + 1]) << 8))
                }
                print("OBSERVED SAMPLE leg=\(leg) elapsed=\(sample.receivedAt - started) pose+joints=\(values)")
            }
            return sample
        }
        func endObservation(_ session: UUID) async { await serial.endObservation(session) }
        func close() async { await serial.close() }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXARM_PRESETS_TEST"] == "1"))
    func nexArmUSBPhysicalPresetsSharedWithPhone() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["NEXARM_PORT"])
        let link = try NexArmPhysicalTrace(path: path)
        let controller = NexArmController(link: link)
        do {
            _ = try await controller.verifyCompatibility()
            let gestures: [NexArmGesture]
            switch ProcessInfo.processInfo.environment["NEXARM_PRESETS_FILTER"] {
            case "tilt": gestures = [.tiltLeft, .tiltRight]
            case "dance": gestures = [.dance]
            case "head": gestures = [.nod, .shakeHead]
            case nil: gestures = NexArmGesture.allCases
            default: throw NexArmError.invalidMotion
            }
            for gesture in gestures {
                print("PHYSICAL BEGIN \(gesture)")
                try await controller.performGesture(gesture, repetitions: 1)
                let sample = try await controller.readState()
                print("PHYSICAL PASS \(gesture) final=\(sample.pose) joints=\(sample.joints)")
                try await Task.sleep(for: .milliseconds(500))
            }
            await link.close()
        } catch {
            print(
                "PHYSICAL STOP error=\(error) detail=\(String(describing: await controller.motionFailure)) failure=\(String(describing: await controller.lastFailure))"
            )
            await link.close()
            throw error
        }
    }
#endif

@Test func nexArmGestureAcceptsMeasuredIntermediateAccuracyWithoutAccumulatingOffsets() async throws {
    let fixture = GestureArmFixture()
    await fixture.configure(measuredBias: true)
    let controller = NexArmController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
    try await controller.performGesture(.dance, repetitions: 1)
    #expect(await fixture.pose == [200, 0, 197, -7, 0, 0])
    #expect(await fixture.commands.count == 10)
    // Absolute targets remain exact even though feedback has the measured 9mm / 2.2° bias.
    #expect(await fixture.commands.first?.payload.prefix(8) == [0, 0, 200, 0, 0, 0, 200, 0])
    #expect(await fixture.commands.last?.payload.prefix(8) == [0, 0, 200, 0, 0, 0, 200, 0])
}

#if os(macOS)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXARM_JOG_TEST"] == "1"))
    func nexArmUSBPhysicalJogSharedWithPhone() async throws {
        let link = try NexArmSerial(path: #require(ProcessInfo.processInfo.environment["NEXARM_PORT"]))
        let controller = NexArmController(link: link)
        do {
            _ = try await controller.verifyCompatibility()
            try await controller.resetPosition()
            for id in 1...6 {
                let initial = try await controller.readState()
                var planner = try NexArmJogPlanner(positions: initial.joints)
                var writes = 0
                let began = ContinuousClock.now
                for _ in 0..<20 {
                    let tick = ContinuousClock.now
                    let proposal = try #require(try planner.proposal(id: id, deflection: 0.75))
                    if let packet = proposal.packet {
                        try await link.write(packet)
                        writes += 1
                    }
                    planner.accept(proposal)
                    try await Task.sleep(until: tick + .milliseconds(30))
                }
                planner.stop(id: id)
                try await Task.sleep(for: .milliseconds(800))
                let final = try await controller.readState()
                let target = Int(planner.targets[id - 1])
                print(
                    "JOG motor=\(id) writes=\(writes) elapsed=\(ContinuousClock.now - began) start=\(initial.joints) target=\(target) actual=\(final.joints)"
                )
                try #require(final.joints[id - 1] - initial.joints[id - 1] > 60)
                try #require(abs(final.joints[id - 1] - target) <= 23)
                for other in 0..<6 where other != id - 1 {
                    try #require(abs(final.joints[other] - initial.joints[other]) <= 12)
                }
                try await Task.sleep(for: .milliseconds(300))
                let held = try await controller.readState()
                try #require(abs(held.joints[id - 1] - final.joints[id - 1]) <= 3)
                // Explicit reset is separate from release and uses the shared controller.
                try await controller.resetPosition()
            }
            print("JOG SIX MOTORS PASS")
            await link.close()
        } catch {
            await link.close()
            throw error
        }
    }
#endif

@Test(arguments: [NexArmGesture.tiltLeft, .tiltRight])
func nexArmTiltKeepsReadyHeightAndCompletesItsReturn(_ gesture: NexArmGesture) async throws {
    let fixture = GestureArmFixture()
    await fixture.configure(measuredBias: true)
    let controller = NexArmController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
    try await controller.performGesture(gesture, repetitions: 1)
    let commands = await fixture.commands
    #expect(commands.count == 5)
    let values = commands.map { packet in
        stride(from: 0, to: 12, by: 2).map {
            Int(Int16(bitPattern: UInt16(packet.payload[$0]) | UInt16(packet.payload[$0 + 1]) << 8))
        }
    }
    #expect(values.map { $0[3] } == [200, 240, 240, 240, 200])
    #expect(values[2][4] == (gesture == .tiltLeft ? 40 : -40))
    #expect(values.last == [0, 200, 0, 200, 0, 0])
}

#if os(macOS)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXARM_SETTINGS_TEST"] == "1"))
    func nexArmUSBSettingsSequenceWithoutFeedbackWaits() async throws {
        let link = try NexArmPhysicalTrace(path: #require(ProcessInfo.processInfo.environment["NEXARM_PORT"]))
        let controller = NexArmController(link: link)
        do {
            _ = try await controller.verifyCompatibility()
            for gesture in [NexArmGesture.tiltLeft, .tiltRight] {
                let began = ContinuousClock.now
                for frame in try gesture.settingsTestFrames() {
                    print("SETTINGS SEND \(gesture) elapsed=\(ContinuousClock.now - began)")
                    try await link.write(frame.packet)
                    try await Task.sleep(for: .milliseconds(frame.milliseconds))
                }
                // Observation belongs to test acceptance, never the production send sequence.
                try await Task.sleep(for: .milliseconds(500))
                let sample = try await controller.readState()
                print("SETTINGS END \(gesture) pose=\(sample.pose)")
                try #require(zip(sample.pose.prefix(3), [200, 0, 200]).allSatisfy { abs($0 - $1) <= 5 })
                try #require(abs(sample.pose[3]) <= 20 && abs(sample.pose[4]) <= 2)
            }
            await link.close()
        } catch {
            await link.close()
            throw error
        }
    }
#endif

@Test func nexArmInvalidDanceArgumentsReportValidationWithoutDeviceEffects() async throws {
    let registry = try ActionRegistry(modules: [
        NexArmGestureActionModule { _, _ in Issue.record("Invalid parameters must not reach the device") }
    ])
    let call = ActionInvocation(
        source: .assistant, input: AgentInput(sessionID: UUID(), payload: .event("fixture")),
        call: ActionCall(
            actionPath: ActionPath(module: "NexArm", function: "dance"), channel: "Robot", parameters: ["cycles": "4"]))
    do {
        _ = try await ActionExecutor(registry: registry).execute(call)
        Issue.record("Expected invalid repetitions")
    } catch {
        #expect((error as? any ActionExecutionFailureProviding)?.actionExecutionFailure == .invalidArguments)
        #expect(error.localizedDescription == "跳舞次数必须是 1 到 3 的整数")
    }
}

@Test(arguments: [NexArmGesture.nod, .shakeHead])
func headSettingsUseOnlyRequestedMotorWithLargeFiniteSweeps(_ gesture: NexArmGesture) throws {
    let motor = try #require(gesture.motorID)
    let frames = try gesture.settingsTestFrames()
    #expect(frames.count == 7)
    #expect(frames.first?.packet.command == 8 && frames.last?.packet.command == 8)
    #expect(frames.allSatisfy { $0.packet.isLiveControl })
    let body = Array(frames.dropFirst().dropLast())
    #expect(body.allSatisfy { $0.packet.id == motor && $0.packet.isObservedControl })
    let targets = body.map { Int($0.packet.payload[2]) | Int($0.packet.payload[3]) << 8 }
    #expect(targets[0] == targets[2] && targets[1] == targets[3])
    #expect(targets[4] == NexArmJogPlanner.home[(gesture.motorID ?? 1) - 1])
    #expect(targets[1] - targets[0] == (gesture == .nod ? 760 : 1000))
    #expect(body.allSatisfy { Int($0.packet.payload[6]) | Int($0.packet.payload[7]) << 8 == 1400 })
}

@Test func headMotionArrivalRequiresEncoderTargetNotUnchangedCartesianFeedback() {
    let start = ContinuousClock.now
    let center = NexArmJogPlanner.home
    var target = center
    target[3] += 380
    var tracker = NexArmArrivalTracker(
        target: [200, 0, 200, 0, 0, 0], final: false,
        started: start, durationMilliseconds: 750, jointTarget: target)
    for tick in 0...5 {
        tracker.observe(
            pose: [200, 0, 200, 0, 0, 0], joints: center,
            at: start.advanced(by: .milliseconds(tick * 100)))
    }
    #expect(tracker.outcome(at: start.advanced(by: .milliseconds(500))) == .waiting)
    tracker.observe(pose: [200, 0, 200, 0, 0, 0], joints: target, at: start.advanced(by: .milliseconds(600)))
    tracker.observe(pose: [200, 0, 200, 0, 0, 0], joints: target, at: start.advanced(by: .milliseconds(850)))
    #expect(tracker.outcome(at: start.advanced(by: .milliseconds(850))) == .arrived)
}

@Test(arguments: [NexArmGesture.nod, .shakeHead])
func headPreparationUsesSameIntermediateToleranceAsOtherActions(_ gesture: NexArmGesture) async throws {
    let fixture = GestureArmFixture()
    await fixture.configure(preparationBias: true)
    let controller = NexArmController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
    try await controller.performGesture(gesture, repetitions: 1)
    let commands = await fixture.commands
    // Z190 / pitch-3deg is an accepted approach, but would fail the final-home contract.
    #expect(await fixture.reached.first == [200, 0, 190, -30, 0, 0])
    #expect(commands.count == 8)
    #expect(commands.filter { $0.command == 3 }.count == 5)
    #expect(await fixture.pose == [200, 0, 200, 0, 0, 0])
    #expect(await controller.motionFailure == nil)
}

@Test(arguments: [NexArmGesture.nod, .shakeHead])
func headEndingStillRequiresStrictObservedHome(_ gesture: NexArmGesture) async throws {
    let fixture = GestureArmFixture()
    await fixture.configure(endingBias: true)
    let controller = NexArmController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
    await #expect(throws: NexArmError.uncertainMotion) {
        try await controller.performGesture(gesture, repetitions: 1)
    }
    #expect(await fixture.commands.filter { $0.command == 3 }.count == 5)
    #expect(await fixture.commands.last?.command == 8)
    #expect(await controller.motionFailure == .completionTimeout)
}

@Test(arguments: [NexArmGesture.nod, .shakeHead])
func headHandoffWaitsForCartesianTrajectoryAndEndsAtDistinctTarget(_ gesture: NexArmGesture) async throws {
    let fixture = GestureArmFixture()
    await fixture.configure(cartesianOwnership: true)
    let controller = NexArmController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
    // Repeating from home must not bypass the firmware trajectory handoff.
    for _ in 0..<2 {
        try await controller.performGesture(gesture, repetitions: 1)
        #expect(await fixture.pose == [200, 0, 200, 0, 0, 0])
    }
    #expect(await fixture.overwrittenServoWrites == 0)
    #expect(await fixture.commands.filter { $0.command == 3 }.count == 10)
}

@Test func headHandoffRequiresFreshFeedbackAfterTrajectoryDuration() {
    let start = ContinuousClock.now
    let pose = [200, 0, 240, 0, 0, 0]
    let joints = NexArmJogPlanner.home
    var tracker = NexArmArrivalTracker(
        target: pose, final: false, started: start, durationMilliseconds: 800,
        minimumObservationMilliseconds: 800)
    tracker.observe(pose: pose, joints: joints, at: start)
    tracker.observe(pose: pose, joints: joints, at: start.advanced(by: .milliseconds(250)))
    #expect(tracker.outcome(at: start.advanced(by: .milliseconds(250))) == .waiting)
    // Wall time alone cannot release the firmware's trajectory ownership.
    #expect(tracker.outcome(at: start.advanced(by: .milliseconds(900))) == .waiting)
    tracker.observe(pose: pose, joints: joints, at: start.advanced(by: .milliseconds(900)))
    #expect(tracker.outcome(at: start.advanced(by: .milliseconds(900))) == .arrived)
}

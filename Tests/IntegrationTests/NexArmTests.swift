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
    let assistant = try AssistantAgent(chat: FixedTextChat(text: "<shakeBase cycles=\"\(cycles)\"/>"))
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
            AgentInput(sessionID: session, payload: .text("底座左右晃动 \(cycles) 次")), to: .assistant)
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
            if results.contains(where: { $0.path == ActionPath(module: "NexArm", function: "shakeBase") }) { break }
            try await Task.sleep(for: .milliseconds(10))
            results = await assistant.actionResults()
        }
        #expect(
            results.contains {
                $0.path == ActionPath(module: "NexArm", function: "shakeBase") && $0.status == .succeeded
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

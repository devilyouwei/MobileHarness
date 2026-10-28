import Actions
import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import PlatformKit
import StorageCore
import Testing

@testable import Agents

/// Deliberately simple IK fixture; does not model physical kinematics.
struct NexArmTestIK {
    var intents: [[Int]: NexArmPacket] = [:]
    mutating func reply(_ request: NexArmPacket) throws -> NexArmPacket {
        let v = words(request.payload)
        let pose = [v[1], v[2], v[3], v[0], v[4], v[5]]
        let joints = [2048 + v[2], 2087, 1225 + v[3] - 200, 1238, 2048 + v[4] * 11]
        intents[joints] = try NexArmPacket(command: 8, payload: request.payload)
        return try NexArmPacket(
            command: 7,
            payload: (pose + joints + [2048]).flatMap {
                let bits = UInt16(bitPattern: Int16($0))
                return [UInt8(bits & 255), UInt8(bits >> 8)]
            })
    }
    func intent(_ packet: NexArmPacket) throws -> NexArmPacket {
        guard packet.isSynchronousPositionWrite else { throw NexArmError.invalidPacket }
        let joints = (0..<5).map { index in
            let offset = 2 + index * 8
            return Int(packet.payload[offset + 2]) | Int(packet.payload[offset + 3]) << 8
        }
        guard let intent = intents[joints] else { throw NexArmError.invalidPacket }
        return intent
    }
    func words(_ payload: [UInt8]) -> [Int] {
        stride(from: 0, to: payload.count, by: 2).map {
            Int(Int16(bitPattern: UInt16(payload[$0]) | UInt16(payload[$0 + 1]) << 8))
        }
    }
}

private actor NexArmFixture: NexArmWritableLink {
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
        #expect(packet.command == 11)
        position += speed * 10
        return try telemetry()
    }
    func write(_ packet: NexArmPacket) throws {
        #expect(packet.id == 5 && packet.command == 3)
        writes += 1
        if failWrite { throw NexArmError.timeout }
        let target = Int(packet.payload[2]) | Int(packet.payload[3]) << 8
        roll += Int((Double(target - position) * 360 / 4096).rounded())
        position = target
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

@Test(.actionCatalog) func nexArmFramingHandlesFragmentationLogsAndChecksum() throws {
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

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmLegacyMotionVerifiesAndAllowsOnlyOneNudge() async throws {
        let link = NexArmFixture()
        let controller = NexArmLegacyDiagnosticController(link: link)
        try await controller.nudgeWrist(delta: 1)
        #expect(await controller.lastMotion?.start == 2110)
        #expect(await controller.lastMotion?.observed == 2121)
        await #expect(throws: NexArmLegacyDiagnosticError.alreadyUsed) { try await controller.nudgeWrist(delta: 1) }
        #expect(await link.writes == 1)
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmLegacyMotionRefusesUnknownFirmwareAndMovingDevice() async throws {
        let wrong = NexArmFixture()
        await wrong.configure(wrong: true)
        await #expect(throws: NexArmExecutionError.unsupportedFirmware) {
            try await NexArmLegacyDiagnosticController(link: wrong).nudgeWrist(delta: 1)
        }
        #expect(await wrong.writes == 0)
        let moving = NexArmFixture()
        await moving.configure(moving: true)
        await #expect(throws: NexArmActionError.moving) {
            try await NexArmLegacyDiagnosticController(link: moving).nudgeWrist(delta: 1)
        }
        #expect(await moving.writes == 0)
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmLegacyUncertainWriteIsNeverRetried() async throws {
        let link = NexArmFixture()
        await link.configure(fail: true)
        let controller = NexArmLegacyDiagnosticController(link: link)
        await #expect(throws: NexArmActionError.uncertainMotion) { try await controller.nudgeWrist(delta: 1) }
        await #expect(throws: NexArmActionError.uncertainMotion) { try await controller.nudgeWrist(delta: 1) }
        #expect(await link.writes == 1)
    }
}

#if os(macOS)
    extension LiveRuntimeTests {
        @Test(.actionCatalog, .enabled(if: ProcessInfo.processInfo.environment["NEXARM_MOTION_TEST"] == "1"))
        func nexArmUSBLegacyPhysicalWristDiagnostic() async throws {
            let path = try #require(ProcessInfo.processInfo.environment["NEXARM_PORT"])
            let serial = try NexArmSerial(path: path)
            let controller = NexArmLegacyDiagnosticController(link: serial)
            do {
                try await controller.nudgeWrist(delta: 1)
                let motion = try #require(await controller.lastMotion)
                #expect(abs(motion.observed - motion.target) <= 6)
                print(
                    "NEXARM PHYSICAL WRIST: start=\(motion.start) target=\(motion.target) observed=\(motion.observed)")
                await serial.close()
            } catch {
                await serial.close()
                throw error
            }
        }
    }
#endif

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmLegacyCancellationJoinsCommittedMotionAndRejectsConcurrentCommands() async throws {
        let link = NexArmFixture()
        let controller = NexArmLegacyDiagnosticController(link: link)
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
}

/// Controller simulation for base tests only; no hardware is touched by default checks.
private actor NexArmBaseFixture: NexArmWritableLink {
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
        readCount += 1
        let values = [x, y, 350, -180, 0, -35, base + (moving ? readCount * 10 : 0), 2048, 2048, 2048, 2048, 1647]
        let payload = values.flatMap { value -> [UInt8] in
            let bits = UInt16(bitPattern: Int16(value))
            return [UInt8(bits & 255), UInt8(bits >> 8)]
        }
        return try NexArmPacket(command: 11, payload: payload)
    }
    func write(_ packet: NexArmPacket) throws {
        #expect(packet.id == 1 && packet.command == 3)
        writes += 1
        if fail { throw NexArmError.timeout }
        base = Int(packet.payload[2]) | Int(packet.payload[3]) << 8
        let angle = Double(2048 - base) * 2 * .pi / 4096
        x = Int((270 * cos(angle)).rounded())
        y = Int((270 * sin(angle)).rounded())
    }
    func close() {}
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmBaseValidatesCyclesAndRejectsExtraParameters() async throws {
        for parameters in [
            [:], ["cycles": "0"], ["cycles": "4"], ["cycles": "1.5"], ["cycles": "-1"],
            ["cycles": "1", "degrees": "90"],
        ] {
            await #expect(throws: NexArmActions.ShakeError.invalidCycles) {
                let invocation = ActionInvocation(
                    source: .assistant,
                    input: AgentInput(
                        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .event("test")),
                    call: ActionCall(
                        actionPath: ActionPath(domain: "NexArm", module: "Motion", function: "shakeBase"),
                        channel: "Robot",
                        parameters: parameters))
                try await NexArmActions.shakeBase(invocation: invocation) { _, _ in
                    Issue.record("Invalid cycle request reached hardware")
                }
            }
        }
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmLegacyBaseRejectsPreflightAndLatchesUncertainWrite() async throws {
        let wrong = NexArmBaseFixture(wrongFirmware: true)
        await #expect(throws: NexArmExecutionError.unsupportedFirmware) {
            try await NexArmLegacyDiagnosticController(link: wrong).shakeBase(cycles: 1)
        }
        #expect(await wrong.writes == 0)
        let moving = NexArmBaseFixture(moving: true)
        await #expect(throws: NexArmActionError.moving) {
            try await NexArmLegacyDiagnosticController(link: moving).shakeBase(cycles: 1)
        }
        #expect(await moving.writes == 0)
        let link = NexArmBaseFixture(fail: true)
        let controller = NexArmLegacyDiagnosticController(link: link)
        for _ in 0..<2 {
            await #expect(throws: NexArmActionError.uncertainMotion) { try await controller.shakeBase(cycles: 1) }
        }
        #expect(await link.writes == 1)
        #expect(await controller.baseBaseline.count == 12)
        #expect(await controller.baseTarget.count == 6)
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmLegacyBaseCancellationJoinsOneLegAndDoesNotStartTheNext() async throws {
        let link = NexArmBaseFixture()
        let controller = NexArmLegacyDiagnosticController(link: link)
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
}

struct NexArmAssistantUIModule: ActionModule {
    var definitions: [ActionBinding] {
        ["express", "setExpression", "setReplyWaiting", "beginReplyTurn", "print"].map {
            ActionBinding(
                path: ActionPath(
                    domain: "UI", module: ["beginReplyTurn", "print"].contains($0) ? "Caption" : "Expression",
                    function: $0), displayName: "测试动作",
                kind: $0 == "express" ? .finite : .state,
                completion: "Test presentation accepted.", handler: { _ in })
        } + [
            ActionBinding(
                path: ActionPath(domain: "Speech", module: "Playback", function: "speak"), displayName: "测试动作",
                kind: .finite,
                completion: "Test must never request speech.", handler: { _ in Issue.record("Unexpected speech") })
        ]

    }
}

/// Real Assistant/parser/Gateways/Action, with deterministic model output and test-only UI.
private func runNexArmAssistantBase(link: any NexArmLink, cycles: Int) async throws
    -> NexArmLegacyDiagnosticController.BaseSweep
{
    let controller = NexArmLegacyDiagnosticController(link: link)
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
    gesture: @escaping @Sendable (NexArmActions.GestureRequest, any FunctionInput) async throws -> Void = { _, _ in
        throw NexArmError.invalidMotion
    }
) async throws {
    let defaultBindings =
        try AgentConfigurations.skill("expression-interaction").useActions
        + AgentConfigurations.skill("robot-interaction").useActions
    let assistant = try AgentChatWorker<AssistantContextState>(
        stateContext: try publicStateFixture(),
        chat: FixedTextChat(text: markup),
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "assistant"), scope: UUID().uuidString, state: AssistantContextState()),
        capabilities: AgentConfigurations.registry(defaultBindings)
    )
    let manager = AgentManager()
    let session = UUID().uuidString
    try await manager.register(assistant, sessionID: session)
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication,
        configurations: AgentConfigurations.all())
    let input = InputGateway(manager: manager, policy: policy)
    let assembly = try BehaviorAssembly(
        actionModules: [
            ScheduledFunctionFixture(NexArmBaseModule { count, _ in try await move(count) }),
            ScheduledFunctionFixture(NexArmGestureModule(perform: gesture)),
            NexArmAssistantUIModule(),
        ],
        toolModules: [])
    try assembly.actions.validate(capabilities: assistant.descriptor.capabilities)
    let scheduler = ChannelScheduler(
        registry: assembly.actions, capacityPerChannel: 1, maximumTrackedInputs: 1, resources: try nexArmTestResources()
    ) {
        await input.deliverActionResult($0)
    }
    let output = await OutputGateway(
        manager: manager, requests: input, tools: assembly.tools, actions: scheduler, policy: policy,
        actionFeedback: .terminal, sink: { _ in })
    do {
        try await assistant.bind(output.messaging(for: .assistant))
        try await assistant.start()
        let report = try await manager.receiveLocally(
            AgentInput(id: UUID().uuidString, sessionID: session, payload: .text("执行请求的机械臂动作")),
            to: .assistant)
        #expect(report.rejected.isEmpty)
        for await envelope in fixtureOutputs(assistant) {
            try await output.dispatch(envelope)
            if envelope.output == .control("agent.finished") { break }
            if case .control(let token) = envelope.output, token.hasPrefix("assistant.error") {
                throw NexArmError.invalidMotion
            }
        }
        var results = await assistant.actionResults()
        for _ in 0..<100 {
            if results.contains(where: {
                $0.path
                    == ActionPath(
                        domain: "NexArm",
                        module: ["shakeBase", "reset", "moveMotor", "resetMotor"].contains(function)
                            ? "Motion" : "Gesture", function: function)
            }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
            results = await assistant.actionResults()
        }
        #expect(
            results.contains {
                $0.path
                    == ActionPath(
                        domain: "NexArm",
                        module: ["shakeBase", "reset", "moveMotor", "resetMotor"].contains(function)
                            ? "Motion" : "Gesture", function: function) && $0.status == .succeeded
            })
        await output.shutdown()
        await assistant.stop()
    } catch {
        await output.shutdown()
        await assistant.stop()
        throw error
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmLegacyAssistantBaseDiagnosticRunsRequestedCyclesAndReturns() async throws {
        let link = NexArmBaseFixture()
        let sweep = try await runNexArmAssistantBase(link: link, cycles: 2)
        #expect(sweep.cycles == 2)
        #expect(sweep.observed == [2025, 2071, 2048, 2025, 2071, 2048])
        #expect(await link.writes == 6)
    }
}

#if os(macOS)
    extension LiveRuntimeTests {
        @Test(.actionCatalog, .enabled(if: ProcessInfo.processInfo.environment["NEXARM_BASE_TEST"] == "1"))
        func nexArmUSBLegacyPhysicalBaseAction() async throws {
            let path = try #require(ProcessInfo.processInfo.environment["NEXARM_PORT"])
            let raw = ProcessInfo.processInfo.environment["NEXARM_CYCLES"] ?? "1"
            let cycles = try #require(Int(raw))
            guard (1...3).contains(cycles) else { throw NexArmError.invalidMotion }
            let serial = try NexArmSerial(path: path)
            let sweep = try await runNexArmAssistantBase(link: serial, cycles: cycles)
            print(
                "NEXARM PHYSICAL BASE: cycles=\(sweep.cycles) start=\(sweep.start) left/right/origin=\(sweep.observed)")
        }
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

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmFirmwareReadRetriesOnlyExplicitMissingSubcontrollerVersion() async throws {
        let link = NexArmFirmwareFixture(missingReplies: 3)
        let controller = NexArmActionController(link: link)
        try await controller.verifyCompatibility()
        #expect(await link.reads == 4)
        try await controller.verifyCompatibility()
        #expect(await link.reads == 4)  // Reuse verified identity for this live connection only.
        let exhausted = NexArmFirmwareFixture(missingReplies: 10)
        await #expect(throws: NexArmExecutionError.firmwareUnavailable) {
            try await NexArmActionController(link: exhausted).verifyCompatibility()
        }
        #expect(await exhausted.reads == 4)
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmFirmwareReadDoesNotRetryTransportFailure() async throws {
        let link = NexArmFirmwareFixture(missingReplies: 0, transportFailure: true)
        await #expect(throws: NexArmError.timeout) {
            try await NexArmActionController(link: link).verifyCompatibility()
        }
        #expect(await link.reads == 1)
    }
}

/// Telemetry simulator only: never opens Bluetooth or serial hardware.
private actor GestureArmFixture: NexArmObservableLink {
    private var readFailure = false
    func failReads() { readFailure = true }
    private var observation: String?
    private var telemetry = NexArmTelemetryCache()
    private var lastPush = ContinuousClock.now.advanced(by: .seconds(-1))
    private var ik = NexArmTestIK()
    func intents() throws -> [NexArmPacket] {
        try commands.filter { $0.isSynchronousPositionWrite }.map { try ik.intent($0) }
    }
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
    func beginObservation() -> String {
        let token = UUID().uuidString
        observation = token
        return token
    }
    func endObservation(_ session: String) { if observation == session { observation = nil } }
    func sendObserved(_ packet: NexArmPacket, session: String) async throws -> Bool {
        guard observation == session else { throw CancellationError() }
        try await write(packet)
        return true
    }
    func latestObservation(after sequence: UInt64, session: String) throws -> NexArmTelemetry? {
        guard observation == session else { throw CancellationError() }
        if ContinuousClock.now - lastPush >= .milliseconds(100) {
            try telemetry.receive(
                exchange(NexArmPacket(command: 11), replyID: 255, replyCommand: 11, replyCount: 24).bytes)
            lastPush = .now
        }
        guard let value = telemetry.latest, value.sequence > sequence else { return nil }
        return value
    }
    func write(_ packet: NexArmPacket) async throws {
        guard commands.count < 40, let targets = packet.motorTargets else { throw NexArmError.invalidMotion }
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
            for (id, target) in targets { joints[id - 1] = target }
            if packet.isSynchronousPositionWrite, targets.count == 5 {
                let values = ik.words(try ik.intent(packet).payload)
                pose = [values[1], values[2], values[3], values[0], values[4], values[5]]
                if measuredPoseBias {
                    pose[2] -= pose[2] == 200 ? 3 : 9
                    pose[3] -= pose[2] < 200 ? 7 : 22
                }
                if (preparationPoseBias && commands.count == 1) || (endingPoseBias && commands.count > 1) {
                    pose[2] -= 10
                    pose[3] -= 30
                }
                reached.append(pose)
            }
        }
        if disturbOtherJoint { joints[2] += 60 }
    }
    func exchange(_ packet: NexArmPacket, replyID: UInt8, replyCommand: UInt8, replyCount: Int) throws -> NexArmPacket {
        if readFailure { throw NexArmError.timeout }
        if packet.command == 7 { return try ik.reply(packet) }
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

extension LiveRuntimeTests {
    @Test(
        .actionCatalog,
        arguments: ["waveWrist", "lookAround", "celebrate", "dance", "tiltWrist", "nodHead", "shakeHead"])
    func nexArmGestureActionsRejectMalformedArgumentsBeforeEffects(_ function: String) async throws {
        let key = function == "waveWrist" ? "count" : "cycles"
        let invalid =
            function == "tiltWrist"
            ? [[:], ["direction": "up"], ["direction": "left", "speed": "0"]]
            : [[:], [key: "0"], [key: "4"], [key: "1.5"], [key: "nan"], [key: "1", "speed": "0"]]
        let registry = try ActionRegistry(modules: [
            NexArmGestureModule { _, _ in
                Issue.record("Invalid gesture reached physical binding")
            }
        ])
        for parameters in invalid {
            let invocation = ActionInvocation(
                source: .assistant,
                input: AgentInput(
                    id: UUID().uuidString, sessionID: UUID().uuidString, payload: .event("fixture")),
                call: ActionCall(
                    actionPath: ActionPath(
                        domain: "NexArm",
                        module: ["shakeBase", "reset", "moveMotor", "resetMotor"].contains(function)
                            ? "Motion" : "Gesture",
                        function: function), channel: "Robot", parameters: parameters))
            await #expect(throws: (any Error).self) {
                try await ActionExecutor(registry: registry).execute(invocation)
            }
        }
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog, arguments: NexArmGesture.allCases.filter { $0 != .baseSway })
    func nexArmAssistantGesturesReachTelemetryAndReturn(_ gesture: NexArmGesture) async throws {
        let fixture = GestureArmFixture()
        let controller = NexArmActionController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
        let function: String
        let parameters: String
        let expectedFrames: Int
        switch gesture {
        case .baseSway: return
        case .nod:
            function = "nodHead"
            parameters = "cycles='1'"
            expectedFrames = 6
        case .shakeHead:
            function = "shakeHead"
            parameters = "cycles='1'"
            expectedFrames = 6
        case .wave:
            function = "waveWrist"
            parameters = "count='1'"
            expectedFrames = 6
        case .tiltLeft:
            function = "tiltWrist"
            parameters = "direction='left'"
            expectedFrames = 3
        case .tiltRight:
            function = "tiltWrist"
            parameters = "direction='right'"
            expectedFrames = 3
        case .lookAround:
            function = "lookAround"
            parameters = "cycles='1'"
            expectedFrames = 5
        case .celebrate:
            function = "celebrate"
            parameters = "cycles='1'"
            expectedFrames = 6
        case .dance:
            function = "dance"
            parameters = "cycles='1'"
            expectedFrames = 8
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
        if gesture.motorID == nil { #expect(await fixture.pose == [200, 0, 200, 0, 0, 0]) }
        let commands = await fixture.commands
        #expect(commands.count == expectedFrames)
        let positions = await fixture.reached
        if gesture.motorID == nil {
            #expect(positions.first == [200, 0, 200, 0, 0, 0])
            #expect(positions.last == [200, 0, 200, 0, 0, 0])
        }
        if let motor = gesture.motorID {
            #expect(commands.dropFirst().dropLast().allSatisfy { $0.id == motor && $0.command == 3 })
            let targets = commands.dropFirst().dropLast().map { Int($0.payload[2]) | Int($0.payload[3]) << 8 }
            #expect((targets.max() ?? 0) - (targets.min() ?? 0) == (motor == 4 ? 760 : 1000))
        } else {
            #expect(positions.contains { abs($0[1]) >= 40 && abs($0[4]) >= 15 })
        }
        #expect(await fixture.joints[2] == 1225)  // Calibration mismatch must not block completed motion.
        if gesture.motorID == nil {
            #expect(commands.dropFirst().dropLast().allSatisfy { $0.isSynchronousPositionWrite })
        }

    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmGestureCancellationJoinsCommittedLegAndRejectsConcurrentOwner() async throws {
        let fixture = GestureArmFixture()
        await fixture.configure(hold: true)
        let controller = NexArmActionController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
        let task = Task { try await controller.performGesture(.dance, repetitions: 3) }
        await fixture.waitForFirstWrite()
        await #expect(throws: NexArmExecutionError.busy) { try await controller.performGesture(.wave, repetitions: 1) }
        task.cancel()
        await fixture.releaseWrite()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await fixture.commands.count == 1)
        #expect(await fixture.pose == [200, 0, 200, 0, 0, 0])  // Only the scoped home was committed.
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog, arguments: [false, true])
    func nexArmGestureFailureContinuesAndNextExplicitRequestCanStart(_ disturb: Bool) async throws {
        let fixture = GestureArmFixture()
        await fixture.configure(fail: !disturb, disturb: disturb)
        let controller = NexArmActionController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
        await #expect(throws: (any Error).self) { try await controller.performGesture(.dance, repetitions: 3) }
        await #expect(throws: (any Error).self) { try await controller.performGesture(.wave, repetitions: 1) }
        let failedWrites = 26
        #expect(await fixture.commands.count == failedWrites)
        #expect(await controller.motionFailure == (disturb ? .completionTimeout : .sending))
        await fixture.configure()
        try await controller.performGesture(.tiltLeft, repetitions: 1)
        #expect(await fixture.commands.count == failedWrites + 3)
        #expect(await fixture.pose == [200, 0, 200, 0, 0, 0])
        #expect(await controller.lastFailure == nil)
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmGestureValidatesWholePlanAndCountBeforeFirstWrite() async throws {
        let fixture = GestureArmFixture()
        await fixture.configure(wrist: 4000)
        let controller = NexArmActionController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
        await #expect(throws: NexArmExecutionError.invalidArguments) {
            try await controller.performGesture(.dance, repetitions: 1)
        }
        await #expect(throws: NexArmExecutionError.invalidArguments) {
            try await controller.performGesture(.wave, repetitions: 4)
        }
        await #expect(throws: NexArmExecutionError.invalidArguments) {
            try await controller.performGesture(.tiltLeft, repetitions: 2)
        }
        #expect(await fixture.commands.isEmpty == true)
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmGestureWriteAcknowledgmentCannotSubstituteForArrival() async throws {
        let fixture = GestureArmFixture()
        await fixture.configure(ignore: true, wrist: 2700)
        let controller = NexArmActionController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
        await #expect(throws: (any Error).self) {
            try await controller.performGesture(.wave, repetitions: 1)
        }
        #expect(await fixture.commands.count == 6)
        let sample = try await controller.recoverState()
        #expect(sample.joints[4] == 2700)
        #expect(await fixture.commands.count == 6)  // Read-only recovery does not replay the failed wave.
        await fixture.configure()
        try await controller.performGesture(.tiltLeft, repetitions: 1)
        #expect(await fixture.commands.count == 9)
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmGestureMaximumRepetitionsRemainBoundedAndDoNotAccumulateOffset() async throws {
        let fixture = GestureArmFixture()
        let controller = NexArmActionController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
        try await controller.performGesture(.dance, repetitions: 3)
        #expect(await fixture.commands.count == 20)
        #expect(await fixture.pose == [200, 0, 200, 0, 0, 0])
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmChoreographyTargetsAreIndependentOfStartingPose() async throws {
        let first = GestureArmFixture()
        let second = GestureArmFixture()
        await second.configure(wrist: 2700)
        async let a: Void = NexArmActionController(link: first, compatibilityPolicy: .nexArmBLEProtocol)
            .performGesture(.wave, repetitions: 1)
        async let b: Void = NexArmActionController(link: second, compatibilityPolicy: .nexArmBLEProtocol)
            .performGesture(.wave, repetitions: 1)
        _ = try await (a, b)
        #expect(await first.reached == second.reached)

    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmGestureMissingFinalHomeFailsAfterTimedPlayback() async throws {
        let fixture = GestureArmFixture()
        await fixture.configure(ignoreFrom: 3)
        let controller = NexArmActionController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
        await #expect(throws: (any Error).self) {
            try await controller.performGesture(.wave, repetitions: 1)
        }
        // Timed body playback does not claim intermediate arrival; a missed final home still fails.
        #expect(await fixture.commands.count == 6)
        #expect(await fixture.pose != [200, 0, 200, 0, 0, 0])
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmBasePerformanceIsLargeFastAndIndependentOfEncoderCalibration() async throws {
        let fixture = GestureArmFixture()
        let controller = NexArmActionController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
        try await controller.performGesture(.baseSway, repetitions: 1)
        let reached = await fixture.reached
        #expect(reached.contains { $0[1] == -100 })
        #expect(reached.contains { $0[1] == 100 })
        #expect(reached.last == [200, 0, 200, 0, 0, 0])
        #expect(await fixture.commands.count == 5)
        #expect(
            await fixture.commands.dropFirst().dropLast().allSatisfy {
                $0.isSynchronousPositionWrite
            })
    }
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
        func beginObservation() async throws -> String { try await serial.beginObservation() }
        func sendObserved(_ packet: NexArmPacket, session: String) async throws -> Bool {
            if packet.isSynchronousPositionWrite {
                leg += 1
                let values = stride(from: 0, to: packet.payload.count - 1, by: 2).map {
                    Int(Int16(bitPattern: UInt16(packet.payload[$0]) | UInt16(packet.payload[$0 + 1]) << 8))
                }
                print(
                    "OBSERVED MOTION leg=\(leg) elapsed=\(ContinuousClock.now - started) sync-arm-payload=\(values)"
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
        func latestObservation(after sequence: UInt64, session: String) async throws -> NexArmTelemetry? {
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
        func endObservation(_ session: String) async { await serial.endObservation(session) }
        func close() async { await serial.close() }
    }

    extension LiveRuntimeTests {
        @Test(.actionCatalog, .enabled(if: ProcessInfo.processInfo.environment["NEXARM_PRESETS_TEST"] == "1"))
        func nexArmUSBPhysicalPresetsSharedWithPhone() async throws {
            let path = try #require(ProcessInfo.processInfo.environment["NEXARM_PORT"])
            let link = try NexArmPhysicalTrace(path: path)
            let controller = NexArmActionController(link: link)
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
    }
#endif

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmGestureAcceptsMeasuredIntermediateAccuracyWithoutAccumulatingOffsets() async throws
    {
        let fixture = GestureArmFixture()
        await fixture.configure(measuredBias: true)
        let controller = NexArmActionController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
        try await controller.performGesture(.dance, repetitions: 1)
        #expect(await fixture.pose == [200, 0, 197, -7, 0, 0])
        #expect(await fixture.commands.count == 8)
        // Absolute targets remain exact even though feedback has the measured 9mm / 2.2° bias.
        #expect(try await fixture.intents().first?.payload.prefix(8) == [0, 0, 200, 0, 0, 0, 200, 0])
        #expect(try await fixture.intents().last?.payload.prefix(8) == [0, 0, 200, 0, 0, 0, 200, 0])
    }
}

#if os(macOS)
    extension LiveRuntimeTests {
        @Test(.actionCatalog, .enabled(if: ProcessInfo.processInfo.environment["NEXARM_JOG_TEST"] == "1"))
        func nexArmUSBPhysicalJogSharedWithPhone() async throws {
            let link = try NexArmSerial(path: #require(ProcessInfo.processInfo.environment["NEXARM_PORT"]))
            let controller = NexArmActionController(link: link)
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
    }
#endif

extension LiveRuntimeTests {
    @Test(.actionCatalog, arguments: [NexArmGesture.tiltLeft, .tiltRight])
    func nexArmTiltHomesOwnedMotorsBeforeAndAfterItsBody(_ gesture: NexArmGesture) async throws {
        let fixture = GestureArmFixture()
        await fixture.configure(measuredBias: true)
        let controller = NexArmActionController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
        try await controller.performGesture(gesture, repetitions: 1)
        let commands = await fixture.commands
        #expect(commands.count == 3)
        let values = try await fixture.intents().map { packet in
            stride(from: 0, to: 12, by: 2).map {
                Int(Int16(bitPattern: UInt16(packet.payload[$0]) | UInt16(packet.payload[$0 + 1]) << 8))
            }
        }
        #expect(values.map { $0[3] } == [200, 240, 200])
        #expect(values[1][4] == (gesture == .tiltLeft ? 40 : -40))
        #expect(values.last == [0, 200, 0, 200, 0, 0])
    }
}

#if os(macOS)
    extension LiveRuntimeTests {
        @Test(.actionCatalog, .enabled(if: ProcessInfo.processInfo.environment["NEXARM_SETTINGS_TEST"] == "1"))
        func nexArmUSBSettingsSequenceWithoutFeedbackWaits() async throws {
            let link = try NexArmPhysicalTrace(path: #require(ProcessInfo.processInfo.environment["NEXARM_PORT"]))
            let controller = NexArmActionController(link: link)
            do {
                _ = try await controller.verifyCompatibility()
                for gesture in [NexArmGesture.tiltLeft, .tiltRight] {
                    let began = ContinuousClock.now
                    let plan = try await controller.prepareArmControl()
                    let state = try await controller.readState()
                    for frame in try plan.compile(gesture.settingsTestFrames(), from: state.joints) {
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
    }
#endif

extension LiveRuntimeTests {
    @Test(.actionCatalog) func nexArmInvalidDanceArgumentsReportValidationWithoutDeviceEffects() async throws {
        let registry = try ActionRegistry(modules: [
            NexArmGestureModule { _, _ in Issue.record("Invalid parameters must not reach the device") }
        ])
        let call = ActionInvocation(
            source: .assistant,
            input: AgentInput(
                id: UUID().uuidString, sessionID: UUID().uuidString, payload: .event("fixture")),
            call: ActionCall(
                actionPath: ActionPath(domain: "NexArm", module: "Gesture", function: "dance"), channel: "Robot",
                parameters: ["cycles": "4"]))
        do {
            _ = try await ActionExecutor(registry: registry).execute(call)
            Issue.record("Expected invalid repetitions")
        } catch {
            #expect((error as? any ActionReportFailureProviding)?.actionExecutionFailure == .invalidArguments)
            #expect(error.localizedDescription == "跳舞次数必须是 1 到 3 的整数")
        }
    }
}

@Test(.actionCatalog, arguments: [NexArmGesture.nod, .shakeHead])
func headSettingsUseOnlyRequestedMotorWithLargeFiniteSweeps(_ gesture: NexArmGesture) throws {
    let motor = try #require(gesture.motorID)
    let frames = try gesture.settingsTestFrames()
    #expect(frames.count == 6)
    #expect(frames.allSatisfy { $0.packet.id == motor && $0.packet.command == 3 && $0.packet.isLiveControl })
    let targets = frames.map { Int($0.packet.payload[2]) | Int($0.packet.payload[3]) << 8 }
    #expect(targets.first == targets.last)
    #expect(targets[1] == targets[3] && targets[2] == targets[4])
    #expect(targets[2] - targets[1] == (gesture == .nod ? 760 : 1000))
}

@Test(.actionCatalog) func headMotionArrivalRequiresEncoderTargetNotUnchangedCartesianFeedback() {
    let start = ContinuousClock.now
    let center = NexArmGesture.referenceHomeJoints
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

extension LiveRuntimeTests {
    @Test(.actionCatalog, arguments: [NexArmGesture.nod, .shakeHead])
    func headPreparationAndReturnLeaveUnrelatedMotorsUntouched(_ gesture: NexArmGesture) async throws {
        let fixture = GestureArmFixture()
        await fixture.configure(wrist: 2700, preparationBias: true)
        let before = await fixture.joints
        let controller = NexArmActionController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
        try await controller.performGesture(gesture, repetitions: 1)
        let commands = await fixture.commands
        let id = try #require(gesture.motorID)
        #expect(commands.count == 6 && commands.allSatisfy { $0.id == id })
        let after = await fixture.joints
        for index in 0..<6 where index != id - 1 { #expect(before[index] == after[index]) }
        #expect(await fixture.reached.isEmpty)
        #expect(await controller.lockedMotors.isEmpty)
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog, arguments: [NexArmGesture.nod, .shakeHead])
    func headEndingVerifiesOnlyItsOwnMotor(_ gesture: NexArmGesture) async throws {
        let fixture = GestureArmFixture()
        await fixture.configure(ignoreFrom: 6)
        let controller = NexArmActionController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
        await #expect(throws: NexArmActionError.targetsNotReached([6])) {
            try await controller.performGesture(gesture, repetitions: 1)
        }
        #expect(await fixture.commands.count == 6)
        #expect(await controller.unreachedSegments == [6])
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog, arguments: [NexArmGesture.nod, .shakeHead])
    func headFeedbackAdvancesWithoutCartesianOrNominalWait(_ gesture: NexArmGesture) async throws {
        let fixture = GestureArmFixture()
        let controller = NexArmActionController(link: fixture, compatibilityPolicy: .nexArmBLEProtocol)
        let began = ContinuousClock.now
        for _ in 0..<2 { try await controller.performGesture(gesture, repetitions: 1) }
        #expect(ContinuousClock.now - began < .seconds(5))
        #expect(await fixture.commands.count == 12)
        let motor = try #require(gesture.motorID)
        #expect(await fixture.commands.allSatisfy { Int($0.id) == motor })
        #expect(await fixture.reached.isEmpty)
    }
}

@Test(.actionCatalog) func headHandoffRequiresFreshFeedbackAfterTrajectoryDuration() {
    let start = ContinuousClock.now
    let pose = [200, 0, 240, 0, 0, 0]
    let joints = NexArmGesture.referenceHomeJoints
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

@Test(.actionCatalog) func nexArmAllPresetsCompileToArmOnlyTargetsAndRejectWholeDeviceCommands() throws {
    var fixture = NexArmTestIK()
    var plan = NexArmArmPlan()
    for gesture in NexArmGesture.allCases {
        for frame in try gesture.settingsTestFrames() where frame.packet.command == 8 {
            try plan.insert(frame, reply: fixture.reply(NexArmPacket(command: 7, payload: frame.packet.payload)))
            #expect(!frame.packet.isLiveControl && !frame.packet.isObservedControl)
        }
    }
    var measured = NexArmGesture.referenceHomeJoints
    measured[5] = 1647
    for gesture in NexArmGesture.allCases {
        let frames = try plan.compile(gesture.settingsTestFrames(), from: measured)
        for frame in frames {
            let packet = frame.packet
            #expect(packet.isLiveControl && packet.isObservedControl)
            if packet.isSynchronousPositionWrite {
                let ids: [UInt8] = (0..<5).map { packet.payload[2 + $0 * 8] }
                #expect(ids == [1, 2, 3, 4, 5])
                var injected = packet.payload
                injected[34] = 6
                let bad = try NexArmPacket(id: 254, command: 131, payload: injected)
                // Explicit gripper atoms are supported, but cannot enter an arm-only performance plan.
                #expect(throws: NexArmExecutionError.invalidArguments) {
                    try NexArmMotionPlan(lockedMotors: Set(1...5), frames: [.init(packet: bad, milliseconds: 1000)])
                }
            } else {
                #expect(packet.command == 3 && (4...5).contains(packet.id))
            }
        }
    }
    #expect(try plan.home(from: measured).packet.isSynchronousPositionWrite)
    #expect(try !NexArmPacket(command: 54, payload: [0xD0, 0x07]).isLiveControl)
    // A deliberately selected manual gripper jog remains available independently.
    let manual = try NexArmJogPlanner(positions: measured).proposal(id: 6, deflection: 1)
    #expect(manual?.id == 6)
    var otherClaw = measured
    otherClaw[5] = 2600
    #expect(
        try plan.compile(NexArmGesture.dance.settingsTestFrames(), from: measured).map(\.packet)
            == plan.compile(NexArmGesture.dance.settingsTestFrames(), from: otherClaw).map(\.packet))
    #expect(throws: NexArmExecutionError.invalidArguments) {
        try NexArmArmPlan().compile(NexArmGesture.dance.settingsTestFrames(), from: measured)
    }
}

@Test(.actionCatalog) func nexArmIKValidationFailsBeforeMotionForWrongPoseOrInvalidArmJoint() throws {
    let frame = try #require(NexArmGesture.dance.settingsTestFrames().first)
    var fixture = NexArmTestIK()
    let response = try fixture.reply(NexArmPacket(command: 7, payload: frame.packet.payload))
    for index in [0, 12] {
        var bytes = response.payload
        bytes[index] = 255
        bytes[index + 1] = 127
        var plan = NexArmArmPlan()
        #expect(throws: NexArmExecutionError.invalidArguments) {
            try plan.insert(frame, reply: NexArmPacket(command: 7, payload: bytes))
        }
    }
}

func nexArmTestResources() throws -> ResourceCoordinator {
    try ResourceCoordinator(
        definitions: (1...6).map { motor in
            ResourceDefinition(id: ResourceID(rawValue: "nexarm.motor.\(motor)"), allowedOwners: [.assistant]) {}
        })
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func atomicMotorOptionsResetAndScopeUseTheSameExecutor() async throws {
        let link = GestureArmFixture()
        let controller = NexArmActionController(link: link, compatibilityPolicy: .nexArmBLEProtocol)
        let options = try NexArmMotorOptions(speed: 900, acceleration: 80)
        try await controller.moveMotor(id: 4, target: 1500, options: options, completion: NexArmMotorCompletion())
        #expect(await controller.motorResults.count == 1)
        #expect(await controller.motorResults.first?.failure == nil)
        let moved = try #require(await link.commands.first)
        #expect(moved.id == 4 && moved.payload[1] == 80)
        #expect(Int(moved.payload[6]) | Int(moved.payload[7]) << 8 == 900)
        try await controller.configureMotorHome(id: 6, target: 1400)
        try await controller.resetMotor(id: 6, options: options, completion: NexArmMotorCompletion())
        #expect(await link.commands.map(\.id) == [4, 6])
        #expect(await controller.motorResults.first?.motor == 6)
        #expect(await controller.cachedJoints[3] == 1500)
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func atomicStableOffTargetEndsBeforeOverallDeadlineAndKeepsError() async throws {
        let link = GestureArmFixture()
        await link.configure(ignore: true)
        let controller = NexArmActionController(link: link, compatibilityPolicy: .nexArmBLEProtocol)
        let policy = try NexArmMotorCompletion(offTargetMilliseconds: 300, timeoutMilliseconds: 3000)
        let began = ContinuousClock.now
        await #expect(throws: NexArmActionError.targetsNotReached([1])) {
            try await controller.moveMotor(id: 4, target: 1800, options: NexArmMotorOptions(), completion: policy)
        }
        #expect(ContinuousClock.now - began < .seconds(2))
        #expect(await controller.motorResults.first?.failure == .targetNotReached)
        await link.configure()
        try await controller.moveMotor(id: 4, target: 1500, options: NexArmMotorOptions(), completion: policy)
        #expect(await controller.motorResults.first?.failure == nil)
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func composedAtomicMotorGroupsOwnUnionAndTrackEachMotor() async throws {
        let options = try NexArmMotorOptions(speed: 750, acceleration: 50)
        let first = try NexArmMotorCommands.move(motor: 4, target: 1500, options: options)
        let second = try NexArmMotorCommands.move(motor: 5, target: 1900, options: options)
        let ending = try NexArmMotorCommands.move(motor: 4, target: 1238, options: options)
        let plan = try NexArmMotionPlan(groups: [[first, second], [ending]])
        #expect(plan.lockedMotors == [4, 5])
        #expect(plan.steps[0].packet.motorTargets == [4: 1500, 5: 1900])
        #expect(throws: NexArmError.invalidMotion) { try NexArmMotionPlan(groups: [[first, first]]) }
        let link = GestureArmFixture()
        let controller = NexArmActionController(link: link, compatibilityPolicy: .nexArmBLEProtocol)
        try await controller.performPlan(plan, completion: NexArmMotorCompletion())
        #expect(await link.commands.count == 2)
        #expect(await controller.motorResults.count == 3)
        #expect(await controller.motorResults.allSatisfy { $0.failure == nil })
        #expect(await controller.cachedJoints[4] == 1900)
    }
}

#if os(macOS)
    extension LiveRuntimeTests {
        @Test(.actionCatalog, .enabled(if: ProcessInfo.processInfo.environment["NEXARM_ATOMIC_TEST"] == "1"))
        func nexArmUSBPhysicalAtomicGroupAndReset() async throws {
            let link = try NexArmPhysicalTrace(path: #require(ProcessInfo.processInfo.environment["NEXARM_PORT"]))
            let controller = NexArmActionController(link: link)
            do {
                _ = try await controller.verifyCompatibility()
                let calibration = try await controller.prepareArmControl()
                let home = try calibration.homeJoints
                let options = try NexArmMotorOptions(speed: 800, acceleration: 50)
                let outward = try [4, 5].map {
                    try NexArmMotorCommands.move(motor: $0, target: home[$0 - 1] + 80, options: options)
                }
                let ending = try [4, 5].map {
                    try NexArmMotorReset.reset(motor: $0, home: [4: home[3], 5: home[4]], options: options)
                }
                try await controller.performPlan(
                    NexArmMotionPlan(groups: [outward, ending]), completion: NexArmMotorCompletion())
                let results = await controller.motorResults
                print("ATOMIC GROUP RESULTS \(results)")
                #expect(results.count == 4 && results.allSatisfy { $0.failure == nil })
                #expect(Set(results.map(\.motor)) == [4, 5])
                await link.close()
            } catch {
                print("ATOMIC GROUP STOP \(error), results=\(await controller.motorResults)")
                await link.close()
                throw error
            }
        }
    }
#endif

@Test(.actionCatalog) func nexArmRelativeDegreesRejectLimitsAndDoNotWrap() throws {
    #expect(try NexArmMotorCommands.relativeTarget(motor: 1, from: 2048, deltaDegrees: 90) == 3072)
    #expect(try NexArmMotorCommands.relativeTarget(motor: 1, from: 2048, deltaDegrees: -45) == 1536)
    #expect(try NexArmMotorCommands.relativeTarget(motor: 3, from: 1200, deltaDegrees: 22.5) == 1456)
    for id in 1...6 {
        let range = NexArmDeviceLimits.positions[id - 1]
        #expect(
            try NexArmMotorCommands.relativeTarget(motor: id, from: range.upperBound, deltaDegrees: 0)
                == range.upperBound)
        #expect(throws: NexArmError.invalidMotion) {
            try NexArmMotorCommands.relativeTarget(motor: id, from: range.upperBound, deltaDegrees: 1)
        }
        #expect(throws: NexArmError.invalidMotion) {
            try NexArmMotorCommands.relativeTarget(motor: id, from: range.lowerBound, deltaDegrees: -1)
        }
    }
    for delta in [Double.nan, .infinity, -.infinity, 361, -361] {
        #expect(throws: NexArmError.invalidMotion) {
            try NexArmMotorCommands.relativeTarget(motor: 1, from: 2048, deltaDegrees: delta)
        }
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func relativeMotorMoveReadsActualPositionAndRejectsWithoutWrite() async throws {
        let link = GestureArmFixture()
        let controller = NexArmActionController(link: link, compatibilityPolicy: .passiveBLE)
        let options = try NexArmMotorOptions(speed: 400)
        try await controller.moveMotor(id: 1, target: 2200, options: options, completion: .init())
        try await controller.moveMotor(id: 1, deltaDegrees: 90, options: options, completion: .init())
        #expect(await link.commands.last?.motorTargets == [1: 3224])
        try await controller.moveMotor(id: 1, deltaDegrees: -45, options: options, completion: .init())
        #expect(await link.commands.last?.motorTargets == [1: 2712])
        await #expect(throws: NexArmError.invalidMotion) {
            try await controller.moveMotor(id: 1, deltaDegrees: 180, options: options, completion: .init())
        }
        #expect(await link.commands.count == 3)
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func motorActionRejectsAmbiguousAndInvalidTargetsBeforeEffects() async throws {
        let registry = try ActionRegistry(modules: [
            NexArmGestureModule { _, _ in Issue.record("Invalid motor request reached device binding") }
        ])
        for parameters in [
            ["motor": "1"], ["motor": "1", "target": "2048", "deltaDegrees": "90"],
            ["motor": "3", "target": "900"], ["motor": "1", "deltaDegrees": "nan"],
            ["motor": "1", "deltaDegrees": "361"], ["motor": "7", "deltaDegrees": "10"],
            ["motor": "1", "deltaDegrees": "90", "speed": "2000"],
        ] {
            let invocation = ActionInvocation(
                source: .assistant,
                input: AgentInput(id: UUID().uuidString, sessionID: UUID().uuidString, payload: .event("fixture")),
                call: ActionCall(
                    actionPath: ActionPath(domain: "NexArm", module: "Motion", function: "moveMotor"),
                    channel: "Robot", parameters: parameters))
            await #expect(throws: (any Error).self) {
                try await ActionExecutor(registry: registry).execute(invocation)
            }
        }
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func relativeMotorMoveDoesNotUseCachedPoseAfterReadFailure() async throws {
        let link = GestureArmFixture()
        let controller = NexArmActionController(link: link, compatibilityPolicy: .passiveBLE)
        _ = try await controller.readState()
        await link.failReads()
        await #expect(throws: NexArmError.timeout) {
            try await controller.moveMotor(id: 1, deltaDegrees: 90, options: .init(), completion: .init())
        }
        #expect(await link.commands.isEmpty)
    }
}

extension LiveRuntimeTests {
    @Test(.actionCatalog) func motorActionDispatchesRelativeDegreesWithoutInventingTarget() async throws {
        let registry = try ActionRegistry(modules: [
            NexArmGestureModule { request, _ in
                #expect(request.gesture == .moveMotor)
                #expect(request.motor == 1 && request.target == nil && request.deltaDegrees == -45)
                #expect(request.speed == 400 && request.acceleration == 30)
            }
        ])
        let invocation = ActionInvocation(
            source: .assistant,
            input: AgentInput(id: UUID().uuidString, sessionID: UUID().uuidString, payload: .event("fixture")),
            call: ActionCall(
                actionPath: ActionPath(domain: "NexArm", module: "Motion", function: "moveMotor"), channel: "Robot",
                parameters: ["motor": "1", "deltaDegrees": "-45", "speed": "400", "acceleration": "30"]))
        try await ActionExecutor(registry: registry).execute(invocation)
    }
}

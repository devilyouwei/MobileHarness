import Actions
import AgentCore
import Agents
import AppWorkflows
import BehaviorAssembly
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import ModelKit
import Storage
import Testing
import UI

@testable import PlatformKit

#if os(macOS)
    private actor SerialControlFailureProbe {
        private(set) var failure: NexArmControlFailure?
        func record(_ value: NexArmControlFailure) {
            if failure != nil { Issue.record("More than one worker failure in a single serial trial") }
            failure = value
        }
    }
    /// Test-only connection façade: all packets and telemetry use the real serial SDK.
    /// It exercises App's BLE-specific injection seam, not CoreBluetooth/radio behavior.
    private actor SerialSettingsLink: NexArmBluetoothLink {
        nonisolated let id = UUID()
        nonisolated let updates: AsyncStream<NexArmBluetoothSnapshot>
        private let continuation: AsyncStream<NexArmBluetoothSnapshot>.Continuation
        private let path: String
        private var serial: NexArmSerial?
        private var wireSession: UUID?
        private var observation: UUID?
        private var live: UUID?
        private var reader: Task<Void, Never>?
        private var exchanging = false
        private var wireSequence: UInt64 = 0
        private var cache = NexArmTelemetryCache()
        private var budget = NexArmBLETrafficBudget()
        private var snapshot = NexArmBluetoothSnapshot()
        private(set) var writes = 0
        private(set) var targets: [Int: Int] = [:]
        private(set) var samples = 0
        private let started = ContinuousClock.now

        init(path: String) {
            self.path = path
            let pair = AsyncStream<NexArmBluetoothSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
            updates = pair.stream
            continuation = pair.continuation
            snapshot.power = .poweredOn
        }
        private var device: NexArmBluetoothDevice { .init(id: id, name: "Nex_Arm (USB acceptance)", rssi: 0) }
        private func publish() {
            snapshot.revision &+= 1
            continuation.yield(snapshot)
        }
        func status() -> NexArmBluetoothSnapshot { snapshot }
        func scan() {
            snapshot.devices = [device]
            snapshot.scanning = true
            publish()
        }
        func stopScan() {
            snapshot.scanning = false
            publish()
        }
        func clearDiscovery() {
            snapshot.devices = []
            publish()
        }
        func forgetDevice() async {
            await disconnect()
            snapshot.selected = nil
            publish()
        }
        func connect(_ id: UUID) async throws {
            guard id == self.id, serial == nil else { throw NexArmError.busy }
            let link = try NexArmSerial(path: path)
            serial = link
            cache = NexArmTelemetryCache()
            budget = NexArmBLETrafficBudget()
            wireSequence = 0
            wireSession = try await link.beginObservation()
            snapshot.connectionID = UUID()
            snapshot.phase = .connected
            snapshot.selected = device
            snapshot.failure = nil
            snapshot.feedbackPacket = nil
            snapshot.feedbackReceivedAt = nil
            publish()
            reader = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await self?.readAvailable()
                        try await Task.sleep(for: .milliseconds(10))
                    } catch {
                        if !(error is CancellationError) { print("SERIAL READER ERROR \(error)") }
                        return
                    }
                }
            }
        }
        func disconnect() async {
            reader?.cancel()
            reader = nil
            observation = nil
            live = nil
            wireSession = nil
            let previous = serial
            serial = nil
            await previous?.close()
            snapshot.phase = .disconnected
            snapshot.feedbackPacket = nil
            snapshot.feedbackReceivedAt = nil
            publish()
        }
        func close() async { await disconnect() }
        private func readAvailable() async throws {
            guard !exchanging, let serial, let wireSession else { return }
            if let sample = try await serial.latestObservation(after: wireSequence, session: wireSession) {
                guard self.wireSession == wireSession, sample.sequence > wireSequence else { return }
                guard samples < 1024 else { throw NexArmError.overflow }
                wireSequence = sample.sequence
                try cache.receive(sample.packet.bytes, at: sample.receivedAt)
                samples += 1
                snapshot.feedbackPacket = sample.packet
                snapshot.feedbackReceivedAt = sample.receivedAt
                publish()
                let joints = stride(from: 12, to: 24, by: 2).map {
                    Int(sample.packet.payload[$0]) | Int(sample.packet.payload[$0 + 1]) << 8
                }
                print("SERIAL RX t=\(sample.receivedAt - started) joints=\(joints)")
            }
        }
        func beginObservation() throws -> UUID {
            guard serial != nil else { throw NexArmError.disconnected }
            guard !exchanging, observation == nil, live == nil else { throw NexArmError.busy }
            let token = UUID()
            observation = token
            return token
        }
        func endObservation(_ session: UUID) { if observation == session { observation = nil } }
        func latestObservation(after sequence: UInt64, session: UUID) async throws -> NexArmTelemetry? {
            guard serial != nil, observation == session else { throw NexArmError.disconnected }
            try await readAvailable()
            guard let sample = cache.latest, sample.sequence > sequence else { return nil }
            return sample
        }
        func beginLiveControl() throws -> UUID {
            guard serial != nil else { throw NexArmError.disconnected }
            guard !exchanging else { throw NexArmError.busy }
            observation = nil
            let token = UUID()
            live = token
            return token
        }
        func endLiveControl(_ session: UUID) { if live == session { live = nil } }
        func sendObserved(_ packet: NexArmPacket, session: UUID) async throws -> Bool {
            guard observation == session else { throw NexArmError.disconnected }
            return try await send(packet)
        }
        func sendLive(_ packet: NexArmPacket, session: UUID) async throws -> Bool {
            guard live == session else { throw NexArmError.disconnected }
            return try await send(packet)
        }
        private func send(_ packet: NexArmPacket) async throws -> Bool {
            try Task.checkCancellation()
            guard let serial, let wireSession, !exchanging else { throw NexArmError.disconnected }
            guard budget.canSend(at: .now, systemReady: true) else { return false }
            guard writes < 512 else { throw NexArmError.overflow }
            let admitted = try await serial.sendObserved(packet, session: wireSession)
            if admitted {
                budget.sent(bytes: packet.bytes.count, at: .now)
                writes += 1
                if let targets = packet.motorTargets { self.targets = targets }
                print(
                    "SERIAL TX t=\(ContinuousClock.now - started) command=\(packet.command) targets=\(packet.motorTargets ?? [:])"
                )
            }
            return admitted
        }
        func write(_ packet: NexArmPacket) async throws {
            while try await !send(packet) { try await Task.sleep(for: .milliseconds(10)) }
        }
        func exchange(_ packet: NexArmPacket, replyID: UInt8, replyCommand: UInt8, replyCount: Int) async throws
            -> NexArmPacket
        {
            guard let serial, let wireSession else { throw NexArmError.disconnected }
            guard !exchanging, observation == nil, live == nil else { throw NexArmError.busy }
            exchanging = true
            defer { exchanging = false }
            await serial.endObservation(wireSession)
            self.wireSession = nil
            do {
                if let deadline = budget.nextWrite { try await Task.sleep(until: deadline, clock: .continuous) }
                let sentAt = ContinuousClock.now
                let reply = try await serial.exchange(
                    packet, replyID: replyID, replyCommand: replyCommand, replyCount: replyCount)
                budget.sent(bytes: packet.bytes.count, at: sentAt)
                self.wireSession = try await serial.beginObservation()
                wireSequence = 0
                return reply
            } catch {
                self.wireSession = try? await serial.beginObservation()
                wireSequence = 0
                throw error
            }
        }
    }

    @MainActor
    private func serialWait(
        seconds: Int = 20, _ label: String, until predicate: @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        print("SERIAL WAIT FAILED \(label)")
        throw NexArmError.timeout
    }

    /// Real Assistant, parser, Gateways, scheduler and Action modules; deterministic model output.
    @MainActor
    private func serialAssistant(
        _ markup: String, workflow: BluetoothWorkflow, expected: ActionExecutionRecord.Phase
    ) async throws {
        let assistant = try AgentChatWorker<AssistantContextState>(chat: FixedTextChat(text: markup))
        let manager = AgentManager()
        let session = UUID()
        try await manager.register(assistant, sessionID: session)
        let policy = try CommunicationPolicy(
            contracts: AgentContracts.communication,
            externalSources: [
                "user", "runtime", "phone.microphone", "phone.camera", "model.resources", "app.resources",
                "app.environment",
            ],
            configurations: AgentConfigurations.all())
        let input = InputGateway(manager: manager, policy: policy, allowsExternalSend: true)
        let assembly = try BehaviorAssembly(
            actionModules: [
                ScheduledFunctionFixture(
                    NexArmGestureModule { request, invocation in
                        let record: @Sendable (ActionReport) async throws -> Void = {
                            try await invocation.results.record($0)
                        }
                        switch request.gesture {
                        case .moveMotor, .resetMotor:
                            guard let motor = request.motor else { throw NexArmExecutionError.invalidArguments }
                            try await workflow.moveMotor(
                                id: motor, target: request.target, speed: request.speed,
                                acceleration: request.acceleration,
                                recordReport: record)
                        case .reset:
                            try await workflow.resetArm(
                                speed: request.speed, acceleration: request.acceleration, recordReport: record)
                        default:
                            let gesture: NexArmGesture
                            switch request.gesture {
                            case .nod: gesture = .nod
                            case .shakeHead: gesture = .shakeHead
                            case .wave: gesture = .wave
                            case .tiltLeft: gesture = .tiltLeft
                            case .tiltRight: gesture = .tiltRight
                            case .lookAround: gesture = .lookAround
                            case .celebrate: gesture = .celebrate
                            case .dance: gesture = .dance
                            case .moveMotor, .resetMotor, .reset: throw NexArmExecutionError.invalidArguments
                            }
                            try await workflow.performGesture(
                                gesture, repetitions: request.repetitions, speed: request.speed,
                                acceleration: request.acceleration, recordReport: record)
                        }
                    }),
                ScheduledFunctionFixture(
                    NexArmBaseModule { cycles, invocation in
                        try await workflow.shakeBase(
                            cycles: cycles, recordReport: { try await invocation.results.record($0) })
                    }),
                NexArmAssistantUIModule(),
            ], toolModules: [])
        try assembly.actions.validate(capabilities: assistant.descriptor.capabilities)
        let scheduler = ChannelScheduler(
            registry: assembly.actions, capacityPerChannel: 4, maximumTrackedInputs: 2,
            resources: try nexArmTestResources()
        ) { await input.deliverActionResult($0) }
        let output = OutputGateway(
            manager: manager, requests: input, tools: assembly.tools, actions: scheduler, policy: policy,
            actionFeedback: .terminal, sink: { _ in })
        do {
            try await assistant.bind(output.messaging(for: .assistant))
            try await assistant.start()
            let report = try await input.send(
                AgentInput(sessionID: session, payload: .text("执行串口验收动作")), to: .assistant)
            try #require(report.rejected.isEmpty)
            for await envelope in fixtureOutputs(assistant) {
                try await output.dispatch(envelope)
                if envelope.output == .control("agent.finished") { break }
                if case .control(let token) = envelope.output, token.hasPrefix("assistant.error") {
                    throw NexArmExecutionError.invalidArguments
                }
            }
            let records = await output.executionResults(source: .assistant).actions.records.filter {
                $0.path.domain == "NexArm"
            }
            try #require(!records.isEmpty)
            for record in records {
                print(
                    "SERIAL AGENT RESULT path=\(record.path) phase=\(record.phase) failure=\(String(describing: record.failure)) description=\(record.failureDescription ?? "")"
                )
                try #require(record.phase == expected)
                if expected == .failed { try #require(record.failureDescription != nil) }
            }
            await output.shutdown()
            await assistant.stop()
        } catch {
            await output.shutdown()
            await assistant.stop()
            throw error
        }
    }

    @Test(
        .actionCatalog,
        .enabled(if: ProcessInfo.processInfo.environment["NEXARM_SERIAL_TRACKING_ACCEPTANCE"] == "1"),
        .timeLimit(.minutes(3)))
    @MainActor
    func nexArmSerialSettingsTakeoverAndPhotographerToolAcceptance() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["NEXARM_PORT"])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("serial-tracking-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let link = SerialSettingsLink(path: path)
        let workflow = BluetoothWorkflow(
            state: BluetoothSettingsState(), link: link,
            makeStore: { try LocalDocumentStore<BluetoothDeviceRecord>(url: file, maximumBytes: 4096) })
        let observer = Task { await workflow.run() }
        let resources = try ResourceCoordinator(
            definitions: (1...6).map {
                ResourceDefinition(
                    id: ResourceID(rawValue: "nexarm.motor.\($0)"), allowedOwners: [.assistant, .photographer]
                ) {}
            })
        let manager = AgentManager()
        let session = UUID()
        let photographer = try PhotographerAgent(
            sessionID: session, controlsArm: true, controlAvailable: { await workflow.trackingAvailable })
        try await manager.register(photographer, sessionID: session)
        let policy = try CommunicationPolicy(
            contracts: AgentContracts.communication,
            externalSources: ["user", "runtime", "phone.camera", "phone.microphone"],
            configurations: AgentConfigurations.all())
        let input = InputGateway(manager: manager, policy: policy, allowsExternalSend: true)
        let failures = SerialControlFailureProbe()
        let tools = try ToolRegistry(modules: [
            NexArmTrackingModule { base, pitch, invocation in
                try await workflow.aim(
                    base: base, pitch: pitch,
                    origin: .init(
                        source: invocation.context.source, sessionID: invocation.context.sessionID,
                        inputID: invocation.context.inputID, callID: invocation.executionID),
                    failed: { await failures.record($0) })
            }
        ])
        let output = OutputGateway(
            manager: manager, requests: input, tools: tools,
            actions: ChannelScheduler(registry: ActionRegistry(), resources: resources), policy: policy, sink: { _ in })
        do {
            workflow.openPage()
            try await serialWait("discovery") { !workflow.state.nearby.isEmpty }
            workflow.connect(link.id)
            await workflow.waitUntilIdle()
            try await serialWait(seconds: 5, "passive feedback") { workflow.state.joints.count == 6 }
            // Tracking setup explicitly selects its own rest; ordinary reset keeps the legacy home.
            for (index, target) in NexArmJointCommand.armHome.enumerated() {
                try await serialAssistant(
                    "<moveMotor motor=\"\(index + 1)\" target=\"\(target)\" speed=\"400\" acceleration=\"30\"/>",
                    workflow: workflow, expected: .succeeded)
            }
            workflow.withMotorResources = bluetoothResourceGuard(resources)
            try await photographer.start()
            var iterator = photographer.outputs.makeAsyncIterator()
            let baseline = workflow.state.joints
            let before = await link.writes
            for index in 1...6 {
                let sequence = UInt64(index)
                let pose = try PoseObservation(
                    width: 100, height: 100, sequence: sequence, timestamp: Double(index) * 0.25, rotation: 1,
                    people: [Array(repeating: .init(x: 35, y: 50, confidence: 0.9), count: 17)])
                let payload = InputPayload.observation(.pose(pose))
                let delivery = try await input.send(
                    AgentInput(
                        sessionID: session, payload: payload,
                        metadata: InputMetadata(payload: payload, source: "runtime", sequence: sequence)),
                    to: .photographer)
                try #require(delivery.rejected.isEmpty)
                let envelope = try #require(await iterator.next())
                print("SERIAL PHOTOGRAPHER TOOL \(envelope.output)")
                let result = try await output.execute(envelope)
                try #require(!result.isError)
                try await Task.sleep(for: .milliseconds(250))
            }
            await workflow.waitUntilIdle()
            try await Task.sleep(for: .milliseconds(400))
            try #require(await link.writes > before)
            try #require(baseline[0] - workflow.state.joints[0] >= 30)
            try #require(abs(baseline[4] - workflow.state.joints[4]) <= 4)
            try #require(abs(baseline[5] - workflow.state.joints[5]) <= 4)
            let results = await output.executionResults(source: .photographer)
            try #require(results.outputs.count == 6 && results.outputs.allSatisfy { !$0.isError })
            try #require(await failures.failure == nil)
            print(
                "SERIAL TOOL PASS writes=\(await link.writes - before) start=\(baseline) actual=\(workflow.state.joints)"
            )

            if ProcessInfo.processInfo.environment["NEXARM_SERIAL_AIM_STRESS"] == "1" {
                // Explicit Tool fixtures isolate publication rate from YOLO/Photographer policy.
                // Centered observations still cross InputGateway and keep the real freshness guard active.
                let permission = InternalTool(path: "NexArm.Tracking.aim", required: ["base", "pitch"])
                var sequence: UInt64 = 6
                for phase in 0..<3 {
                    let count = phase == 1 ? 300 : 30
                    let interval: Duration = phase == 1 ? .milliseconds(20) : .milliseconds(200)
                    let before = await link.writes
                    let started = ContinuousClock.now
                    print("SERIAL STRESS BEGIN phase=\(phase) calls=\(count) interval=\(interval)")
                    for index in 0..<count {
                        sequence += 1
                        let pose = try PoseObservation(
                            width: 100, height: 100, sequence: sequence,
                            timestamp: Double(sequence), rotation: 1,
                            people: [Array(repeating: .init(x: 50, y: 50, confidence: 0.9), count: 17)])
                        let payload = InputPayload.observation(.pose(pose))
                        let observation = AgentInput(
                            sessionID: session, payload: payload,
                            metadata: InputMetadata(payload: payload, source: "runtime", sequence: sequence))
                        let delivery = try await input.send(observation, to: .photographer)
                        try #require(delivery.rejected.isEmpty)
                        let base: Double
                        switch phase {
                        case 0: base = -0.08 + 0.16 * Double(index) / Double(count - 1)
                        case 1: base = 0.08
                        default: base = 0.08 + (index.isMultiple(of: 2) ? -0.01 : 0.01)
                        }
                        let call = try permission.call(["base": String(base), "pitch": "0"])
                        let envelope = OutputEnvelope(
                            source: .photographer, input: observation, output: .toolCall(call), sequence: sequence)
                        let result = try await output.execute(envelope)
                        try #require(!result.isError)
                        try #require(await failures.failure == nil)
                        try await Task.sleep(for: interval)
                    }
                    print(
                        "SERIAL STRESS END phase=\(phase) calls=\(count) writes=\(await link.writes - before) elapsed=\(ContinuousClock.now - started) joints=\(workflow.state.joints)"
                    )
                }
            } else {
                // Hold an Agent-side lease with no motion; manual controls must bypass it.
                let owner = ExecutionOwner(agent: .assistant, incarnation: UUID(), sessionID: session)
                let lease = try await resources.acquire(
                    resources: [ResourceID(rawValue: "nexarm.motor.5")], owner: owner, duration: .seconds(30),
                    revoke: { _ in })
                let manualStart = await link.writes
                workflow.tryAction(.shakeHead)
                try await serialWait("first manual packet") { await link.writes > manualStart }
                try await Task.sleep(for: .milliseconds(250))
                workflow.setMotorVelocity(id: 5, value: -0.5)
                try await Task.sleep(for: .milliseconds(350))
                workflow.setMotorVelocity(id: 5, value: 0)
                await workflow.waitUntilIdle()
                let finished = await link.writes
                try await Task.sleep(for: .milliseconds(600))
                try #require(await link.writes == finished)
                try #require(workflow.state.phase == .connected && workflow.state.transportIssue == nil)
                try await resources.release(lease, owner: owner)
                print("SERIAL TAKEOVER PASS manual bypassed Agent lease; no old preset replay")
            }

            await output.shutdown()
            await photographer.stop()
            workflow.disconnect()
            await workflow.waitUntilIdle()
            observer.cancel()
            await observer.value
        } catch {
            print("SERIAL TRACKING STOP error=\(error) joints=\(workflow.state.joints)")
            workflow.stopMotorControl()
            await workflow.stopActions()
            await output.shutdown()
            await photographer.stop()
            workflow.disconnect()
            await workflow.waitUntilIdle()
            observer.cancel()
            await observer.value
            throw error
        }
    }

    @Test(
        .actionCatalog, .enabled(if: ProcessInfo.processInfo.environment["NEXARM_SERIAL_ACCEPTANCE"] == "1"),
        .timeLimit(.minutes(3)))
    @MainActor
    func nexArmSerialSettingsAndAgentAcceptance() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["NEXARM_PORT"])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("serial-acceptance-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let link = SerialSettingsLink(path: path)
        let workflow = BluetoothWorkflow(
            state: BluetoothSettingsState(), link: link,
            makeStore: { try LocalDocumentStore<BluetoothDeviceRecord>(url: file, maximumBytes: 4096) })
        let observer = Task { await workflow.run() }
        do {
            workflow.openPage()
            try await serialWait("discovery") { !workflow.state.nearby.isEmpty }
            let row = try #require(workflow.state.nearby.first)
            workflow.connect(row.id)
            await workflow.waitUntilIdle()
            try #require(workflow.state.isConnected(link.id))
            try await serialWait(seconds: 5, "real passive feedback") { workflow.state.joints.count == 6 }
            let initial = workflow.state.joints
            print("SERIAL APP CONNECTED joints=\(initial)")

            // Small supervised single-motor motion first; actual terminal feedback is required.
            let target = initial[4] + (initial[4] < 3000 ? 80 : -80)
            try await serialAssistant(
                "<moveMotor motor=\"5\" target=\"\(target)\" speed=\"400\" acceleration=\"30\"/>",
                workflow: workflow, expected: .succeeded)
            try #require(abs(workflow.state.joints[4] - target) <= 16)
            try #require(abs(workflow.state.joints[4] - initial[4]) >= 40)
            try await serialAssistant(
                "<moveMotor motor=\"5\" target=\"\(initial[4])\" speed=\"400\" acceleration=\"30\"/>",
                workflow: workflow, expected: .succeeded)

            for action in [BluetoothArmAction.nod, .shakeHead] {
                let before = await link.writes
                let home = workflow.state.joints
                let began = ContinuousClock.now
                workflow.tryAction(action)
                try #require(ContinuousClock.now - began < .milliseconds(100))
                await workflow.waitUntilIdle()
                try #require(await link.writes >= before + 6)
                try #require(workflow.state.phase == .connected)
                let motor = action == .nod ? 4 : 5
                try #require(abs(workflow.state.joints[motor - 1] - home[motor - 1]) <= 32)
                print("SERIAL SETTINGS PASS action=\(action) writes=\(await link.writes - before)")
            }

            let jogStart = workflow.state.joints
            let beforeJog = await link.writes
            workflow.setMotorVelocity(id: 5, value: 0.6)
            try await Task.sleep(for: .milliseconds(450))
            workflow.setMotorVelocity(id: 5, value: 0)
            await workflow.waitUntilIdle()
            try await Task.sleep(for: .milliseconds(500))
            try #require(await link.writes > beforeJog)
            try #require(workflow.state.joints[4] - jogStart[4] >= 30)
            let held = workflow.state.joints[4]
            try await Task.sleep(for: .milliseconds(400))
            try #require(abs(workflow.state.joints[4] - held) <= 4)
            print("SERIAL SETTINGS JOG PASS writes=\(await link.writes - beforeJog) start=\(jogStart[4]) held=\(held)")

            // Invalid arguments must fail through the actual scheduler without a native write.
            let beforeInvalid = await link.writes
            try await serialAssistant(
                "<moveMotor motor=\"5\" target=\"5000\"/>", workflow: workflow, expected: .failed)
            try #require(await link.writes == beforeInvalid)
            try #require(workflow.state.transportIssue == nil)

            workflow.disconnect()
            await workflow.waitUntilIdle()
            try #require(!workflow.state.canControl(link.id))
            let beforeOffline = await link.writes
            workflow.tryAction(.nod)
            workflow.setMotorVelocity(id: 5, value: 0.5)
            try await serialAssistant(
                "<moveMotor motor=\"5\" target=\"2048\"/>", workflow: workflow, expected: .failed)
            try #require(await link.writes == beforeOffline)
            print("SERIAL OFFLINE PASS disabled controls and failed Agent result")
            observer.cancel()
            await observer.value
        } catch {
            print(
                "SERIAL ACCEPTANCE STOP error=\(error) current=\(workflow.state.phase) joints=\(workflow.state.joints)")
            workflow.stopMotorControl()
            await workflow.stopActions()
            workflow.disconnect()
            await workflow.waitUntilIdle()
            observer.cancel()
            await observer.value
            throw error
        }
    }

    @Test(
        .actionCatalog,
        .enabled(if: ProcessInfo.processInfo.environment["NEXARM_SERIAL_PRESETS_ACCEPTANCE"] == "1"),
        .timeLimit(.minutes(5)))
    @MainActor
    func nexArmSerialAllSettingsAndAssistantPresetsAcceptance() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["NEXARM_PORT"])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("serial-presets-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let link = SerialSettingsLink(path: path)
        let workflow = BluetoothWorkflow(
            state: BluetoothSettingsState(), link: link,
            makeStore: { try LocalDocumentStore<BluetoothDeviceRecord>(url: file, maximumBytes: 4096) })
        let observer = Task { await workflow.run() }
        let presets: [(BluetoothArmAction, NexArmGesture, String)] = [
            (.nod, .nod, "<nodHead cycles=\"1\"/>"),
            (.shakeHead, .shakeHead, "<shakeHead cycles=\"1\"/>"),
            (.shakeBase, .baseSway, "<shakeBase cycles=\"1\"/>"),
            (.wave, .wave, "<waveWrist count=\"1\"/>"),
            (.tiltLeft, .tiltLeft, "<tiltWrist direction=\"left\"/>"),
            (.tiltRight, .tiltRight, "<tiltWrist direction=\"right\"/>"),
            (.lookAround, .lookAround, "<lookAround cycles=\"1\"/>"),
            (.celebrate, .celebrate, "<celebrate cycles=\"1\"/>"),
            (.dance, .dance, "<dance cycles=\"1\"/>"),
        ]
        do {
            workflow.openPage()
            try await serialWait("discovery") { !workflow.state.nearby.isEmpty }
            workflow.connect(link.id)
            await workflow.waitUntilIdle()
            try await serialWait(seconds: 5, "passive feedback") { workflow.state.joints.count == 6 }
            for (manual, gesture, markup) in presets {
                let before = await link.writes
                print("SERIAL FULL SETTINGS BEGIN \(manual)")
                workflow.tryAction(manual)
                await workflow.waitUntilIdle()
                try #require(await link.writes - before == gesture.settingsTestFrames().count)
                let targets = await link.targets
                try #require(!targets.isEmpty)
                try #require(
                    targets.allSatisfy { id, target in
                        abs(workflow.state.joints[id - 1] - target) <= NexArmMotorProfiles.profile(for: id).tolerance
                    })
                print("SERIAL FULL SETTINGS PASS \(manual) actual=\(workflow.state.joints)")
                print("SERIAL FULL ASSISTANT BEGIN \(gesture)")
                try await serialAssistant(markup, workflow: workflow, expected: .succeeded)
            }
            workflow.tryAction(.reset)
            await workflow.waitUntilIdle()
            try #require(
                zip(workflow.state.joints.prefix(5), NexArmGesture.referenceHomeJoints.prefix(5)).enumerated()
                    .allSatisfy {
                        index, pair in
                        abs(pair.0 - pair.1) <= NexArmMotorProfiles.profile(for: index + 1).tolerance
                    })
            print("SERIAL FULL SETTINGS RESET PASS actual=\(workflow.state.joints)")
            try await serialAssistant("<resetArm/>", workflow: workflow, expected: .succeeded)
            workflow.disconnect()
            await workflow.waitUntilIdle()
            observer.cancel()
            await observer.value
        } catch {
            print("SERIAL FULL PRESETS STOP error=\(error) joints=\(workflow.state.joints)")
            workflow.stopMotorControl()
            await workflow.stopActions()
            workflow.disconnect()
            await workflow.waitUntilIdle()
            observer.cancel()
            await observer.value
            throw error
        }
    }

    @Test(.actionCatalog, .enabled(if: ProcessInfo.processInfo.environment["NEXARM_SERIAL_PREFLIGHT"] == "1"))
    func nexArmSerialReadOnlyPreflight() async throws {
        let link = try NexArmSerial(path: #require(ProcessInfo.processInfo.environment["NEXARM_PORT"]))
        do {
            let controller = NexArmActionController(link: link)
            do {
                let compatibility = try await controller.verifyCompatibility()
                print("SERIAL PREFLIGHT compatibility=\(compatibility)")
            } catch {
                print("SERIAL PREFLIGHT version unavailable=\(error); checking read-only position separately")
            }
            let first = try await controller.readState()
            try await Task.sleep(for: .milliseconds(400))
            let second = try await controller.readState()
            print("SERIAL PREFLIGHT pose=\(second.pose) joints=\(second.joints)")
            try #require(zip(first.joints, second.joints).allSatisfy { abs($0 - $1) <= 3 })
            let session = try await link.beginObservation()
            await link.close()
            await #expect(throws: NexArmError.disconnected) {
                try await link.latestObservation(after: 0, session: session)
            }
            await #expect(throws: NexArmError.disconnected) {
                try await link.sendObserved(NexArmPacket(command: 11), session: session)
            }
            print("SERIAL PREFLIGHT closed-session errors=disconnected, not caller cancellation")
        } catch {
            await link.close()
            throw error
        }
    }
#endif

import Actions
import AgentCore
import Agents
import AppWorkflows
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import Testing

private actor CameraProbe {
    var operations: [PhotographerCameraIntent.Operation] = []
    var sources: [String] = []
    var facings: [String] = []
    var failFlip = true
    var held = false
    private var release: CheckedContinuation<Void, Never>?
    nonisolated let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    nonisolated let cancelled = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    func holdNext() { held = true }
    func finish() {
        release?.resume()
        release = nil
    }
    func perform(_ operation: PhotographerCameraIntent.Operation, source: String, facing: String?) async throws {
        operations.append(operation)
        sources.append(source)
        if let facing { facings.append(facing) }
        if held {
            held = false
            await withTaskCancellationHandler {
                await withCheckedContinuation {
                    release = $0
                    entered.continuation.yield(())
                }
            } onCancel: {
                self.cancelled.continuation.yield(())
            }
            try Task.checkCancellation()
        }
        if operation == .flip && failFlip {
            failFlip = false
            throw ActionReportedError(
                try ActionReport(entries: [
                    .init(path: "prepare", status: .succeeded),
                    .init(
                        path: "switch", status: .failed, code: .init(rawValue: "camera.unavailable"),
                        details: ["cause": "test device failure"]),
                ]).withExecutionFailure(.init(rawValue: "camera.unavailable"), description: "Lens switch failed"))
        }
    }
}
private actor CameraBridge: CameraControlCapability {
    let probe: CameraProbe
    private var runtime: PhotographerIntentRuntime?
    private var gateway: OutputGateway?
    init(probe: CameraProbe) { self.probe = probe }
    func bind(_ runtime: PhotographerIntentRuntime, gateway: OutputGateway) {
        self.runtime = runtime
        self.gateway = gateway
    }
    func setEnabled(_ enabled: Bool, invocation: any FunctionInput) async throws {
        try await perform(enabled ? .open : .close, invocation: invocation)
    }
    func retry(invocation: any FunctionInput) async throws { try await perform(.retry, invocation: invocation) }
    func flip(_ facing: CameraActions.Facing, invocation: any FunctionInput) async throws {
        try await perform(.flip, facing: facing, invocation: invocation)
    }
    private func perform(
        _ operation: PhotographerCameraIntent.Operation, facing: CameraActions.Facing? = nil,
        invocation: any FunctionInput
    ) async throws {
        if invocation.context.source == "assistant", let runtime, let gateway {
            do {
                try await runtime.perform(
                    operation, facing: facing.flatMap { PhotographerCameraIntent.Facing(rawValue: $0.rawValue) },
                    delegate: { message in
                        try await gateway.delegate(message, context: invocation.context, to: .photographer)
                    })
            } catch PhotographerIntentFailure.execution(let result) {
                if case .report(let report)? = result.tool?.completion { throw ActionReportedError(report) }
                throw PhotographerIntentFailure.execution(result)
            }
        } else {
            guard invocation.context.source == "photographer" else { throw CommunicationError.unauthorized }
            try await probe.perform(operation, source: invocation.context.source, facing: facing?.rawValue)
        }
    }
}
private struct CameraTools: ToolModule { let definitions: [ActionBinding] }
private actor CameraCaller: Agent {
    nonisolated let descriptor: AgentDescriptor
    nonisolated let outputs = AsyncStream<OutputEnvelope> { $0.finish() }
    init() throws {
        descriptor = AgentDescriptor(
            id: .assistant, name: "Assistant fixture", inputs: [], outputs: [.toolCall],
            capabilities: try AgentConfigurations.load(named: "Assistant").capabilities)
    }
    func start() {}
    func pause() {}
    func resume() {}
    func stop() {}
    func receive(_ input: AgentInput) {}
    func status() -> AgentStatus { .init(lifecycle: .running, queuedInputs: 0, processedInputs: 0) }
}
private struct CameraFixture {
    let runtime: PhotographerIntentRuntime
    let probe: CameraProbe
    let gateway: OutputGateway
    let manager: AgentManager
    let root: UUID
    init() async throws {
        root = UUID()
        manager = AgentManager()
        let policy = try CommunicationPolicy(
            contracts: AgentContracts.communication,
            externalSources: ["user", "runtime", "phone.microphone", "phone.camera"],
            configurations: ["Assistant", "SpeechPerception", "SpeechSynthesis", "VisionPerception", "Photographer"].map
            {
                try AgentConfigurations.load(named: $0)
            })
        let input = InputGateway(manager: manager, policy: policy)
        probe = CameraProbe()
        let bridge = CameraBridge(probe: probe)
        let tools = try ToolRegistry(modules: [
            CameraTools(
                definitions: CameraModule(camera: bridge).definitions.map {
                    ActionBinding(
                        function: $0, protocols: [.tool], executionPolicy: .direct, directResultPolicy: .returning)
                })
        ])
        gateway = OutputGateway(
            manager: manager, requests: input, tools: tools,
            actions: ChannelScheduler(registry: ActionRegistry()), policy: policy, sink: { _ in })
        runtime = PhotographerIntentRuntime(
            sessionID: root, manager: manager, input: input, output: gateway,
            agent: try PhotographerAgent(sessionID: root))
        await bridge.bind(runtime, gateway: gateway)
    }
}
@Test(.timeLimit(.minutes(1))) func photographerCameraUsesSharedFunctionsAndRetainsFailuresBeforeRecovering()
    async throws
{
    let f = try await CameraFixture()
    try await f.runtime.perform(.open)
    await #expect(throws: PhotographerIntentFailure.self) { try await f.runtime.perform(.flip, facing: .back) }
    let feedback = try #require(await f.runtime.agent.cameraResult())
    #expect(feedback.isError)
    #expect(feedback.failureCode == "camera.unavailable")
    guard case .report(let report)? = feedback.completion else {
        Issue.record("Missing full report")
        return
    }
    #expect(report.entries.map(\.path) == ["prepare", "switch"])
    #expect(report.entries.last?.details["cause"] == "test device failure")
    try await f.runtime.perform(.flip, facing: .front)
    try await f.runtime.perform(.retry)
    try await f.runtime.perform(.close)
    #expect(await f.probe.operations == [.open, .flip, .flip, .retry, .close])
    #expect(await f.probe.facings == ["back", "front"])
    #expect(await f.probe.sources.allSatisfy { $0 == "photographer" })
    await f.runtime.shutdown()
}
@Test(.timeLimit(.minutes(1))) func photographerCameraCancellationJoinsBeforeRetryAndRejectsOverlap() async throws {
    let f = try await CameraFixture()
    await f.probe.holdNext()
    var entered = f.probe.entered.stream.makeAsyncIterator()
    let opening = Task { try await f.runtime.perform(.open) }
    await entered.next()
    await #expect(throws: CommunicationError.capacityExceeded) { try await f.runtime.perform(.close) }
    var cancelled = f.probe.cancelled.stream.makeAsyncIterator()
    opening.cancel()
    await cancelled.next()
    await #expect(throws: CommunicationError.capacityExceeded) { try await f.runtime.perform(.retry) }
    await f.probe.finish()
    await #expect(throws: CancellationError.self) { try await opening.value }
    try await f.runtime.perform(.retry)
    await f.runtime.shutdown()
}
@Test(.timeLimit(.minutes(1))) func photographerSurvivesVisionDetachAndRejectsRetiredPoseScopes() async throws {
    let f = try await CameraFixture()
    let vision = UUID()
    try await f.runtime.attachTracking(sessionID: vision)
    await f.runtime.detachTracking(sessionID: vision)
    #expect(await f.runtime.agent.status().lifecycle == .running)
    let pose = try PoseObservation(width: 100, height: 100, sequence: 1, timestamp: 1, rotation: 1, people: [])
    let payload = InputPayload.observation(.pose(pose))
    await #expect(throws: CommunicationError.unauthorized) {
        try await f.runtime.agent.receive(AgentInput(sessionID: vision, payload: payload))
    }
    try await f.runtime.perform(.close)
    try await f.runtime.perform(.open)
    await f.runtime.shutdown()
}
@Test(.timeLimit(.minutes(1))) func boundAssistantCameraDelegationUsesPhotographerAndReturnsCompleteNativeFailure()
    async throws
{
    let f = try await CameraFixture()
    let voice = UUID()
    try await f.manager.register(CameraCaller(), sessionID: voice)
    try await f.manager.start(.assistant)
    let parent = AgentInput(sessionID: voice, payload: .text("switch camera"))
    let context = ActionExecutionContext(source: "assistant", sessionID: voice, inputID: parent.id)
    await #expect(throws: CommunicationError.unauthorized) {
        try await f.gateway.delegate(PhotographerCameraIntent(.open).message, context: context, to: .photographer)
    }
    let result = try await f.gateway.execute(
        OutputEnvelope(
            source: .assistant, input: parent,
            output: .toolCall(ToolCall(toolPath: "Camera.Capture.flip", arguments: ["facing": "back"]))))
    #expect(result.isError)
    #expect(result.tool?.failureCode?.rawValue == "camera.unavailable")
    #expect(await f.probe.facings == ["back"])
    guard case .report(let report)? = result.tool?.completion else {
        Issue.record("Missing delegated failure report")
        return
    }
    #expect(report.entries.map(\.path) == ["prepare", "switch"])
    #expect(report.entries.last?.details["cause"] == "test device failure")
    let recovery = try await f.gateway.execute(
        OutputEnvelope(
            source: .assistant, input: parent,
            output: .toolCall(ToolCall(toolPath: "Camera.Capture.open", arguments: [:]))))
    #expect(!recovery.isError)
    #expect(await f.probe.sources == ["photographer", "photographer"])
    await f.runtime.shutdown()
    try await f.manager.remove(.assistant)
}

@Test func photographerCameraRejectsForeignScopeAndFeedbackWithoutLosingPendingWork() async throws {
    let root = UUID()
    let agent = try PhotographerAgent(sessionID: root)
    try await agent.start()
    await #expect(throws: CommunicationError.unauthorized) {
        try await agent.receive(PhotographerCameraIntent(.open).input(sessionID: UUID()))
    }
    let request = PhotographerCameraIntent(.open)
    try await agent.receive(request.input(sessionID: root))
    var reader = agent.outputs.makeAsyncIterator()
    let envelope = try #require(await reader.next())
    let result = InputPayload.toolResult(ToolResult(callID: request.requestID, value: "completed"))
    await #expect(throws: CommunicationError.invalidPayload) {
        try await agent.receive(
            AgentInput(
                sessionID: root, payload: result,
                metadata: InputMetadata(payload: result, source: "user", origin: .external)))
    }
    await #expect(throws: CommunicationError.invalidPayload) {
        try await agent.receive(AgentInput(sessionID: UUID(), payload: result))
    }
    await #expect(throws: CommunicationError.capacityExceeded) {
        try await agent.receive(PhotographerCameraIntent(.close).input(sessionID: root))
    }
    try await agent.receive(
        AgentInput(
            sessionID: root, payload: result,
            metadata: InputMetadata(payload: result, source: "runtime", origin: .runtime)))
    let terminal = try #require(await reader.next())
    #expect(terminal.inputID == envelope.inputID)
    #expect(terminal.output.kind == .control)
    await #expect(throws: CommunicationError.invalidPayload) {
        try await agent.receive(
            AgentInput(
                sessionID: root, payload: result,
                metadata: InputMetadata(payload: result, source: "runtime", origin: .runtime)))
    }
    try await agent.receive(PhotographerCameraIntent(.close).input(sessionID: root))
    #expect(await agent.status().lifecycle == .running)
    await agent.stop()
}

@Test func photographerCameraFacingIsRequiredOnlyForFlip() throws {
    for facing in [PhotographerCameraIntent.Facing.front, .back] {
        _ = try PhotographerCameraIntent(.flip, facing: facing).message.validatedSize()
        #expect(throws: CommunicationError.invalidPayload) {
            try PhotographerCameraIntent(.open, facing: facing).message.validatedSize()
        }
    }
    #expect(throws: CommunicationError.invalidPayload) {
        try PhotographerCameraIntent(.flip).message.validatedSize()
    }
}

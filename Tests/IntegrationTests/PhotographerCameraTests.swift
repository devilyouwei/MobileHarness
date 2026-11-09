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
import UI

@testable import Agents

private actor CameraProbe {
    var operations: [PhotographerCameraIntent.Operation] = []
    var sources: [String] = []
    var facings: [String] = []
    var failFlip = true
    var held = false
    let previewID = "preview_1"
    var photoVisible = true
    var exports = 0
    var failSave = false
    func denyNextSave() { failSave = true }
    func photo(_ operation: PhotographerCameraIntent.Operation, id: String?, source: String) throws
        -> CameraPhotoCommandReceipt
    {
        guard photoVisible, id == nil || id == previewID else { throw CameraControlError.photoUnavailable }
        operations.append(operation)
        sources.append(source)
        if failSave {
            failSave = false
            throw CameraControlError.permissionDenied
        }
        let already = exports > 0
        if !already { exports += 1 }
        return .init(previewID: previewID, state: .saved, alreadySaved: already)
    }
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
    init(probe: CameraProbe) { self.probe = probe }
    func configureCapture(_ settings: CameraCaptureSettings.Update, invocation: any FunctionInput) async throws {
        try await perform(.configure, invocation: invocation)
    }
    func cancelCapture(invocation: any FunctionInput) async throws {
        try await perform(.cancelCapture, invocation: invocation)
    }
    func startRecording(durationSeconds: Int?, invocation: any FunctionInput) async throws -> CameraVideoReceipt {
        try await perform(.startRecording, invocation: invocation)
        return .init(recordingID: "11111111-2222-4333-8444-555555555555", state: "recording")
    }
    func stopRecording(_ id: String, invocation: any FunctionInput) async throws -> CameraVideoReceipt {
        try await perform(.stopRecording, invocation: invocation)
        return .init(recordingID: id, state: "ready")
    }
    func saveVideo(_ id: String, invocation: any FunctionInput) async throws -> CameraVideoReceipt {
        try await perform(.saveVideo, invocation: invocation)
        return .init(recordingID: id, state: "saved")
    }
    func ignoreVideo(_ id: String, invocation: any FunctionInput) async throws -> CameraVideoReceipt {
        try await perform(.ignoreVideo, invocation: invocation)
        return .init(recordingID: id, state: "ignored")
    }
    func savePhoto(_ id: String?, invocation: any FunctionInput) async throws -> CameraPhotoCommandReceipt {
        try await photo(.savePhoto, id: id, invocation: invocation)
    }
    private func photo(_ operation: PhotographerCameraIntent.Operation, id: String?, invocation: any FunctionInput)
        async throws -> CameraPhotoCommandReceipt
    {
        guard invocation.context.source == "photographer" else { throw CommunicationError.unauthorized }
        return try await probe.photo(operation, id: id, source: invocation.context.source)
    }
    func setEnabled(_ enabled: Bool, invocation: any FunctionInput) async throws {
        try await perform(enabled ? .open : .close, invocation: invocation)
    }
    func setPerceptionEnabled(_ enabled: Bool, invocation: any FunctionInput) async throws {
        try await perform(enabled ? .perceptionOpen : .perceptionClose, invocation: invocation)
    }
    func flipPerception(_ facing: CameraActions.Facing, invocation: any FunctionInput) async throws {
        try await perform(.perceptionFlip, facing: facing, invocation: invocation)
    }
    func retry(invocation: any FunctionInput) async throws { try await perform(.retry, invocation: invocation) }
    func flip(_ facing: CameraActions.Facing, invocation: any FunctionInput) async throws {
        try await perform(.flip, facing: facing, invocation: invocation)
    }
    private func perform(
        _ operation: PhotographerCameraIntent.Operation, facing: CameraActions.Facing? = nil,
        invocation: any FunctionInput
    ) async throws {
        guard invocation.context.source == "photographer" else { throw CommunicationError.unauthorized }
        try await probe.perform(operation, source: invocation.context.source, facing: facing?.rawValue)
    }
}
private struct CameraTools: ToolModule { let definitions: [ActionBinding] }
private actor CameraCaller: Agent {
    nonisolated let descriptor: AgentDescriptor
    nonisolated let outputs = AsyncStream<OutputEnvelope> { $0.finish() }
    init() throws {
        descriptor = AgentDescriptor(
            id: .assistant, name: "Assistant fixture", inputs: [], outputs: [.toolCall, .actionCall, .control],
            capabilities: try AgentSkillLoader.registry(
                ["photography"], fixed: AgentConfigurations.load(named: "Assistant").capabilities))
    }
    func start() {}
    func pause() {}
    func resume() {}
    func stop() {}
    func receive(_ input: AgentInput) {}
    func status() -> AgentStatus { .init(lifecycle: .running, queuedInputs: 0, processedInputs: 0) }
}
private struct CameraFixture {
    let runtime: CameraTestRuntime
    let probe: CameraProbe
    let gateway: OutputGateway
    let manager: AgentManager
    let root: String
    @MainActor init(uiCamera: UICameraContainer? = nil) async throws {
        let ui = UIContainer()
        try ui.start()
        let cameraUI = uiCamera ?? ui.camera
        root = UUID().uuidString
        manager = AgentManager()
        let policy = try CommunicationPolicy(
            contracts: AgentContracts.communication,
            configurations: AgentConfigurations.all())
        let input = InputGateway(manager: manager, policy: policy)
        probe = CameraProbe()
        let bridge = CameraBridge(probe: probe)
        let bindings = CameraModule(camera: bridge).definitions.map {
            ActionBinding(
                function: $0,
                protocols: ["savePhoto"].contains($0.path.function) ? [.action, .tool] : [.tool],
                executionPolicy: .direct, directResultPolicy: .returning)
        }
        let tools = try ToolRegistry(modules: [CameraTools(definitions: bindings)])
        let actions = try ActionRegistry(definitions: bindings.filter { $0.protocols.contains(.action) })
        gateway = await OutputGateway(
            manager: manager, requests: input, tools: tools,
            actions: ChannelScheduler(registry: actions), policy: policy, sink: { _ in })
        let host = PhotographerExecutionSession(
            manager: manager, output: gateway,
            agent: try PhotographerAgent(
                sessionID: root, uiCamera: cameraUI,
                context: try AgentContextRepository(
                    agent: AgentID(rawValue: "photographer"), scope: UUID().uuidString,
                    state: PhotographerContextState())
            ))
        runtime = CameraTestRuntime(host: host, ui: ui, camera: cameraUI)
    }
}
@Test(.actionCatalog, .timeLimit(.minutes(1)))
func photographerCameraUsesSharedFunctionsAndRetainsFailuresBeforeRecovering()
    async throws
{
    let f = try await CameraFixture()
    try await f.runtime.perform(.open)
    let opened = try #require(await f.runtime.agent.cameraResult())
    #expect(opened.completion == .completed && !opened.isError)
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
    let flipped = try #require(await f.runtime.agent.cameraResult())
    #expect(
        try JSONDecoder().decode(CameraCommandReceipt.self, from: Data(flipped.value.utf8))
            == CameraCommandReceipt(operation: "flip", facing: .front))
    try await f.runtime.perform(.retry)
    try await f.runtime.perform(.close)
    #expect(await f.probe.operations == [.open, .flip, .flip, .retry, .close])
    #expect(await f.probe.facings == ["back", "front"])
    #expect(await f.probe.sources.allSatisfy { $0 == "photographer" })
    await f.runtime.shutdown()
}
@Test(.actionCatalog, .timeLimit(.minutes(1))) func photographerCameraCancellationJoinsBeforeQueuedRetry()
    async throws
{
    let f = try await CameraFixture()
    await f.probe.holdNext()
    var entered = f.probe.entered.stream.makeAsyncIterator()
    let opening = Task { try await f.runtime.perform(.open) }
    await entered.next()
    let closing = Task { try await f.runtime.perform(.close) }
    closing.cancel()
    var cancelled = f.probe.cancelled.stream.makeAsyncIterator()
    opening.cancel()
    await cancelled.next()
    let retry = Task { try await f.runtime.perform(.retry) }
    await f.probe.finish()
    await #expect(throws: CancellationError.self) { try await opening.value }
    await #expect(throws: CancellationError.self) { try await closing.value }
    _ = try await retry.value
    await f.runtime.shutdown()
}
@Test(.actionCatalog, .timeLimit(.minutes(1))) func photographerSurvivesVisionDetachAndRejectsRetiredPoseScopes()
    async throws
{
    let f = try await CameraFixture()
    let vision = UUID().uuidString
    try await f.runtime.attachTracking(sessionID: vision)
    await f.runtime.detachTracking(sessionID: vision)
    #expect(await f.runtime.agent.status().lifecycle == .running)
    let pose = try PoseObservation(width: 100, height: 100, sequence: 1, timestamp: 1, rotation: 1, people: [])
    let payload = InputPayload.observation(.pose(pose))
    await #expect(throws: CommunicationError.unauthorized) {
        try await f.runtime.agent.receive(
            AgentInput(id: UUID().uuidString, sessionID: vision, payload: payload))
    }
    try await f.runtime.perform(.close)
    try await f.runtime.perform(.open)
    await f.runtime.shutdown()
}
@Test(.actionCatalog) func assistantCannotExecutePhotographyFunctions() async throws {
    let f = try await CameraFixture()
    try await f.manager.register(CameraCaller())
    try await f.manager.start(.assistant)
    let parent = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("switch camera"))
    let result = try await f.gateway.execute(
        OutputEnvelope(
            source: .assistant, context: parent.context,
            output: .toolCall(
                ToolCall(
                    id: UUID().uuidString, toolPath: "Camera.Capture.flip", arguments: ["facing": "back"])),
            taskScope: parent.taskScope))
    #expect(result.isError)
    #expect(await f.probe.operations.isEmpty)
    try await f.manager.remove(.assistant)
    await f.runtime.shutdown()
}

@Test(.actionCatalog) func photographerCameraRejectsForeignScopeAndFeedbackWithoutLosingPendingWork() async throws {
    let root = UUID().uuidString
    let agent = try PhotographerAgent(
        sessionID: root,
        context: try AgentContextRepository(
            agent: AgentID(rawValue: "photographer"), scope: UUID().uuidString, state: PhotographerContextState())
    )
    try await agent.start()
    await #expect(throws: CommunicationError.unauthorized) {
        try await agent.receive(
            PhotographerCameraIntent(.open, requestID: UUID().uuidString).input(
                sessionID: UUID().uuidString))
    }
    let request = PhotographerCameraIntent(.open, requestID: UUID().uuidString)
    try await agent.receive(request.input(sessionID: root))
    var reader = agent.outputs.makeAsyncIterator()
    let envelope = try #require(await reader.next())
    let result = InputPayload.toolResult(ToolResult(callID: request.requestID, value: "completed"))
    await #expect(throws: CommunicationError.invalidPayload) {
        try await agent.receive(
            AgentInput(
                id: UUID().uuidString,
                sessionID: root, payload: result,
                metadata: InputMetadata(
                    payload: result, source: "user", origin: .local, rootID: UUID().uuidString)))
    }
    await #expect(throws: CommunicationError.invalidPayload) {
        try await agent.receive(
            AgentInput(id: UUID().uuidString, sessionID: UUID().uuidString, payload: result))
    }
    await #expect(throws: CommunicationError.capacityExceeded) {
        try await agent.receive(
            PhotographerCameraIntent(.close, requestID: UUID().uuidString).input(sessionID: root))
    }
    try await agent.receive(
        AgentInput(
            id: UUID().uuidString,
            sessionID: root, payload: result,
            metadata: InputMetadata(
                payload: result, source: "runtime", origin: .runtime, rootID: UUID().uuidString)))
    let terminal = try #require(await reader.next())
    #expect(terminal.inputID == envelope.inputID)
    #expect(terminal.output.kind == .control)
    await #expect(throws: CommunicationError.invalidPayload) {
        try await agent.receive(
            AgentInput(
                id: UUID().uuidString,
                sessionID: root, payload: result,
                metadata: InputMetadata(
                    payload: result, source: "runtime", origin: .runtime, rootID: UUID().uuidString)))
    }
    try await agent.receive(
        PhotographerCameraIntent(.close, requestID: UUID().uuidString).input(sessionID: root))
    #expect(await agent.status().lifecycle == .running)
    await agent.stop()
}

@Test(.actionCatalog) func photographerCameraFacingIsRequiredOnlyForFlip() throws {
    for facing in [PhotographerCameraIntent.Facing.front, .back] {
        _ = try PhotographerCameraIntent(.flip, facing: facing, requestID: UUID().uuidString).message
            .validatedSize()
        #expect(throws: CommunicationError.invalidPayload) {
            try PhotographerCameraIntent(.open, facing: facing, requestID: UUID().uuidString).message
                .validatedSize()
        }
    }
    #expect(throws: CommunicationError.invalidPayload) {
        try PhotographerCameraIntent(.flip, requestID: UUID().uuidString).message.validatedSize()
    }
}

@Test(.actionCatalog) func photoButtonsRouteExactIdentityAndRetainFailureBeforeRetry() async throws {
    let fixture = try await CameraFixture()
    let id = await fixture.probe.previewID
    await fixture.probe.denyNextSave()
    await #expect(throws: PhotographerIntentFailure.self) {
        try await fixture.runtime.perform(.savePhoto, previewID: id)
    }
    let raw = try #require(try await fixture.runtime.perform(.savePhoto, previewID: id))
    let saved = try JSONDecoder().decode(CameraPhotoCommandReceipt.self, from: Data(raw.utf8))
    #expect(saved == .init(previewID: id, state: .saved))
    let repeated = try #require(try await fixture.runtime.perform(.savePhoto, previewID: id))
    #expect(try JSONDecoder().decode(CameraPhotoCommandReceipt.self, from: Data(repeated.utf8)).alreadySaved)
    #expect(await fixture.probe.exports == 1)
    await #expect(throws: PhotographerIntentFailure.self) {
        try await fixture.runtime.perform(.savePhoto, previewID: UUID().uuidString)
    }
    #expect(await fixture.probe.photoVisible)
    await #expect(throws: PhotographerIntentFailure.self) { try await fixture.runtime.perform(.savePhoto) }
    try await fixture.runtime.perform(.open)
    #expect(await fixture.probe.sources.allSatisfy { $0 == "photographer" })
    await fixture.runtime.shutdown()
}

@Test(.actionCatalog) func photographerActionsReturnActualDisposition() async throws {
    let fixture = try await CameraFixture()
    try await fixture.runtime.prepareForInteraction()
    let caller = fixture.runtime.agent
    let capabilities = caller.descriptor.capabilities
    for (alias, state) in [("savePhoto", CameraPhotoCommandReceipt.State.saved)] {
        let input = AgentInput(
            id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text(alias))
        let call = try capabilities.resolveAction(
            alias, parameters: ["previewID": await fixture.probe.previewID])
        let result = try await fixture.gateway.execute(
            OutputEnvelope(
                source: .photographer, context: input.context, output: .actionCall(call), sequence: 1,
                taskScope: input.taskScope))
        #expect(result.isError == false)
        _ = try await fixture.gateway.execute(
            OutputEnvelope(
                source: .photographer, context: input.context, output: .control("agent.finished"), sequence: 2,
                taskScope: input.taskScope))
        let snapshot = await fixture.gateway.executionResults(inputID: input.id)
        let record = try #require(snapshot.actions.records.first)
        guard case .value(let raw)? = record.completion else {
            Issue.record(
                "Missing actual photo receipt: \(String(describing: record.completion)) \(record.failureDescription ?? "")"
            )
            continue
        }
        #expect(try JSONDecoder().decode(CameraPhotoCommandReceipt.self, from: Data(raw.utf8)).state == state)
    }
    #expect(await fixture.probe.exports == 1)
    #expect(await fixture.probe.photoVisible)
    await fixture.runtime.shutdown()
}

@Test(.actionCatalog) func malformedPhotoCommandsCannotReachNativeEffect() async throws {
    let fixture = try await CameraFixture()
    try await fixture.runtime.prepareForInteraction()
    let caller = fixture.runtime.agent
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .text("invalid photo"))
    let call = try caller.descriptor.capabilities.resolveAction("savePhoto", parameters: ["previewID": "invalid"])
    let result = try await fixture.gateway.execute(
        OutputEnvelope(
            source: .photographer, context: input.context, output: .actionCall(call), sequence: 1,
            taskScope: input.taskScope))
    #expect(result.isError == true)
    _ = try await fixture.gateway.execute(
        OutputEnvelope(
            source: .photographer, context: input.context, output: .control("agent.finished"), sequence: 2,
            taskScope: input.taskScope))
    let snapshot = await fixture.gateway.executionResults(inputID: input.id)
    #expect(snapshot.actions.records.isEmpty)
    #expect(await fixture.probe.exports == 0)
    #expect(await fixture.probe.operations.isEmpty)
    #expect(throws: CommunicationError.self) {
        try PhotographerCameraIntent(
            .open, previewID: UUID().uuidString, requestID: UUID().uuidString
        ).message.validatedSize()
    }
    await fixture.runtime.shutdown()
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func cameraContainerCallsPhotographerDirectlyAndWaitsForNativeCompletion() async throws {
    let ui = UIContainer()
    try ui.start()
    let host = try await CameraFixture(uiCamera: ui.camera)
    try await host.runtime.prepareForInteraction()
    _ = try await ui.camera.requests.submit(.init(.open))
    _ = try await ui.camera.requests.submit(.init(.close))
    #expect(await host.probe.operations == [.open, .close])
    #expect(await host.probe.sources.allSatisfy { $0 == "photographer" })
    await host.runtime.shutdown()
    await ui.stop()
}

@Test(.actionCatalog) func perceptionUIRequestsUseFixedSeparateActionsThroughGateway() async throws {
    let f = try await CameraFixture()
    try await f.runtime.perform(.perceptionOpen)
    try await f.runtime.perform(.perceptionFlip, facing: .back)
    try await f.runtime.perform(.perceptionClose)
    #expect(await f.probe.operations == [.perceptionOpen, .perceptionFlip, .perceptionClose])
    #expect(await f.probe.facings == ["back"])
    await f.runtime.shutdown()
}

@Test(.actionCatalog) @MainActor func cameraVideoButtonsUsePhotographerGatewayAndDeclaredActions() async throws {
    let fixture = try await CameraFixture()
    try await fixture.runtime.prepareForInteraction()
    let requests = fixture.runtime.camera.requests
    var settings = CameraSettings()
    settings.mode = "video"
    settings.durationSeconds = 10
    _ = try await requests.submit(.init(.configure, settings: settings))
    let start = try #require(try await requests.submit(.init(.startRecording)))
    let receipt = try JSONDecoder().decode(CameraVideoReceipt.self, from: Data(start.utf8))
    _ = try await requests.submit(.init(.stopRecording, recordingID: receipt.recordingID))
    _ = try await requests.submit(.init(.saveVideo, recordingID: receipt.recordingID))
    _ = try await requests.submit(.init(.ignoreVideo, recordingID: receipt.recordingID))
    _ = try await requests.submit(.init(.cancelCapture))
    #expect(
        await fixture.probe.operations == [
            .configure, .open, .startRecording, .stopRecording, .saveVideo, .ignoreVideo, .cancelCapture,
        ])
    #expect(await fixture.probe.sources.allSatisfy { $0 == "photographer" })
    let catalog = try AgentSkillLoader.registry(
        ["photography"], fixed: AgentConfigurations.load(named: "Assistant").capabilities)
    for (alias, path) in [
        ("configureCamera", "Camera.Capture.configure"), ("startRecording", "Camera.Video.startRecording"),
        ("stopRecording", "Camera.Video.stopRecording"), ("saveVideo", "Camera.Video.saveVideo"),
        ("ignoreVideo", "Camera.Video.ignoreVideo"),
    ] {
        let parameters =
            ["stopRecording", "saveVideo", "ignoreVideo"].contains(alias) ? ["recordingID": receipt.recordingID] : [:]
        #expect(try catalog.resolveAction(alias, parameters: parameters).actionPath.description == path)
    }
    await fixture.runtime.shutdown()
}

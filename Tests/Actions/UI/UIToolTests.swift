import Actions
import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import ModelKit
import StorageCore
import Testing
import UI

@testable import Agents
@testable import PlatformKit

/// Reuse scheduler fixtures in argument validation tests while constructing a genuine immediate Tool envelope.
func uiActionInvocation(_ invocation: any FunctionInput) -> ActionInvocation {
    let call = ToolCall(
        id: UUID().uuidString,
        toolPath: "Fixture.Control.UI." + invocation.call.actionPath.function, arguments: invocation.call.parameters)
    let e = invocation.testEnvelope
    let envelope = OutputEnvelope(
        source: e.source,
        context: AgentInput(id: e.inputID, sessionID: e.sessionID, payload: .event("fixture"), turn: e.turn).context,
        output: .toolCall(call), sequence: e.sequence)
    return ActionInvocation(call: call, envelope: envelope)
}

private actor CaptionEndpoint {
    var policy = ConversationPresentation()
    var reply = ""
    var transcript = ""
    var transcriptFinalized = false
    func begin(_ invocation: any FunctionInput) {
        if policy.accept(invocation.context, update: .beginReply) { reply = "" }
    }
    func append(_ text: String, _ invocation: any FunctionInput) {
        if policy.accept(invocation.context, update: .reply) { reply += text }
    }
    func replace(_ text: String, _ invocation: any FunctionInput) {
        if policy.accept(invocation.context, update: .transcript) { transcript = text }
    }
    func close(_ invocation: any FunctionInput) {
        if policy.accept(invocation.context, update: .finishTranscript) { transcriptFinalized = true }
    }
}

@Test(.actionCatalog) func immediateCaptionToolsPreserveAppendReplacementAndTurnFences() async throws {
    let endpoint = CaptionEndpoint()
    let input = AgentInput(
        id: UUID().uuidString, sessionID: UUID().uuidString, payload: .event("fixture"),
        turn: AgentTurn(id: UUID().uuidString, ordinal: 1))
    func invocation(_ function: String, text: String? = nil, source: AgentID, sequence: UInt64) -> ActionInvocation {
        let call = ToolCall(
            id: UUID().uuidString, toolPath: "Fixture.Control.UI." + function,
            arguments: text.map { ["text": $0] } ?? [:])
        return ActionInvocation(
            call: call,
            envelope: OutputEnvelope(
                source: source, context: input.context,
                output: .toolCall(call), sequence: sequence, taskScope: input.taskScope))
    }
    try await UIActions.beginReplyTurn(invocation: invocation("beginReplyTurn", source: .assistant, sequence: 1)) {
        await endpoint.begin($0)
    }
    let first = invocation("print", text: "第一句。", source: .assistant, sequence: 2)
    for _ in 0..<2 {
        try await UIActions.print(invocation: first) { await endpoint.append($0, $1) }
    }
    try await UIActions.print(invocation: invocation("print", text: "第二句。", source: .assistant, sequence: 3)) {
        await endpoint.append($0, $1)
    }
    #expect(await endpoint.reply == "第一句。第二句。")
    for (offset, text) in ["你", "你好", "你好世界"].enumerated() {
        try await UIActions.setTranscript(
            invocation: invocation(
                "setTranscript", text: text,
                source: .speechPerception, sequence: UInt64(offset + 1))
        ) { await endpoint.replace($0, $1) }
    }
    #expect(await endpoint.transcript == "你好世界")
    try await UIActions.finishTranscript(
        invocation: invocation("finishTranscript", source: .speechPerception, sequence: 4)
    ) {
        await endpoint.close($0)
    }
    try await UIActions.setTranscript(
        invocation: invocation(
            "setTranscript", text: "迟到的结果",
            source: .speechPerception, sequence: 5)
    ) { await endpoint.replace($0, $1) }
    #expect(await endpoint.transcript == "你好世界")
    #expect(await endpoint.transcriptFinalized)
    #expect(await endpoint.reply == "第一句。第二句。")
}

@Test @MainActor func microphoneSpectrumExecutionFencesCapturesAndUIRoots() async throws {
    let ui = UI.UIContainer()
    try ui.start()
    let state = ui.home.conversation
    let presentation = MicrophoneSpectrumPresentation(state: state)
    let old = try presentation.begin(sessionID: "voice", captureGeneration: "first")
    #expect(try presentation.present(Array(repeating: 1, count: 32), using: old))
    #expect(state.microphoneSpectrum.contains { $0 > 0 })
    let current = try presentation.begin(sessionID: "voice", captureGeneration: "second")
    let retained = state.microphoneSpectrum
    #expect(!presentation.finish(old))
    #expect(try !presentation.present(Array(repeating: 0, count: 32), using: old))
    #expect(state.microphoneSpectrum == retained)
    #expect(try presentation.present(Array(repeating: 0.5, count: 32), using: current))
    try ui.setForeground(false)
    #expect(try !presentation.present(Array(repeating: 1, count: 32), using: current))
    try ui.setForeground(true)
    #expect(try !presentation.present(Array(repeating: 1, count: 32), using: current))
    let resumed = try presentation.begin(sessionID: "voice", captureGeneration: "third")
    #expect(!presentation.finish(current))
    #expect(try presentation.present(Array(repeating: 0.5, count: 32), using: resumed))
    #expect(presentation.finish(resumed))
    #expect(state.microphoneSpectrum.allSatisfy { $0 == 0 })
    await ui.stop()
}

@Test @MainActor func microphoneSpectrumExecutionRejectsInvalidMeasurementsWithoutMutation() async throws {
    let ui = UI.UIContainer()
    try ui.start()
    let presentation = MicrophoneSpectrumPresentation(state: ui.home.conversation)
    #expect(throws: MicrophoneSpectrumPresentation.Failure.self) {
        try presentation.begin(sessionID: "", captureGeneration: "capture")
    }
    let handle = try presentation.begin(sessionID: "voice", captureGeneration: "capture")
    let invalid: [[Float]] = [[], [1], Array(repeating: .nan, count: 32), Array(repeating: 2, count: 32)]
    for values in invalid {
        #expect(throws: MicrophoneSpectrumPresentation.Failure.self) { try presentation.present(values, using: handle) }
    }
    #expect(ui.home.conversation.microphoneSpectrum.allSatisfy { $0 == 0 })
    presentation.finish(handle)
    await ui.stop()
}

@Test(.actionCatalog) @MainActor func actionsPerceptionPortKeepsConsentAndCaptureRevisionAuthorityInTheAgent()
    async throws
{
    let ui = UI.UIContainer()
    try ui.start()
    let role = try SpeechPerceptionAgent(
        recognition: PortUnusedRecognition(), vad: PortUnusedVAD(), sessionID: "initial",
        interactionSessionID: "voice-root", residentListening: true, uiHome: ui.home,
        context: AgentContextRepository(
            agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState()))
    try await role.start()
    let perception: any VoicePerceptionHandling = role
    #expect(await perception.isRunning())
    var outputs = role.outputs.makeAsyncIterator()
    try await ui.home.listeningRequests.submitControl(.setEnabled(true))
    let envelope = try #require(await outputs.next())
    guard case .actionCall(let call) = envelope.output else {
        Issue.record("Consent must produce an authorized listening Action")
        await role.stop()
        await ui.stop()
        return
    }
    let rawRevision = try #require(call.parameters["revision"])
    let revision = try #require(UInt64(rawRevision))
    try await perception.captureEnded(revision: revision + 1, sessionID: "voice-root")
    try await perception.openCapture(sessionID: "capture")
    await perception.closeCapture()
    await #expect(throws: CommunicationError.scopeClosed) {
        try await perception.captureEnded(revision: revision, sessionID: "foreign-root")
    }
    try await perception.captureEnded(revision: revision, sessionID: "voice-root")
    await #expect(throws: HarnessError.notRunning) { try await perception.openCapture(sessionID: "next") }
    await perception.stop()
    #expect(await !perception.isRunning())
    await ui.stop()
}

private struct PortUnusedRecognition: SpeechRecognitionCapability {
    var availability: CapabilityAvailability { .available }
    func transcribe(_ request: SpeechRecognitionRequest) throws -> SpeechRecognitionSession {
        throw CapabilityError.unavailable("Policy-only port regression must not open ASR")
    }
}
private struct PortUnusedVAD: VoiceActivityCapability {
    var availability: CapabilityAvailability { .available }
    func detectVoiceActivity(format: AudioFormat) throws -> any VoiceActivitySession {
        throw CapabilityError.unavailable("Policy-only port regression must not open VAD")
    }
}

/// Explicit native substitute. No system permission, microphone, playback or physical signal.
@MainActor private final class DetectionAudioFixture: AudioCaptureControlling {
    let source = MicrophoneCapture()
    let events = AsyncThrowingStream<NativeAudioEvent, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let stopped = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var captureContext = AudioCaptureContext(input: .builtInMicrophone, spatialSupport: .unsupported)
    var cleanupFailure: (any Error)?
    var denied = false
    var calls: [String] = []
    var stopCount = 0
    func requestPermissions() async throws {
        calls.append("permission")
        if denied { throw AudioIOError.microphoneDenied }
    }
    func subscribeEvents() throws -> AsyncThrowingStream<NativeAudioEvent, any Error> { events.stream }
    func startCapture(preferSpatial: Bool) async throws {
        try Task.checkCancellation()
        calls.append("capture.start")
        try source.send(MicrophoneFrame(samples: Array(repeating: 0.01, count: 1024), sampleRate: 16000, sequence: 0))
    }
    func subscribeCapture() async throws -> MicrophoneCaptureInput { try source.subscribe() }
    func stopCapture() async {
        calls.append("capture.stop")
        source.finish()
    }
    func stop() async {
        stopCount += 1
        calls.append("audio.stop")
        await stopCapture()
        stopped.continuation.yield(())
    }
    var connections: AudioDetectionConnections {
        AudioDetectionConnections { [self] id, input, observe, _ in
            calls.append("factory.start")
            let role = try SpeechPerceptionAgent(
                recognition: PortUnusedRecognition(), vad: PortUnusedVAD(), sessionID: id, mode: .soundSourceOnly,
                microphoneInput: input,
                microphoneObservation: { observe(.microphone($0.layout, $0.sampleRate, $0.rms, $0.capturedAt)) },
                context: AgentContextRepository(
                    agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState()))
            try await role.start()
            return AudioDetectionPerception(
                perception: role,
                stop: {
                    await role.stop()
                    self.calls.append("factory.stop")
                })
        }
    }
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func actionsAudioDetectionCancellationAndInterruptionJoinActualExecution() async throws {
    for cancel in [true, false] {
        let audio = DetectionAudioFixture()
        let endpoint = AudioDetectionSession(
            connections: audio.connections, execution: AudioDetectionExecution(audio: audio, beforeStart: {}))
        let updates = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let operation = Task {
            try await endpoint.run { if $0.capturedAt != nil { updates.continuation.yield(()) } }
        }
        var ready = updates.stream.makeAsyncIterator()
        _ = try #require(await ready.next())
        #expect(audio.calls.first == "permission")
        #expect(audio.calls.contains("capture.start"))
        if cancel { operation.cancel() } else { audio.events.continuation.yield(.interrupted) }
        let result = await operation.result
        guard case .failure(let failure) = result else {
            Issue.record("Detection must report termination")
            continue
        }
        if cancel {
            #expect(failure is CancellationError)
        } else {
            #expect(failure.localizedDescription.contains("interrupted"))
        }
        #expect(audio.stopCount == 1)
        let nativeStop = try #require(audio.calls.firstIndex(of: "audio.stop"))
        let rolesJoined = try #require(audio.calls.firstIndex(of: "factory.stop"))
        #expect(nativeStop < rolesJoined)
        #expect(!audio.source.isActive)
    }
}

@Test @MainActor func actionsAudioDetectionPermissionFailureDoesNotStartRolesOrCapture() async {
    let audio = DetectionAudioFixture()
    audio.denied = true
    let endpoint = AudioDetectionSession(
        connections: audio.connections, execution: AudioDetectionExecution(audio: audio, beforeStart: {}))
    var permission: Bool?
    do {
        try await endpoint.run { permission = $0.permissionGranted }
        Issue.record("Denied permission must fail")
    } catch { #expect(error.localizedDescription.contains("Allow microphone access")) }
    #expect(permission == false)
    #expect(!audio.calls.contains("factory.start"))
    #expect(!audio.calls.contains("capture.start"))
    #expect(audio.stopCount == 1)
}

private actor DetectionFactoryGate {
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered.continuation.yield(())
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
/// Lifecycle substitute for a factory that ignores cancellation; it never supplies native data.
private actor LateDetectionPerception: VoicePerceptionHandling {
    private var running = true
    func stop() { running = false }
    func isRunning() -> Bool { running }
    func openCapture(sessionID: String) throws { throw HarnessError.unsupportedInput }
    func closeCapture() {}
    func startInput(sessionID: String) throws { throw HarnessError.unsupportedInput }
    func waitForInput() throws { throw HarnessError.unsupportedInput }
    func stopInput() {}
    func stopListening(sessionID: String) throws { throw HarnessError.unsupportedInput }
    func captureEnded(revision: UInt64, sessionID: String) throws { throw HarnessError.unsupportedInput }
    func acquirePlaybackAdmission() -> Bool { false }
    func resumeListening() throws { throw HarnessError.unsupportedInput }
}

@Test(.timeLimit(.minutes(1))) @MainActor func actionsAudioDetectionRetiresAFactoryReturningAfterShutdown() async throws
{
    let audio = DetectionAudioFixture()
    let role = LateDetectionPerception()
    let gate = DetectionFactoryGate()
    let connection = AudioDetectionConnections { _, _, _, _ in
        await gate.wait()
        return AudioDetectionPerception(perception: role, stop: { audio.calls.append("factory.stop") })
    }
    let endpoint = AudioDetectionSession(
        connections: connection, execution: AudioDetectionExecution(audio: audio, beforeStart: {}))
    let operation = Task { try await endpoint.run { _ in } }
    var entered = gate.entered.stream.makeAsyncIterator()
    _ = try #require(await entered.next())
    operation.cancel()
    var stopped = audio.stopped.stream.makeAsyncIterator()
    _ = try #require(await stopped.next())
    await gate.release()
    guard case .failure(let failure) = await operation.result else {
        Issue.record("Cancelled factory must fail")
        return
    }
    #expect(failure is CancellationError)
    #expect(await !role.isRunning())
    #expect(!audio.calls.contains("capture.start"))
    #expect(audio.calls.filter { $0 == "factory.stop" }.count == 1)
    #expect(audio.stopCount == 1)
}

private enum DetectionFactoryFailure: Error { case unavailable }
@Test @MainActor func actionsAudioDetectionRejectsAReportedFactoryFailureBeforeNativeStart() async {
    let audio = DetectionAudioFixture()
    let role = LateDetectionPerception()
    let connection = AudioDetectionConnections { _, _, _, fail in
        await fail(DetectionFactoryFailure.unavailable)
        return AudioDetectionPerception(perception: role, stop: { audio.calls.append("factory.stop") })
    }
    let endpoint = AudioDetectionSession(
        connections: connection, execution: AudioDetectionExecution(audio: audio, beforeStart: {}))
    do {
        try await endpoint.run { _ in }
        Issue.record("A reported role failure must reject native execution")
    } catch { #expect(error as? DetectionFactoryFailure == .unavailable) }
    #expect(await !role.isRunning())
    #expect(!audio.calls.contains("capture.start"))
    #expect(audio.calls.filter { $0 == "factory.stop" }.count == 1)
    #expect(audio.stopCount == 1)
}

private struct DetectionFunctionModule: ToolModule { let definitions: [ActionBinding] }
@MainActor private final class HeldDetectionCapability: AudioDetectionCapability {
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var joined = false
    func runDetection(invocation: any FunctionInput) async throws {
        #expect(invocation.context.source == "applicationControl")
        let readiness = try #require(invocation.attachment as? AudioDetectionReadiness)
        readiness.ready()
        entered.continuation.yield(())
        defer {
            joined = true
            readiness.finish()
        }
        try await Task.sleep(for: .seconds(60))
    }
}
@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func diagnosticContainerRequestsReachTheAgentAndStopJoinsProtectedExecution() async throws {
    let ui = UIContainer()
    try ui.start()
    let agent = try ApplicationControlAgent(
        sessionID: "detection-ui", uiDiagnostics: ui.diagnostics,
        context: AgentContextRepository(
            agent: .applicationControl, scope: UUID().uuidString, state: ApplicationControlContextState()))
    let manager = AgentManager()
    let policy = try CommunicationPolicy(
        contracts: AgentContracts.communication, configurations: AgentConfigurations.all())
    let input = InputGateway(manager: manager, policy: policy)
    let capability = HeldDetectionCapability()
    let function = SpeechActions.detectionFunction(using: capability)
    let tools = try ToolRegistry(modules: [
        DetectionFunctionModule(definitions: [BehaviorProtocolBindings.bind(function)])
    ])
    let output = await OutputGateway(
        manager: manager, requests: input, tools: tools,
        actions: ChannelScheduler(registry: ActionRegistry()), policy: policy, sink: { _ in })
    try await manager.register(agent)
    let consumer = try await output.consumer(for: agent)
    await agent.bindUIExecution(consumer)
    try await manager.start(.applicationControl)
    let request = Task { try await ui.diagnostics.detectionRequests.submit(.start) }
    for await _ in capability.entered.stream { break }
    try await ui.diagnostics.detectionRequests.submitControl(.stop)
    await #expect(throws: CancellationError.self) { try await request.value }
    #expect(capability.joined)
    #expect(ui.diagnostics.detectionRequests.outstanding == 0)
    await agent.stop()
    await output.shutdown()
    await ui.stop()
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func detectionCancellationPreservesActualCleanupFailure() async throws {
    let audio = DetectionAudioFixture()
    let endpoint = AudioDetectionSession(
        connections: audio.connections,
        execution: AudioDetectionExecution(audio: audio, beforeStart: {}))
    let ready = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let operation = Task { try await endpoint.run { if $0.capturedAt != nil { ready.continuation.yield(()) } } }
    for await _ in ready.stream { break }
    audio.cleanupFailure = DetectionFactoryFailure.unavailable
    operation.cancel()
    guard case .failure(let error) = await operation.result, let merged = error as? NativeCleanupFailure else {
        Issue.record("Cancellation must preserve actual cleanup failure")
        return
    }
    #expect(merged.errors.count == 2)
    #expect(merged.errors.contains { $0 is CancellationError })
    #expect(merged.errors.contains { $0 as? DetectionFactoryFailure == .unavailable })
    #expect(audio.stopCount == 1)
}

@Test(.actionCatalog, .timeLimit(.minutes(1))) @MainActor
func listeningPressIsDirectTypedInputAndDoesNotGrantCaptureConsent() async throws {
    let ui = UIContainer()
    try ui.start()
    let role = try SpeechPerceptionAgent(
        recognition: PortUnusedRecognition(), vad: PortUnusedVAD(),
        sessionID: "capture-policy", interactionSessionID: "gesture-ui", residentListening: true, uiHome: ui.home,
        context: AgentContextRepository(
            agent: .speechPerception, scope: UUID().uuidString, state: SpeechPerceptionContextState()))
    try await role.start()
    var outputs = role.outputs.makeAsyncIterator()
    for pressed in [true, false] {
        try await ui.home.listeningRequests.submitControl(.press(pressed))
        let envelope = try #require(await outputs.next())
        guard case .toolCall(let call) = envelope.output else {
            Issue.record("Expected private feedback execution")
            break
        }
        #expect(call.toolPath == "Speech.Listening.prepare")
        #expect(call.arguments == ["pressed": String(pressed)])
        #expect(envelope.inputMetadata.origin == .local)
        #expect(envelope.context.generation == ui.home.listeningRequests.generation.uuidString)
    }
    // No policy enable Action, VAD, ASR or native capture was requested.
    #expect(await role.status().processedInputs == 0)
    await role.stop()
    await ui.stop()
}

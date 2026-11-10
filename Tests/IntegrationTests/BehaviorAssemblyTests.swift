import Actions
import AgentCore
import CallRuntime
import ExecutionRuntime
import Foundation
import FunctionContracts
import Gateway
import PlatformKit
import StorageChat
import StorageCore
import Testing
import UI

@testable import Agents

private actor BehaviorEndpoint: UIPresentationCapability, UIUpdateCapability, SpeechPlaybackCapability,
    PosePresentationCapability, CameraControlCapability, HistoryPresentationCapability, ResourcePresentationCapability,
    TaskControlCapability, WindowControlCapability, IslandControlCapability, WebCapability, ArtifactCapability
{
    func perform(invocation: any FunctionInput) async throws -> String { throw CancellationError() }
    func perform(_ operation: String, invocation: any FunctionInput) async throws -> String {
        throw CancellationError()
    }
    func performIsland(_ command: IslandCommand, context: IslandActionContext) async throws -> IslandReceipt {
        throw CancellationError()
    }
    func performWindow(_ operation: WindowOperation, id: String, x: Double?, y: Double?, invocation: any FunctionInput)
        async throws
    { throw CancellationError() }
    func controlTask(_ operation: String, arguments: [String: String], invocation: any FunctionInput) async throws
        -> ActionCompletion
    {
        throw CancellationError()
    }
    func presentResources(_ inventory: ModelResourceInventory, generation: UInt64, invocation: any FunctionInput)
        async throws
    {}
    func presentResourcePreferenceFailure(
        _ reason: ResourcePreferenceFailureReason, message: String, invocation: any FunctionInput
    ) async throws {
        throw CancellationError()
    }
    func presentResourceOperationFailure(_ message: String, invocation: any FunctionInput) async throws {
        throw CancellationError()
    }
    func presentResourceFailure(_ message: String, generation: UInt64, invocation: any FunctionInput) async throws {}
    func showHistory(invocation: any FunctionInput) async throws {}
    private(set) var cameraCalls: [String] = []
    func setEnabled(_ enabled: Bool, invocation: any FunctionInput) async throws {
        cameraCalls.append(enabled ? "open" : "close")
    }
    func flip(_ facing: CameraActions.Facing, invocation: any FunctionInput) async throws {
        cameraCalls.append("flip:" + facing.rawValue)
    }
    private(set) var emotion: UIActions.Emotion?
    private(set) var gaze: UIActions.Gaze?
    private(set) var pose: Actions.PoseOverlay?
    func play(audioID: String, invocation: any FunctionInput) async throws {}
    func present(_ text: String, invocation: any FunctionInput) async throws {}
    func presentTranscript(_ text: String, invocation: any FunctionInput) async throws {}
    func finishTranscript(invocation: any FunctionInput) async throws {}
    func beginReplyTurn(invocation: any FunctionInput) async throws {}
    func clearReply(invocation: any FunctionInput) async throws {}
    func setReplyWaiting(_ enabled: Bool, requestID: String, invocation: any FunctionInput) async throws {}
    func presentVoiceState(_ state: UIActions.VoiceState, invocation: any FunctionInput) async throws {}
    func presentExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) async throws {
        self.emotion = emotion
    }
    func restoreExpression(invocation: any FunctionInput) async throws {}
    func setExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) async throws {
        self.emotion = emotion
    }
    func present(_ target: UIActions.Gaze, invocation: any FunctionInput) async throws { gaze = target }
    func present(_ overlay: Actions.PoseOverlay, sessionID: String) async throws { pose = overlay }
}

private struct FixtureActionModule: ActionModule {
    let definitions: [ActionBinding]
}
private struct FixtureToolModule: ToolModule {
    let definitions: [ActionBinding]
}
private func behaviorInvocation(_ function: String, parameters: [String: String] = [:]) -> ActionInvocation {
    ActionInvocation(
        source: .assistant,
        input: AgentInput(
            id: UUID().uuidString, sessionID: UUID().uuidString, payload: .event("fixture")),
        call: ActionCall(
            actionPath: ActionPath(domain: "UI", module: "Expression", function: function), channel: "main",
            parameters: parameters))
}

@Test(.actionCatalog) func builtInBehaviorAssemblyCoversAllAgentCatalogsAndPreservesTypedValidation() async throws {
    let endpoint = BehaviorEndpoint()
    let assembly = try BehaviorAssembly(
        presentation: endpoint, playback: endpoint, pose: endpoint, historyPresentation: endpoint, camera: endpoint,
        history: HistoryQueryService(store: AssistantHistoryStore()),
        historyMutations: HistoryMutationService(
            store: AssistantHistoryStore(), summarizeTitle: { _ in "Unused fixture title" }),
        windows: endpoint, web: endpoint, artifacts: endpoint, island: endpoint,
        modelResources: UnusedModelResourceCapability(),
        resourcePreferences: UnusedModelResourcePreferencesCapability(), resourceInventory: UnusedResourceInventory(),
        resourcePresentation: endpoint, providerDiscovery: UnusedProviderDiscovery(),
        providerSettings: UnusedProviderSettings(), device: UnusedDeviceControl(), taskControl: endpoint,
        gesture: { _, _ in throw CancellationError() },
        shakeBase: { _, _ in throw CancellationError() },
        aim: { _, _, _ in throw ActionExecutionFailure(code: .handlerFailed, message: "Fixture dependency unavailable")
        })
    for binding in assembly.bindings {
        if binding.protocols.contains(.action) {
            #expect({ if case .scheduled = binding.executionPolicy { true } else { false } }())
        } else {
            #expect({ if case .direct = binding.executionPolicy { true } else { false } }())
        }
    }
    #expect(await assembly.tools.handler(for: "Agent.Task.startTask") == nil)
    #expect(await assembly.tools.handler(for: "Artifacts.Workspace.open") != nil)
    #expect(await assembly.tools.handler(for: "Artifacts.Workspace.read") != nil)
    #expect(await assembly.tools.handler(for: "Artifacts.Workspace.perform") == nil)
    try BehaviorCoverage.validate(
        actions: assembly.actions, toolPaths: assembly.toolPaths,
        capabilities: [
            AssistantAgent.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities),
            SpeechPerceptionAgent.runtimeCapabilities(AgentConfigurations.load(named: "SpeechPerception").capabilities),
            VisionPerceptionAgent.runtimeCapabilities(AgentConfigurations.load(named: "VisionPerception").capabilities),
            PhotographerAgent.runtimeCapabilities(AgentConfigurations.load(named: "Photographer").capabilities),
            try ApplicationControlAgent(
                sessionID: UUID().uuidString,
                context: try AgentContextRepository(
                    agent: AgentID(rawValue: "applicationControl"), scope: UUID().uuidString,
                    state: ApplicationControlContextState())
            ).descriptor.capabilities,
            MemoryAgent.runtimeCapabilities(
                AgentConfigurations.load(named: "Memory").capabilities),
        ])
    let executor = ActionExecutor(registry: assembly.actions)
    await #expect(throws: UIActions.ExpressionError.invalidEmotion) {
        try await executor.execute(behaviorInvocation("express", parameters: ["emotion": "invalid"]))
    }
    #expect(await endpoint.emotion == nil)
    try await executor.execute(behaviorInvocation("express", parameters: ["emotion": "smile"]))
    #expect(await endpoint.emotion == .smile)
    let tool = ToolCall(id: UUID().uuidString, toolPath: "System.Runtime.runtimeInfo", arguments: [:])
    let result = try await ToolExecutor(registry: assembly.tools).execute(
        tool, envelope: behaviorInvocation("express").testEnvelope)
    #expect(result?.callID == tool.id)
    #expect(result?.isError == false)
    let show = ToolCall(
        id: UUID().uuidString,
        toolPath: "UI.Pose.showPose",
        arguments: ["payload": "{\"sequence\":1,\"timestamp\":0,\"rotation\":0,\"people\":[]}"]
    )
    let completion = try await ToolExecutor(registry: assembly.tools).execute(
        show, envelope: behaviorInvocation("express").testEnvelope)
    #expect(completion == nil)
    #expect(await endpoint.pose?.people.isEmpty == true)
}

@Test(.actionCatalog) func behaviorAssemblyRejectsMissingInternalToolBeforeRuntimeStarts() throws {
    let permissions = try CapabilityRegistry(internalTools: [InternalTool(path: "Missing.Control.tool")])
    #expect(throws: HarnessError.forbiddenTool) {
        let assembly = try BehaviorAssembly(actionModules: [], toolModules: [])
        try BehaviorCoverage.validate(
            actions: assembly.actions, toolPaths: assembly.toolPaths, capabilities: [permissions])
    }
}

@Test(.actionCatalog) func behaviorModulesRejectDuplicatesInvalidPathsAndExcessCapacity() throws {
    let tool = FixtureToolModule(definitions: [ActionBinding(path: "Fixture.Control.fixture", handler: { _ in "ok" })])
    #expect(throws: ToolRegistryError.duplicateHandler) { try ToolRegistry(modules: [tool, tool]) }
    #expect(throws: ToolRegistrationError.invalidDefinition("bad path")) {
        try ToolRegistry(modules: [
            FixtureToolModule(definitions: [ActionBinding(path: "bad path", handler: { _ in "" })])
        ])
    }
    #expect(throws: ToolRegistryError.queueFull) { try ToolRegistry(modules: Array(repeating: tool, count: 33)) }
    let action = FixtureActionModule(definitions: [
        ActionBinding(
            path: ActionPath(domain: "Fixture", module: "Control", function: "apply"), displayName: "测试动作",
            kind: .state,
            completion: "Committed.",
            handler: { _ in })
    ])
    #expect(
        throws: ActionExecutionError.duplicateDefinition(
            ActionIdentifier(domain: "Fixture", module: "Control", function: "apply"))
    ) {
        try ActionRegistry(modules: [action, action])
    }
}

@Test(.actionCatalog) func additionalBehaviorModulesExecuteWithoutAnApplicationHost() async throws {
    let endpoint = BehaviorEndpoint()
    let path = ActionPath(domain: "Fixture", module: "Control", function: "smile")
    let resource = ResourceID(rawValue: "fixture.output")
    let action = FixtureActionModule(definitions: [
        ActionBinding(
            path: path, displayName: "测试动作", kind: .state, completion: "Expression accepted.", resources: [resource],
            handler: {
                try await endpoint.presentExpression(.smile, invocation: $0)
            })
    ])
    let tool = FixtureToolModule(definitions: [
        ActionBinding(
            path: "Fixture.Control.read", resources: [ActionResource(rawValue: resource.rawValue)],
            handler: { _ in
                await endpoint.emotion?.rawValue ?? "clear"
            })
    ])
    let assembly = try BehaviorAssembly(actionModules: [action], toolModules: [tool])
    #expect(
        try assembly.actions.definition(
            for: ActionIdentifier(domain: path.domain, module: path.module, function: path.function)
        ).resources == [ActionResource(rawValue: resource.rawValue)])
    #expect(
        await assembly.tools.resources(for: "Fixture.Control.read") == [ActionResource(rawValue: resource.rawValue)])
    let invocation = ActionInvocation(
        source: .assistant,
        input: AgentInput(
            id: UUID().uuidString, sessionID: UUID().uuidString, payload: .event("fixture")),
        call: ActionCall(actionPath: path, channel: "main"))
    try await ActionExecutor(registry: assembly.actions).execute(invocation)
    let result = try await ToolExecutor(registry: assembly.tools).execute(
        ToolCall(id: UUID().uuidString, toolPath: "Fixture.Control.read", arguments: [:]),
        envelope: invocation.testEnvelope)
    #expect(result?.value == "smile")
}

@Test(.actionCatalog) func cameraToolsValidateBeforeEffectsAndKeepCompletionSemantics() async throws {
    let endpoint = BehaviorEndpoint()
    let executor = ToolExecutor(registry: try ToolRegistry(modules: [CameraModule(camera: endpoint)]))
    let envelope = behaviorInvocation("express").testEnvelope
    for name in ["open", "close", "flip"] {
        let result = try await executor.execute(
            ToolCall(
                id: UUID().uuidString, toolPath: "Camera.Capture." + name,
                arguments: name == "flip" ? ["facing": "front"] : [:]),
            envelope: envelope)
        #expect(result == nil)
    }
    #expect(await endpoint.cameraCalls == ["open", "close", "flip:front"])
    let invalid = try #require(
        try await executor.execute(
            ToolCall(
                id: UUID().uuidString, toolPath: "Camera.Capture.flip", arguments: ["unexpected": "yes"]),
            envelope: envelope))
    #expect(invalid.isError)
    #expect(invalid.value.contains("invalidKeys"))
    for arguments in [[:], ["facing": "rear"], ["facing": ""], ["facing": "Front"]] {
        let rejected = try #require(
            try await executor.execute(
                ToolCall(id: UUID().uuidString, toolPath: "Camera.Capture.flip", arguments: arguments),
                envelope: envelope))
        #expect(rejected.isError)
    }
    #expect(await endpoint.cameraCalls == ["open", "close", "flip:front"])
    _ = try await executor.execute(
        ToolCall(id: UUID().uuidString, toolPath: "Camera.Capture.flip", arguments: ["facing": "back"]),
        envelope: envelope)
    #expect(await endpoint.cameraCalls.last == "flip:back")

    #expect(await endpoint.cameraCalls.count == 4)
    let cancelled = Task {
        try Task.checkCancellation()
        try await Task.sleep(for: .seconds(30))
        return try await executor.execute(
            ToolCall(id: UUID().uuidString, toolPath: "Camera.Capture.open", arguments: [:]),
            envelope: envelope)
    }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(await endpoint.cameraCalls.count == 4)
}

private struct UnavailableCameraEndpoint: CameraControlCapability {
    func setEnabled(_ enabled: Bool, invocation: any FunctionInput) async throws {
        throw CameraControlError.permissionDenied
    }
    func flip(_ facing: CameraActions.Facing, invocation: any FunctionInput) async throws {
        throw CameraControlError.disabled
    }
}

@Test(.actionCatalog) func cameraToolsRecordHostFailureWithoutSuccessFeedback() async throws {
    let executor = ToolExecutor(
        registry: try ToolRegistry(modules: [CameraModule(camera: UnavailableCameraEndpoint())]))
    let envelope = behaviorInvocation("express").testEnvelope
    let open = try #require(
        try await executor.execute(
            ToolCall(id: UUID().uuidString, toolPath: "Camera.Capture.open", arguments: [:]),
            envelope: envelope))
    #expect(open.isError && open.failureCode == .permissionDenied)
    let flip = try #require(
        try await executor.execute(
            ToolCall(id: UUID().uuidString, toolPath: "Camera.Capture.flip", arguments: ["facing": "back"]),
            envelope: envelope))
    #expect(flip.isError && flip.failureCode?.rawValue == "disabled")
}

@Test(.actionCatalog) func unifiedUIDomainBindsExpressionAndGazeWithoutChangingValidation() async throws {
    let endpoint = BehaviorEndpoint()
    let module = UIModule(expression: endpoint, pose: endpoint, updates: endpoint, history: endpoint)
    let assembly = try BehaviorAssembly(capabilityModules: [module])
    let actions = assembly.actions
    let tools = assembly.tools
    try await ActionExecutor(registry: actions).execute(
        behaviorInvocation("setExpression", parameters: ["emotion": "smile"]))
    let envelope = behaviorInvocation("setExpression").testEnvelope
    let response = try await ToolExecutor(registry: tools).execute(
        ToolCall(
            id: UUID().uuidString, toolPath: "UI.Gaze.moveEyes", arguments: ["x": "0.25", "y": "-0.5"]),
        envelope: envelope)
    #expect(response == nil)
    #expect(await endpoint.emotion == .smile)
    let accepted = await endpoint.gaze
    #expect(accepted?.x == 0.25 && accepted?.y == -0.5)
    let invalid = try await ToolExecutor(registry: tools).execute(
        ToolCall(id: UUID().uuidString, toolPath: "UI.Gaze.moveEyes", arguments: ["x": "1.1", "y": "0"]),
        envelope: envelope)
    #expect(invalid?.isError == true && invalid?.failureCode == .invalidArguments)
    #expect(await endpoint.gaze == accepted)
}

struct UnusedDeviceControl: DeviceControlCapability {
    func control(_ request: DeviceControlRequest, invocation: any FunctionInput) async throws {
        throw DeviceControlError.unavailable
    }
    func readStatus() async throws -> String { throw DeviceControlError.unavailable }
}

@MainActor private final class EndpointCameraFixture: CameraControlCapability {
    private(set) var calls = 0
    let receipt = CameraPhotoCommandReceipt(
        previewID: "captured-photo", state: .saved, alreadySaved: true, feedbackIssues: ["first", "第二个反馈"])
    var failure: (any Error)?
    func setEnabled(_ enabled: Bool, invocation: any FunctionInput) async throws { calls += 1 }
    func flip(_ facing: CameraActions.Facing, invocation: any FunctionInput) async throws { calls += 1 }
    func savePhoto(_ id: String?, invocation: any FunctionInput) async throws -> CameraPhotoCommandReceipt {
        calls += 1
        if let failure { throw failure }
        return receipt
    }
}

private func endpointInvocation(source: String, session: String, decision: String? = nil) -> FunctionInvocation {
    FunctionInvocation(
        call: FunctionRequest(
            actionPath: .init(domain: "Camera", module: "Capture", function: "savePhoto"), parameters: [:]),
        context: .init(source: source, sessionID: session, inputID: "input", decisionID: decision),
        executionID: UUID().uuidString, results: ActionReportStore())
}

@Test(.actionCatalog) @MainActor func cameraEndpointPreservesReceiptsAndRejectsForeignSessionsBeforeExecution()
    async throws
{
    let native = EndpointCameraFixture()
    var sessionChecks = 0
    let endpoint = CameraExecutionEndpoint(
        camera: native, rootSessionID: "root",
        validateSession: { invocation in
            sessionChecks += 1
            guard invocation.context.sessionID == "active-turn" else { throw CommunicationError.scopeClosed }
        })
    let receipt = try await endpoint.savePhoto(
        nil, invocation: endpointInvocation(source: "photographer", session: "root"))
    #expect(receipt == native.receipt)
    #expect(sessionChecks == 0 && native.calls == 1)
    _ = try await endpoint.savePhoto(
        nil, invocation: endpointInvocation(source: "assistant", session: "active-turn"))
    #expect(sessionChecks == 1 && native.calls == 2)
    await #expect(throws: CommunicationError.scopeClosed) {
        try await endpoint.savePhoto(nil, invocation: endpointInvocation(source: "assistant", session: "retired-turn"))
    }
    _ = try await endpoint.savePhoto(nil, invocation: endpointInvocation(source: "memory", session: "root"))
    #expect(native.calls == 3)
    native.failure = CameraControlError.permissionDenied
    await #expect(throws: CameraControlError.permissionDenied) {
        try await endpoint.savePhoto(nil, invocation: endpointInvocation(source: "photographer", session: "root"))
    }
}

@Test(.actionCatalog) @MainActor func taskEndpointKeepsAdmissionAndOriginalHandlerFailure() async throws {
    let endpoint = TaskControlEndpoint(rootSessionID: "root")
    await #expect(throws: ActionHostError.scopeClosed) {
        try await endpoint.controlTask(
            "task.start", arguments: [:], invocation: endpointInvocation(source: "assistant", session: "root"))
    }
    let accepted = LockedTaskRequests()
    endpoint.handler = { operation, _, source, session, _, _ in
        await accepted.record(operation + ":" + source + ":" + session)
        throw CancellationError()
    }
    await #expect(throws: ActionHostError.scopeClosed) {
        try await endpoint.controlTask(
            "task.start", arguments: [:], invocation: endpointInvocation(source: "assistant", session: "retired"))
    }
    await #expect(throws: CancellationError.self) {
        try await endpoint.controlTask(
            "task.start", arguments: [:], invocation: endpointInvocation(source: "memory", session: "root"))
    }
    #expect(await accepted.values == ["task.start:memory:root"])
    await #expect(throws: CancellationError.self) {
        try await endpoint.controlTask(
            "task.start", arguments: [:], invocation: endpointInvocation(source: "assistant", session: "root"))
    }
    #expect(await accepted.values == ["task.start:memory:root", "task.start:assistant:root"])
}

private actor LockedTaskRequests {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

@Test(.actionCatalog) func taskFunctionsRequireAnExplicitCapabilityInsteadOfPresentationConformance() throws {
    let endpoint = BehaviorEndpoint()
    func assemble(task: (any TaskControlCapability)?) throws -> BehaviorAssembly {
        try BehaviorAssembly(
            presentation: endpoint, playback: endpoint, pose: endpoint, historyPresentation: endpoint, camera: endpoint,
            history: HistoryQueryService(store: AssistantHistoryStore()),
            historyMutations: HistoryMutationService(
                store: AssistantHistoryStore(), summarizeTitle: { _ in "fixture" }),
            modelResources: UnusedModelResourceCapability(),
            resourcePreferences: UnusedModelResourcePreferencesCapability(),
            resourceInventory: UnusedResourceInventory(),
            resourcePresentation: endpoint, providerDiscovery: UnusedProviderDiscovery(),
            providerSettings: UnusedProviderSettings(), device: UnusedDeviceControl(), taskControl: task,
            gesture: { _, _ in }, shakeBase: { _, _ in }, aim: { _, _, _ in })
    }
    let path = ActionIdentifier(domain: "Agent", module: "Task", function: "startTask")
    #expect(try assemble(task: nil).functions.find(path) == nil)
    #expect(try assemble(task: endpoint).functions.find(path) != nil)
}

@MainActor private final class EndpointVoiceFixture: VoiceOutputHandling {
    private(set) var plays = 0
    private(set) var captions = 0
    private(set) var listening: [Bool] = []
    func setListening(enabled: Bool, invocation: any FunctionInput) throws { listening.append(enabled) }
    func validateCameraControl(invocation: any FunctionInput) throws {}
    func updateListening(
        enabled: Bool, paused: Bool, revision: UInt64, feedback: SpeechActions.ListeningFeedback,
        invocation: any FunctionInput
    ) async throws {}
    func playCue(_ request: UIActions.CueRequest, invocation: any FunctionInput) async throws {}
    func vibrate(_ request: UIActions.HapticRequest, invocation: any FunctionInput) async throws {}
    func play(audioID: String, invocation: any FunctionInput) async throws { plays += 1 }
    func present(_ text: String, invocation: any FunctionInput) throws { captions += 1 }
    func presentTranscript(_ text: String, invocation: any FunctionInput) throws {}
    func finishTranscript(invocation: any FunctionInput) throws {}
    func beginReplyTurn(invocation: any FunctionInput) throws {}
    func clearReply(invocation: any FunctionInput) throws {}
    func setReplyWaiting(_ enabled: Bool, requestID: String, invocation: any FunctionInput) throws {}
    func presentVoiceState(_ state: UIActions.VoiceState, invocation: any FunctionInput) throws {}
    func presentExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) async throws {}
    func restoreExpression(invocation: any FunctionInput) async throws {}
    func setExpression(_ emotion: UIActions.Emotion, invocation: any FunctionInput) throws {}
    func observeTranscript(_ text: String, sessionID: String) {}
    func observeEmptyUtterance(sessionID: String) {}
    func show(_ envelope: ActionOutputObservation) async {}
}

@Test(.actionCatalog) @MainActor func domainEndpointBindingsAreAtomicAndRetiredOwnersCannotUnbindReplacements()
    async throws
{
    let ui = UIContainer()
    let endpoints = ActionEndpoints(
        cameraControl: EndpointCameraFixture(), rootSessionID: "root", activity: ui.home.activity,
        effects: ui.home.effects, expressions: ui.home.expressions,
        homeBluetooth: ui.home.conversation, deviceBluetooth: ui.devices.state)
    let first = EndpointVoiceFixture()
    let replacement = EndpointVoiceFixture()
    let invocation = endpointInvocation(source: "assistant", session: "root")
    try endpoints.bindVoice(first)
    #expect(throws: ActionHostError.scopeClosed) { try endpoints.bindVoice(replacement) }
    endpoints.unbindVoice(replacement)
    try await endpoints.speech.play(audioID: "audio", invocation: invocation)
    try await endpoints.presentation.present("caption", invocation: invocation)
    #expect(first.plays == 1 && first.captions == 1 && replacement.plays == 0)
    endpoints.unbindVoice(first)
    await #expect(throws: ActionHostError.scopeClosed) {
        try await endpoints.speech.play(audioID: "audio", invocation: invocation)
    }
    try endpoints.bindVoice(replacement)
    endpoints.unbindVoice(first)
    try await endpoints.speech.play(audioID: "audio", invocation: invocation)
    try await endpoints.presentation.present("caption", invocation: invocation)
    #expect(replacement.plays == 1 && replacement.captions == 1)
    endpoints.unbindVoice(replacement)
}

@Test(.actionCatalog) @MainActor func listeningControlEndpointRejectsWrongSessionAndMissingOwner() async throws {
    let endpoint = SpeechExecutionEndpoint(rootSessionID: "root")
    let input = endpointInvocation(source: "assistant", session: "root")
    await #expect(throws: ActionHostError.scopeClosed) {
        try await endpoint.setListening(enabled: false, invocation: input)
    }
    let voice = EndpointVoiceFixture()
    try endpoint.bind(voice)
    await #expect(throws: ActionHostError.unauthorized) {
        try await endpoint.setListening(
            enabled: true, invocation: endpointInvocation(source: "assistant", session: "other"))
    }
    #expect(voice.listening.isEmpty)
    try await endpoint.setListening(enabled: true, invocation: input)
    try await endpoint.setListening(enabled: false, invocation: input)
    #expect(voice.listening == [true, false])
    endpoint.unbind(voice)
    await #expect(throws: ActionHostError.scopeClosed) {
        try await endpoint.setListening(enabled: true, invocation: input)
    }
}

@Test(.actionCatalog) func listeningCatalogUsesBasicSkillBindingsAndFailsWithoutCapability() async throws {
    let registry = try AgentSkillLoader.registry(["basic-skill"], fixed: CapabilityRegistry())
    let module = SpeechModule(playback: BehaviorEndpoint())
    for name in ["startListening", "stopListening"] {
        let path = ActionIdentifier(domain: "Speech", module: "Listening", function: name)
        let binding = try #require(registry.actions.first { $0.path.description == path.description })
        #expect(binding.alias == name && binding.defaultChannel == "ListeningControl")
        let definition = try #require(module.definitions.first { $0.path == path })
        let input = FunctionInvocation(
            call: .init(actionPath: path),
            context: .init(source: "assistant", sessionID: "root", inputID: UUID().uuidString, sequence: 1),
            executionID: UUID().uuidString, results: ActionReportStore())
        await #expect(throws: SpeechActionError.listeningUnavailable) {
            try await definition.handler(input)
        }
    }
}

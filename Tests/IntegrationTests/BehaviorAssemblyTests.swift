import ActionRuntime
import Actions
import AgentCore
import Agents
import BehaviorAssembly
import Foundation
import Gateway
import StorageChat
import Testing
import ToolRuntime
import Tools

private actor BehaviorEndpoint: UIPresentationCapability, UIUpdateCapability, SpeechPlaybackCapability,
    PosePresentationCapability, CameraControlCapability, HistoryPresentationCapability
{
    func showHistory(invocation: ToolInvocation) async throws {}
    private(set) var cameraCalls: [String] = []
    func setEnabled(_ enabled: Bool, invocation: ToolInvocation) async throws {
        cameraCalls.append(enabled ? "open" : "close")
    }
    func flip(invocation: ToolInvocation) async throws { cameraCalls.append("flip") }
    private(set) var emotion: UIActions.Emotion?
    private(set) var pose: ToolPoseOverlay?
    func play(audioID: UUID, invocation: ActionInvocation) async throws {}
    func present(_ text: String, invocation: ToolInvocation) async throws {}
    func presentTranscript(_ text: String, invocation: ToolInvocation) async throws {}
    func finishTranscript(invocation: ToolInvocation) async throws {}
    func beginReplyTurn(invocation: ToolInvocation) async throws {}
    func presentVoiceState(_ state: UITools.VoiceState, invocation: ToolInvocation) async throws {}
    func presentExpression(_ emotion: UIActions.Emotion, invocation: ActionInvocation) async throws {
        self.emotion = emotion
    }
    func restoreExpression(invocation: ActionInvocation) async throws {}
    func setExpression(_ emotion: UIActions.Emotion, invocation: ActionInvocation) async throws {
        self.emotion = emotion
    }
    func present(_ target: UITools.Gaze, invocation: ToolInvocation) async throws {}
    func present(_ overlay: ToolPoseOverlay, sessionID: UUID) async throws { pose = overlay }
}

private struct FixtureActionModule: ActionModule {
    let definitions: [ActionDefinition]
}
private struct FixtureToolModule: ToolModule {
    let definitions: [ToolDefinition]
}
private func behaviorInvocation(_ function: String, parameters: [String: String] = [:]) -> ActionInvocation {
    ActionInvocation(
        source: .assistant, input: AgentInput(sessionID: UUID(), payload: .event("fixture")),
        call: ActionCall(
            actionPath: ActionPath(module: "UI", function: function), channel: "main", parameters: parameters))
}

@Test func builtInBehaviorAssemblyCoversAllAgentCatalogsAndPreservesTypedValidation() async throws {
    let endpoint = BehaviorEndpoint()
    let assembly = try BehaviorAssembly(
        presentation: endpoint, playback: endpoint, pose: endpoint, historyPresentation: endpoint, camera: endpoint,
        history: HistoryQueryService(store: ConversationHistoryStore()),
        gesture: { _, _ in throw CancellationError() },
        shakeBase: { _, _ in throw CancellationError() },
        aim: { _, _, _ in throw ToolExecutionFailure(code: .handlerFailed, message: "Fixture dependency unavailable") })
    try BehaviorCoverage.validate(
        actions: assembly.actions, toolPaths: assembly.toolPaths,
        capabilities: [
            AssistantAgent.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities),
            SpeechPerceptionAgent.runtimeCapabilities(AgentConfigurations.load(named: "SpeechPerception").capabilities),
            VisionPerceptionAgent.runtimeCapabilities(AgentConfigurations.load(named: "VisionPerception").capabilities),
            PhotographerAgent.runtimeCapabilities(AgentConfigurations.load(named: "Photographer").capabilities),
            AgentConfigurations.load(named: "SpeechSynthesis").capabilities,
            ConversationMemoryAgent.runtimeCapabilities(
                AgentConfigurations.load(named: "ConversationMemory").capabilities),
        ])
    let executor = ActionExecutor(registry: assembly.actions)
    await #expect(throws: UIActions.ExpressionError.invalidEmotion) {
        try await executor.execute(behaviorInvocation("express", parameters: ["emotion": "invalid"]))
    }
    #expect(await endpoint.emotion == nil)
    try await executor.execute(behaviorInvocation("express", parameters: ["emotion": "smile"]))
    #expect(await endpoint.emotion == .smile)
    let tool = ToolCall(toolPath: "runtimeInfo", arguments: [:])
    let result = try await ToolExecutor(registry: assembly.tools).execute(
        tool, envelope: behaviorInvocation("express").testEnvelope)
    #expect(result?.callID == tool.id)
    #expect(result?.isError == false)
    let show = ToolCall(
        toolPath: "UI.showPose", arguments: ["payload": "{\"sequence\":1,\"timestamp\":0,\"rotation\":0,\"people\":[]}"]
    )
    let completion = try await ToolExecutor(registry: assembly.tools).execute(
        show, envelope: behaviorInvocation("express").testEnvelope)
    #expect(completion == nil)
    #expect(await endpoint.pose?.people.isEmpty == true)
}

@Test func behaviorAssemblyRejectsMissingInternalToolBeforeRuntimeStarts() throws {
    let permissions = try CapabilityRegistry(internalTools: [InternalTool(path: "Missing.tool")])
    #expect(throws: ToolRegistrationError.missingHandler("Missing.tool")) {
        let assembly = try BehaviorAssembly(actionModules: [], toolModules: [])
        try BehaviorCoverage.validate(
            actions: assembly.actions, toolPaths: assembly.toolPaths, capabilities: [permissions])
    }
}

@Test func behaviorModulesRejectDuplicatesInvalidPathsAndExcessCapacity() throws {
    let tool = FixtureToolModule(definitions: [ToolDefinition(path: "fixture", handler: { _ in "ok" })])
    #expect(throws: ToolRegistryError.duplicateHandler) { try ToolRegistry(modules: [tool, tool]) }
    #expect(throws: ToolRegistrationError.invalidDefinition("bad path")) {
        try ToolRegistry(modules: [
            FixtureToolModule(definitions: [ToolDefinition(path: "bad path", handler: { _ in "" })])
        ])
    }
    #expect(throws: ToolRegistryError.queueFull) { try ToolRegistry(modules: Array(repeating: tool, count: 33)) }
    let action = FixtureActionModule(definitions: [
        ActionDefinition(
            path: ActionPath(module: "Fixture", function: "apply"), displayName: "测试动作", kind: .state,
            completion: "Committed.",
            handler: { _ in })
    ])
    #expect(throws: ActionExecutionError.duplicateDefinition(ActionIdentifier(module: "Fixture", function: "apply"))) {
        try ActionRegistry(modules: [action, action])
    }
}

@Test func additionalBehaviorModulesExecuteWithoutAnApplicationHost() async throws {
    let endpoint = BehaviorEndpoint()
    let path = ActionPath(module: "Fixture", function: "smile")
    let resource = ResourceID(rawValue: "fixture.output")
    let action = FixtureActionModule(definitions: [
        ActionDefinition(
            path: path, displayName: "测试动作", kind: .state, completion: "Expression accepted.", resources: [resource],
            handler: {
                try await endpoint.presentExpression(.smile, invocation: $0)
            })
    ])
    let tool = FixtureToolModule(definitions: [
        ToolDefinition(
            path: "Fixture.read", resources: [ToolResource(rawValue: resource.rawValue)],
            handler: { _ in
                await endpoint.emotion?.rawValue ?? "clear"
            })
    ])
    let assembly = try BehaviorAssembly(actionModules: [action], toolModules: [tool])
    #expect(try assembly.actions.definition(for: path).resources == [ActionResource(rawValue: resource.rawValue)])
    #expect(await assembly.tools.resources(for: "Fixture.read") == [ToolResource(rawValue: resource.rawValue)])
    let invocation = ActionInvocation(
        source: .assistant, input: AgentInput(sessionID: UUID(), payload: .event("fixture")),
        call: ActionCall(actionPath: path, channel: "main"))
    try await ActionExecutor(registry: assembly.actions).execute(invocation)
    let result = try await ToolExecutor(registry: assembly.tools).execute(
        ToolCall(toolPath: "Fixture.read", arguments: [:]), envelope: invocation.testEnvelope)
    #expect(result?.value == "smile")
}

@Test func cameraToolsValidateBeforeEffectsAndKeepCompletionSemantics() async throws {
    let endpoint = BehaviorEndpoint()
    let executor = ToolExecutor(registry: try ToolRegistry(modules: [CameraToolModule(camera: endpoint)]))
    let envelope = behaviorInvocation("express").testEnvelope
    for name in ["open", "close", "flip"] {
        let result = try await executor.execute(
            ToolCall(toolPath: "Camera." + name, arguments: [:]), envelope: envelope)
        #expect(result == nil)
    }
    #expect(await endpoint.cameraCalls == ["open", "close", "flip"])
    let invalid = try #require(
        try await executor.execute(
            ToolCall(toolPath: "Camera.flip", arguments: ["unexpected": "yes"]), envelope: envelope))
    #expect(invalid.isError)
    #expect(invalid.value.contains("invalidKeys"))
    #expect(await endpoint.cameraCalls.count == 3)
    let cancelled = Task {
        try Task.checkCancellation()
        try await Task.sleep(for: .seconds(30))
        return try await executor.execute(ToolCall(toolPath: "Camera.open", arguments: [:]), envelope: envelope)
    }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(await endpoint.cameraCalls.count == 3)
}

private struct UnavailableCameraEndpoint: CameraControlCapability {
    func setEnabled(_ enabled: Bool, invocation: ToolInvocation) async throws {
        throw CameraControlError.permissionDenied
    }
    func flip(invocation: ToolInvocation) async throws { throw CameraControlError.disabled }
}

@Test func cameraToolsRecordHostFailureWithoutSuccessFeedback() async throws {
    let executor = ToolExecutor(
        registry: try ToolRegistry(modules: [CameraToolModule(camera: UnavailableCameraEndpoint())]))
    let envelope = behaviorInvocation("express").testEnvelope
    let open = try #require(
        try await executor.execute(ToolCall(toolPath: "Camera.open", arguments: [:]), envelope: envelope))
    #expect(open.isError && open.value.contains("permissionDenied"))
    let flip = try #require(
        try await executor.execute(ToolCall(toolPath: "Camera.flip", arguments: [:]), envelope: envelope))
    #expect(flip.isError && flip.value.contains("disabled"))
}

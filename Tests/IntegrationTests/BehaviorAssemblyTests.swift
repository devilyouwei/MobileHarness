import Actions
import AgentCore
import Agents
import BehaviorAssembly
import Foundation
import Testing
import Tools

private actor BehaviorEndpoint: UIPresentationCapability, UIUpdateCapability, SpeechPlaybackCapability,
    PosePresentationCapability
{
    private(set) var emotion: UIActions.Emotion?
    private(set) var pose: PoseOverlay?
    func play(audioID: UUID, invocation: ActionInvocation) async throws {}
    func present(_ text: String, invocation: ToolInvocation) async throws {}
    func presentTranscript(_ text: String, invocation: ToolInvocation) async throws {}
    func finishTranscript(invocation: ToolInvocation) async throws {}
    func beginReplyTurn(invocation: ToolInvocation) async throws {}
    func presentVoiceState(_ state: UITools.VoiceState, invocation: ToolInvocation) async throws {}
    func presentExpression(_ emotion: UIActions.Emotion, invocation: ActionInvocation) async throws {
        self.emotion = emotion
    }
    func present(_ target: UITools.Gaze, invocation: ToolInvocation) async throws {}
    func present(_ overlay: PoseOverlay, sessionID: UUID) async throws { pose = overlay }
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
        presentation: endpoint, playback: endpoint, pose: endpoint,
        gesture: { _, _ in throw CancellationError() },
        shakeBase: { _, _ in throw CancellationError() },
        capabilities: [
            AssistantAgent.runtimeCapabilities(AgentConfigurations.load(named: "Assistant").capabilities),
            SpeechPerceptionAgent.runtimeCapabilities(AgentConfigurations.load(named: "SpeechPerception").capabilities),
            VisionPerceptionAgent.runtimeCapabilities(AgentConfigurations.load(named: "VisionPerception").capabilities),
            AgentConfigurations.load(named: "SpeechSynthesis").capabilities,
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
        tool, envelope: behaviorInvocation("express").envelope)
    #expect(result?.callID == tool.id)
    #expect(result?.isError == false)
    let show = ToolCall(
        toolPath: "UI.showPose", arguments: ["payload": "{\"sequence\":1,\"timestamp\":0,\"rotation\":0,\"people\":[]}"]
    )
    let completion = try await ToolExecutor(registry: assembly.tools).execute(
        show, envelope: behaviorInvocation("express").envelope)
    #expect(completion == nil)
    #expect(await endpoint.pose?.people.isEmpty == true)
}

@Test func behaviorAssemblyRejectsMissingInternalToolBeforeRuntimeStarts() throws {
    let permissions = try CapabilityRegistry(internalTools: [InternalTool(path: "Missing.tool")])
    #expect(throws: ToolRegistrationError.missingHandler("Missing.tool")) {
        try BehaviorAssembly(actionModules: [], toolModules: [], capabilities: [permissions])
    }
}

@Test func behaviorModulesRejectDuplicatesInvalidPathsAndExcessCapacity() throws {
    let tool = FixtureToolModule(definitions: [ToolDefinition(path: "fixture", handler: { _ in "ok" })])
    #expect(throws: HarnessError.duplicateHandler) { try ToolRegistry(modules: [tool, tool]) }
    #expect(throws: ToolRegistrationError.invalidDefinition("bad path")) {
        try ToolRegistry(modules: [
            FixtureToolModule(definitions: [ToolDefinition(path: "bad path", handler: { _ in "" })])
        ])
    }
    #expect(throws: HarnessError.queueFull) { try ToolRegistry(modules: Array(repeating: tool, count: 33)) }
    let action = FixtureActionModule(definitions: [
        ActionDefinition(
            path: ActionPath(module: "Fixture", function: "apply"), displayName: "测试动作", kind: .state,
            completion: "Committed.",
            handler: { _ in })
    ])
    #expect(throws: ActionExecutionError.duplicateDefinition(ActionPath(module: "Fixture", function: "apply"))) {
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
            path: "Fixture.read", resources: [resource],
            handler: { _ in
                await endpoint.emotion?.rawValue ?? "clear"
            })
    ])
    let assembly = try BehaviorAssembly(actionModules: [action], toolModules: [tool], capabilities: [])
    #expect(try assembly.actions.definition(for: path).resources == [resource])
    #expect(await assembly.tools.resources(for: "Fixture.read") == [resource])
    let invocation = ActionInvocation(
        source: .assistant, input: AgentInput(sessionID: UUID(), payload: .event("fixture")),
        call: ActionCall(actionPath: path, channel: "main"))
    try await ActionExecutor(registry: assembly.actions).execute(invocation)
    let result = try await ToolExecutor(registry: assembly.tools).execute(
        ToolCall(toolPath: "Fixture.read", arguments: [:]), envelope: invocation.envelope)
    #expect(result?.value == "smile")
}

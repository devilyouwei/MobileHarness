import ActionRuntime
import Actions
import AgentCore
import Agents
import Foundation
import Gateway
import ModelKit
import ToolRuntime
import Tools

@MainActor
enum AgentBootstrap {
    static func makeAssistant(chat: any ChatCapability) throws -> AssistantAgent {
        try AssistantAgent(chat: chat)
    }

}

/// Process-local communication assembly, available before voice models are ready.
@MainActor
final class ApplicationRuntime {
    private static var instance: ApplicationRuntime?
    static func shared() throws -> ApplicationRuntime {
        if let instance { return instance }
        let runtime = try ApplicationRuntime()
        instance = runtime
        return runtime
    }
    let manager: AgentManager
    let input: InputGateway
    let output: OutputGateway
    let bus: InternalSignalBus
    let presentation: RuntimePresentation
    private let tools: ToolRegistry
    private var toolSetup: Task<Void, Error>?

    private init() throws {
        let policy = try CommunicationPolicy(
            configurations: ["Assistant", "SpeechPerception", "VisionPerception", "Photographer"].map {
                try AgentConfigurations.load(named: $0)
            })
        let manager = AgentManager()
        let input = InputGateway(manager: manager, policy: policy)
        let bus = InternalSignalBus { value, target, incarnation in
            try await input.receiveInternal(value, target: target, incarnation: incarnation)
        }
        let presentation = RuntimePresentation()
        let actions = ChannelScheduler(
            registry: ActionRegistry(handlers: [
                ActionPath(module: "Speech", function: "speak"): { try await presentation.speak($0) },
                ActionPath(module: "UI", function: "print"): { try await presentation.printText($0) },
                ActionPath(module: "UI", function: "express"): { try await presentation.express($0) },
                ActionPath(module: "UI", function: "showPose"): { try await presentation.showPose($0) },
            ]))
        let tools = ToolRegistry()
        self.manager = manager
        self.input = input
        self.bus = bus
        self.presentation = presentation
        self.tools = tools
        output = OutputGateway(
            manager: manager, requests: input, tools: tools, actions: actions, policy: policy, bus: bus,
            observedContracts: ["speech.partial", "speech.final", "speech.phase"],
            observeEvent: { try await presentation.observe($0) }, sink: { await presentation.output($0) })
    }
    func prepareTools() async throws {
        if toolSetup == nil {
            toolSetup = Task { [tools] in
                try await tools.register("System.runtimeInfo") { try await SystemTools.runtimeInfo($0) }
            }
        }
        try await toolSetup?.value
    }
}

/// One endpoint per scene role, with weak UI captures supplied by coordinators.
@MainActor
final class RuntimePresentation {
    var synthesis: (any SpeechSynthesisCapability)?
    var play: (@Sendable (AudioFrame, ActionInvocation) async throws -> Void)?
    var text: (@Sendable (String, ActionInvocation) async throws -> Void)?
    var emotion: (@Sendable (String, ActionInvocation) async throws -> Void)?
    var pose: (@Sendable (PoseOverlay, ActionInvocation) async throws -> Void)?
    var speech: (@Sendable (AgentInput) async throws -> Void)?
    var control: (@Sendable (OutputEnvelope) async -> Void)?
    func speak(_ invocation: ActionInvocation) async throws {
        guard let synthesis, let play else { throw CommunicationError.scopeClosed }
        try await SpeechActions.speak(invocation: invocation, synthesis: synthesis, play: play)
    }
    func printText(_ invocation: ActionInvocation) async throws {
        guard let text else { throw CommunicationError.scopeClosed }
        try await UIActions.print(invocation: invocation, present: text)
    }
    func express(_ invocation: ActionInvocation) async throws {
        guard let emotion else { throw CommunicationError.scopeClosed }
        try await UIActions.express(invocation: invocation, present: emotion)
    }
    func showPose(_ invocation: ActionInvocation) async throws {
        guard let pose else { throw CommunicationError.scopeClosed }
        try await UIActions.showPose(invocation: invocation, present: pose)
    }
    func observe(_ input: AgentInput) async throws {
        guard let speech else { throw CommunicationError.scopeClosed }
        try await speech(input)
    }
    func output(_ envelope: OutputEnvelope) async { await control?(envelope) }
}

import AgentCore
import Foundation
import StorageChat
import StorageCore

@testable import Agents

/// Test-only transport bridge: production Agents emit communication Actions exclusively.
private enum FixtureCommunicationStreams {
    static let lock = NSLock()
    private final class Entry {
        weak var agent: (any Agent)?
        let stream: AsyncStream<OutputEnvelope>
        init(agent: any Agent, stream: AsyncStream<OutputEnvelope>) {
            self.agent = agent
            self.stream = stream
        }
    }
    nonisolated(unsafe) private static var streams: [ObjectIdentifier: Entry] = [:]
    static func bind(_ agent: any Agent, port: AgentMessaging) async throws {
        let key = ObjectIdentifier(agent)
        let stream = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(4096))
        try lock.withLock {
            streams = streams.filter { $0.value.agent != nil }
            guard streams[key]?.agent == nil else { throw HarnessError.invalidTransition }
            streams[key] = Entry(agent: agent, stream: stream.stream)
        }
        try await agent.bindMessaging(port)
        Task {
            await withTaskGroup(of: Void.self) { group in
                var active = 0
                for await output in agent.outputs {
                    if case .communication(let action) = output.output {
                        if active == 16 {
                            await group.next()
                            active -= 1
                        }
                        active += 1
                        group.addTask {
                            let parent = AgentInput(
                                id: output.inputID, sessionID: output.sessionID,
                                payload: .observation(action.message), metadata: output.inputMetadata, turn: output.turn
                            )
                            let report: DeliveryReport
                            do {
                                if let target = action.target {
                                    report = try await port.sendResult(action.message, parent: parent, to: target)
                                } else {
                                    try await port.publish(action.message, parent: parent)
                                    return
                                }
                            } catch {
                                report = DeliveryReport(failure: String(describing: error))
                            }

                        }
                    } else {
                        guard case .enqueued = stream.continuation.yield(output) else { break }
                    }
                }
                group.cancelAll()
            }
            stream.continuation.finish()
        }
    }
    static func outputs(_ agent: any Agent) -> AsyncStream<OutputEnvelope> {
        lock.withLock {
            streams[ObjectIdentifier(agent)]?.agent == nil
                ? agent.outputs : (streams[ObjectIdentifier(agent)]?.stream ?? agent.outputs)
        }
    }
}

func bindFixtureCommunications(_ agent: any Agent, port: AgentMessaging) async throws {
    try await FixtureCommunicationStreams.bind(agent, port: port)
}

func fixtureOutputs(_ agent: any Agent) -> AsyncStream<OutputEnvelope> { FixtureCommunicationStreams.outputs(agent) }
extension AssistantChatWorker {
    func bind(_ port: AgentMessaging) async throws {
        if speechOutput == nil { try bindSpeechOutput(SpeechRequestProbe()) }
        try await FixtureCommunicationStreams.bind(self, port: port)
    }
}
extension SpeechPerceptionAgent {
    func bind(_ port: AgentMessaging) async throws { try await FixtureCommunicationStreams.bind(self, port: port) }
}
extension VisionPerceptionAgent {
    func bind(_ port: AgentMessaging) async throws { try await FixtureCommunicationStreams.bind(self, port: port) }
}

/// Explicit synthetic native-call role; its fixture catalog is independent of production Skill loading.
struct FixtureNativeChatState: AssistantChatState {
    static func sessionControl(_ message: AgentMessage) throws -> AssistantChatControl? {
        try AssistantContextState.sessionControl(message)
    }
    static let agentID = AgentID.assistant
    static let configurationName = "Assistant"
    static func runtimeCapabilities(_ capabilities: CapabilityRegistry) throws -> CapabilityRegistry {
        let fixture =
            capabilities.actions.allSatisfy { $0.path.domain == "Agent" && $0.path.module == "Task" }
            ? try AgentSkillLoader.registry(["basic-interaction"], fixed: capabilities) : capabilities
        let native = try CapabilityRegistry(
            actions: fixture.actions, tools: fixture.tools + [fixtureRuntimeTool()],
            channels: fixture.channels,
            internalActions: fixture.internalActions, internalTools: fixture.internalTools,
            supportsWait: fixture.supportsWait)
        return try AssistantAgent.runtimeCapabilities(native)
    }
    static func preprocess(_ input: AgentInput, state: Self) throws -> SignalDisposition {
        switch input.payload {
        case .actionResult, .toolResult, .executionFeedback: return .feedback
        default: return .enqueue(priority: 0)
        }
    }
    static func systemPrompt(_ capabilities: CapabilityRegistry) throws -> String {
        try AssistantAgent.systemPrompt(capabilities: capabilities)
    }
    var history = AssistantArchive()
    var admissionSequence: UInt64 = 0
    var taskViews: [String: AgentTaskView]?
    init() {}
    func validateContextState() throws { try validateChatState() }
    mutating func recoverInterruptedWork() { recoverChatState() }
}

typealias FixtureNativeAgent = AssistantChatWorker<FixtureNativeChatState>

func fixtureRuntimeTool() throws -> ToolRegistration {
    let definition = try JSONDecoder().decode(
        NativeToolDefinition.self,
        from: Data(
            #"{"type":"function","function":{"name":"runtimeInfo","description":"Synthetic native result fixture","parameters":{"type":"object","properties":{},"required":[],"additionalProperties":false},"strict":true}}"#
                .utf8))
    return ToolRegistration(alias: "runtimeInfo", path: "System.Runtime.runtimeInfo", definition: definition)
}

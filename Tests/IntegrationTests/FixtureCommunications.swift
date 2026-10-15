import AgentCore
import Agents
import Foundation
import Storage
import StorageChat

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
    static func bind(_ agent: any Agent, port: AgentMessaging) throws {
        let key = ObjectIdentifier(agent)
        let stream = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(4096))
        try lock.withLock {
            streams = streams.filter { $0.value.agent != nil }
            guard streams[key]?.agent == nil else { throw HarnessError.invalidTransition }
            streams[key] = Entry(agent: agent, stream: stream.stream)
        }
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
                            let receipt = CommunicationReceipt(
                                callID: action.id, report: report,
                                owner: ExecutionOwner(
                                    agent: output.source, incarnation: UUID().uuidString,
                                    sessionID: output.sessionID),
                                causality: SignalCausality(envelope: output))
                            let payload = InputPayload.communicationReceipt(receipt)
                            do {
                                try await agent.receive(
                                    AgentInput(
                                        id: UUID().uuidString,
                                        sessionID: output.sessionID, payload: payload,
                                        metadata: InputMetadata(
                                            payload: payload, source: "runtime", origin: .runtime,
                                            rootID: UUID().uuidString)))
                            } catch {}
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

func bindFixtureCommunications(_ agent: any Agent, port: AgentMessaging) throws {
    try FixtureCommunicationStreams.bind(agent, port: port)
}

func fixtureOutputs(_ agent: any Agent) -> AsyncStream<OutputEnvelope> { FixtureCommunicationStreams.outputs(agent) }
extension AgentChatWorker {
    func bind(_ port: AgentMessaging) throws { try FixtureCommunicationStreams.bind(self, port: port) }
}
extension SpeechPerceptionAgent {
    func bind(_ port: AgentMessaging) throws { try FixtureCommunicationStreams.bind(self, port: port) }
}
extension VisionPerceptionAgent {
    func bind(_ port: AgentMessaging) throws { try FixtureCommunicationStreams.bind(self, port: port) }
}

/// Explicit synthetic native-call role; its fixture catalog is independent of production Skill loading.
struct FixtureNativeChatState: AgentChatContextState {
    static let agentID = AgentID.assistant
    static let configurationName = "Assistant"
    static func runtimeCapabilities(_ capabilities: CapabilityRegistry) throws -> CapabilityRegistry {
        let fixture =
            capabilities.actions.allSatisfy { $0.path.domain == "Agent" && $0.path.module == "Task" }
            ? try AgentSkillLoader.registry(["expression-interaction"], fixed: capabilities) : capabilities
        let native = try CapabilityRegistry(
            actions: fixture.actions, tools: fixture.tools + [fixtureRuntimeTool()],
            channels: fixture.channels,
            internalActions: fixture.internalActions, internalTools: fixture.internalTools)
        return try AssistantAgent.runtimeCapabilities(native)
    }
    static func preprocess(_ input: AgentInput, state: Self) throws -> SignalDisposition {
        switch input.payload {
        case .communicationReceipt, .actionResult, .toolResult, .roundResult: return .feedback
        default: return .enqueue(priority: 0)
        }
    }
    static func systemPrompt(_ capabilities: CapabilityRegistry) throws -> String {
        try AssistantAgent.systemPrompt(capabilities: capabilities)
    }
    var history = ConversationArchive()
    var admissionSequence: UInt64 = 0
    var taskViews: [String: AgentTaskView]?
    init() {}
    func validateContextState() throws { try validateChatState() }
    mutating func recoverInterruptedWork() { recoverChatState() }
}

typealias FixtureNativeAgent = AgentChatWorker<FixtureNativeChatState>

func fixtureRuntimeTool() throws -> ToolRegistration {
    let definition = try JSONDecoder().decode(
        NativeToolDefinition.self,
        from: Data(
            #"{"type":"function","function":{"name":"runtimeInfo","description":"Synthetic native result fixture","parameters":{"type":"object","properties":{},"required":[],"additionalProperties":false},"strict":true}}"#
                .utf8))
    return ToolRegistration(alias: "runtimeInfo", path: "System.Runtime.runtimeInfo", definition: definition)
}

/// Communication protocol tests explicitly opt in; production BasicSkill does not grant send.
func fixtureCatalogWithCommunication(_ base: CapabilityRegistry) throws -> CapabilityRegistry {
    let bindings = try JSONDecoder().decode(
        [AgentConfigurations.Binding].self,
        from: Data(
            """
            [{"path":"Agent.Communication.send","callType":"action","alias":"send","channel":"Communication"}]
            """.utf8))
    let communication = try AgentConfigurations.registry(bindings)
    return try CapabilityRegistry(
        actions: base.actions.filter { $0.path.description != "Agent.Communication.send" } + communication.actions,
        tools: base.tools, channels: base.channels, internalActions: base.internalActions,
        internalTools: base.internalTools)
}

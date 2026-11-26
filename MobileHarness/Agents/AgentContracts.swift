import AgentCore
import Foundation
import FunctionContracts
import StorageCore

/// Application Agent names; the framework only defines the identity value type.
extension AgentID {
    public static let speechPerception = AgentID(rawValue: "speechPerception")
    public static let visionPerception = AgentID(rawValue: "visionPerception")
    public static let photographer = AgentID(rawValue: "photographer")
    public static let writer = AgentID(rawValue: "writer")
    public static let memory = AgentID(rawValue: "memory")
    public static let applicationControl = AgentID(rawValue: "applicationControl")
    public static let assistant = AgentID(rawValue: "assistant")
}
/// Business communication schemas and freshness policy, assembled into the generic registry.
public enum AgentContracts {
    /// Role-owned local implementations are assembled here, never discovered by shared loaders.
    public static var localTools: [AgentLocalTool] {
        WriterLocalTools.declarations.map { AgentLocalTool(owner: .writer, declaration: $0) }
    }
    public static var localToolPaths: Set<String> {
        Set(localTools.map { $0.declaration.path.description })
    }

    public static var communication: CommunicationContracts {
        get throws {
            try CommunicationContracts(
                additional: [
                    CommunicationContract(
                        name: AssistantInterrupt.contract, kind: .observation, channel: "agent.interruption",
                        maximumBytes: 1024,
                        validateMessage: { message in
                            guard message.content(as: AssistantInterrupt.self) != nil else {
                                throw CommunicationError.invalidPayload
                            }
                        }),
                    CommunicationContract(
                        name: AgentTaskRequest.contract, kind: .observation, maximumBytes: 32768, startsNewWork: true,
                        validateMessage: { message in
                            if let query = message.content(as: AgentTaskQuery.self) {
                                try query.message().validate()
                                return
                            }
                            if let value = message.content(as: AgentTaskRequest.self) {
                                try value.validate()
                                return
                            }
                            guard let value = message.content(as: AgentTaskSignal.self),
                                [.request, .input, .cancel].contains(value.kind)
                            else { throw CommunicationError.invalidPayload }
                            try value.validate()
                        }),
                    CommunicationContract(
                        name: AgentTaskResponse.contract, kind: .observation, channel: "agent.task",
                        maximumBytes: 131072, startsNewWork: true,
                        validateMessage: { message in
                            if let response = message.content(as: AgentTaskResponse.self) {
                                try response.validate()
                                if let signal = response.signal {
                                    guard message.eventScope == signal.scope.id else {
                                        throw CommunicationError.invalidPayload
                                    }
                                } else {
                                    guard message.eventScope.flatMap({ UUID(uuidString: $0) }) != nil else {
                                        throw CommunicationError.invalidPayload
                                    }
                                }
                                return
                            }
                            guard let signal = message.content(as: AgentTaskSignal.self),
                                signal.kind == .progress || signal.kind == .result
                            else {
                                throw CommunicationError.invalidPayload
                            }
                            try signal.validate()
                            guard message.eventScope == signal.scope.id else { throw CommunicationError.invalidPayload }
                        }),
                    contract(
                        PerceptionMessage.speechProtocol, channel: "user.input.speech", events: ["partial", "final"]),
                    CommunicationContract(
                        name: SpeechActivity.contract, kind: .observation, channel: SpeechActivity.channel,
                        events: Set(SpeechActivity.Kind.allCases.map(\.rawValue)), maximumBytes: 1024,
                        validateMessage: { message in
                            guard let value = message.content(as: SpeechActivity.self),
                                message.event == value.kind.rawValue
                            else { throw CommunicationError.invalidPayload }
                        }),
                    CommunicationContract(
                        name: ReplyActivitySignal.contract, kind: .observation, channel: ReplyActivitySignal.channel,
                        maximumBytes: ReplyActivitySignal.maximumBytes,
                        validateMessage: { message in
                            guard let activity = message.content(as: ReplyActivitySignal.self) else {
                                throw CommunicationError.invalidPayload
                            }
                            try activity.validate()
                        }),
                    CommunicationContract(
                        name: ListeningModeSignal.contract, kind: .observation, channel: ListeningModeSignal.channel,
                        maximumBytes: 256,
                        validateMessage: { message in
                            guard message.content(as: ListeningModeSignal.self) != nil else {
                                throw CommunicationError.invalidPayload
                            }
                        }),
                    contract("perception.audio.source.v1", channel: "perception.audio.source"),
                    contract("perception.vision.pose.v1", channel: "perception.vision.pose", maximumBytes: 262_144),
                ])
        }
    }
    private static func contract(
        _ name: String, channel: String, events: Set<String> = [], maximumBytes: Int = 16_384,
        startsNewWork: Bool = false
    ) -> CommunicationContract {
        CommunicationContract(
            name: name, kind: .observation, channel: channel, events: events, maximumBytes: maximumBytes,
            startsNewWork: startsNewWork,
            validateMessage: { message in
                guard let value = message.perception, value.contract == name else {
                    throw CommunicationError.invalidPayload
                }
                try value.validate()
            })
    }
}

extension AgentContracts {
    public static var requestImplementations: [AgentID: [AgentRequestImplementation]] {
        let operations = Set(AgentRequestOperation.allCases)
        return [
            .writer: [
                .init(
                    protocolID: "agent.task.v1", role: WriterAgent.self, operations: operations,
                    acceptsTextSubmission: true,
                    handler: { try await $0.receiveRequest($1) })
            ],
            .memory: [
                .init(
                    protocolID: "agent.task.v1", role: MemoryAgent.self, operations: operations,
                    handler: { try await $0.receiveRequest($1) })
            ],
            .photographer: [
                .init(
                    protocolID: "agent.task.v1", role: PhotographerAgent.self, operations: operations,
                    handler: { try await $0.receiveRequest($1) })
            ],
            .applicationControl: [
                .init(
                    protocolID: "agent.task.v1", role: ApplicationControlAgent.self, operations: operations,
                    handler: { try await $0.receiveRequest($1) })
            ],
        ]
    }
    public static func validateProtocols(
        _ configuration: AgentConfiguration,
        implementations: [AgentRequestImplementation]? = nil
    ) throws {
        let registrations = implementations ?? requestImplementations[configuration.agentID] ?? []
        for (index, protocolID) in configuration.communication.requests.enumerated() {
            let matches = registrations.filter { $0.protocolID == protocolID }
            guard matches.count == 1 else {
                throw AgentProtocolStartupError(
                    agentID: configuration.agentID, field: "signals.requests[\(index)]",
                    protocolID: protocolID, reason: matches.isEmpty ? .missingHandler : .schemaMismatch)
            }
            guard Set(AgentRequestOperation.allCases).isSubset(of: matches[0].operations) else {
                throw AgentProtocolStartupError(
                    agentID: configuration.agentID, field: "signals.requests[\(index)]",
                    protocolID: protocolID, reason: .missingRequiredOperation)
            }
        }
        try validateEventImplementations(configuration)
        let knownRoles: Set<AgentID> = [
            .assistant, .writer, .memory, .photographer, .applicationControl, .speechPerception, .visionPerception,
        ]
        for protocolID in configuration.communication.feedback {
            guard knownRoles.contains(configuration.agentID),
                protocolID != ExecutionFeedback.contract || configuration.agentID == .assistant
            else {
                throw AgentProtocolStartupError(
                    agentID: configuration.agentID, field: "signals.feedback", protocolID: protocolID,
                    reason: .missingHandler)
            }
        }
    }
}

extension AgentContracts {
    /// Low-rate, latency-sensitive facts that bypass ordinary input capacity limits.
    static func isControlContract(_ contract: String) -> Bool {
        [
            AssistantInterrupt.contract, SpeechActivity.contract, ListeningModeSignal.contract,
            ReplyActivitySignal.contract,
        ].contains(contract)
    }
    public static var eventImplementations: [AgentID: [AgentEventImplementation]] {
        [
            .assistant: [
                .init(
                    channel: "user.input.speech", protocolID: "user.input.speech.v1", variants: ["final"],
                    role: AssistantAgent.self, handler: { try await $0.receive($1) }),
                .init(
                    channel: SpeechActivity.channel, protocolID: SpeechActivity.contract,
                    variants: Set(SpeechActivity.Kind.allCases.map(\.rawValue)), role: AssistantAgent.self,
                    handler: { try await $0.receive($1) }),
                .init(
                    channel: "agent.interruption", protocolID: "agent.interruption.v1", role: AssistantAgent.self,
                    handler: { try await $0.receive($1) }),
                .init(
                    channel: "agent.task", protocolID: "agent.task.events.v1", role: AssistantAgent.self,
                    handler: { try await $0.receive($1) }),
            ],
            .speechPerception: [
                .init(
                    channel: ListeningModeSignal.channel, protocolID: ListeningModeSignal.contract,
                    role: SpeechPerceptionAgent.self, handler: { try await $0.receive($1) }),
                .init(
                    channel: ReplyActivitySignal.channel, protocolID: ReplyActivitySignal.contract,
                    role: SpeechPerceptionAgent.self, handler: { try await $0.receive($1) }),
            ],
            .photographer: [
                .init(
                    channel: "perception.vision.pose", protocolID: "perception.vision.pose.v1",
                    role: PhotographerAgent.self, handler: { try await $0.receive($1) })
            ],
        ]
    }
    private static var publicationImplementations: [AgentID: Set<String>] {
        [
            .speechPerception: [
                "user.input.speech.v1", SpeechActivity.contract, "perception.audio.source.v1",
                AssistantInterrupt.contract,
            ],
            .visionPerception: ["perception.vision.pose.v1"],
            .applicationControl: ["agent.interruption.v1", "agent.task.events.v1"],
            .assistant: ["agent.task.events.v1", "agent.listening.mode.v1", "agent.reply.activity.v1"],
            .writer: ["agent.task.events.v1"],
            .memory: ["agent.task.events.v1"], .photographer: ["agent.task.events.v1"],
        ]
    }
    static func validateEventImplementations(_ configuration: AgentConfiguration) throws {
        for (index, subscription) in configuration.communication.subscriptions.enumerated() {
            let implementations = eventImplementations[configuration.agentID, default: []].filter {
                $0.channel == subscription.channel && $0.protocolID == subscription.protocol
            }
            guard implementations.count == 1 else {
                throw AgentProtocolStartupError(
                    agentID: configuration.agentID, field: "signals.subscriptions[\(index)]",
                    protocolID: subscription.protocol, reason: .missingHandler)
            }
            let contracts = try communication
            let required = Set(subscription.events ?? contracts[subscription.protocol]?.events.sorted() ?? [])
            guard required.isSubset(of: implementations[0].variants) else {
                throw AgentProtocolStartupError(
                    agentID: configuration.agentID, field: "signals.subscriptions[\(index)].events",
                    protocolID: subscription.protocol, reason: .missingRequiredOperation)
            }
        }
        for (index, publication) in configuration.communication.publications.enumerated() {
            guard publicationImplementations[configuration.agentID, default: []].contains(publication.protocol) else {
                throw AgentProtocolStartupError(
                    agentID: configuration.agentID, field: "signals.publications[\(index)]",
                    protocolID: publication.protocol, reason: .missingHandler)
            }
        }
    }
}

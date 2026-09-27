import Foundation

public enum CommunicationError: Error, Equatable, Sendable {
    case unauthorized, unsupportedContract, invalidPayload, unknownTarget, unavailableTarget, noRecipients
    case capacityExceeded, expired, scopeClosed, staleIncarnation, outOfOrder, hopLimitExceeded
}

public struct CommunicationDeclaration: Codable, Sendable {
    public struct Input: Codable, Hashable, Sendable {
        public let contract: String
        public let version: Int
        public let kind: InputKind
    }
    public struct Subscription: Codable, Hashable, Sendable {
        public let contract: String
        public let source: String
        public let topic: String
    }
    public struct SendPermission: Codable, Hashable, Sendable {
        public let contract: String
        public let target: String
    }
    public let inputs: [Input]
    public let subscriptions: [Subscription]
    public let publications: [String]
    public let sends: [SendPermission]
    public static let empty = CommunicationDeclaration(inputs: [], subscriptions: [], publications: [], sends: [])

    public static let contracts: [String: InputKind] = [
        "user.text": .text, "runtime.event": .event, "tool.result": .toolResult,
        "media.audio": .audio, "media.image": .image, "speech.final": .observation,
        "speech.partial": .observation, "speech.phase": .observation, "vision.pose": .observation,
    ]
    public func validate() throws {
        guard inputs.count <= 32, subscriptions.count <= 16, publications.count <= 64, sends.count <= 64,
            Set(inputs).count == inputs.count, Set(subscriptions).count == subscriptions.count,
            Set(publications).count == publications.count, Set(sends).count == sends.count,
            inputs.allSatisfy({ $0.version == 1 && Self.contracts[$0.contract] == $0.kind }),
            publications.allSatisfy({ Self.contracts[$0] == .observation }),
            subscriptions.allSatisfy({ sub in
                inputs.contains { $0.contract == sub.contract } && sub.topic == sub.contract
                    && CapabilityRegistry.validName(sub.source)
            }),
            sends.allSatisfy({ Self.contracts[$0.contract] == .observation && CapabilityRegistry.validName($0.target) })
        else { throw AgentConfigurationError.invalidField("communication") }
    }
}

public struct CommunicationPolicy: Sendable {
    public let agents: [AgentID: CommunicationDeclaration]
    public init(configurations: [AgentConfiguration]) throws {
        guard configurations.count <= 64, Set(configurations.map(\.agentID)).count == configurations.count else {
            throw CommunicationError.capacityExceeded
        }
        agents = Dictionary(uniqueKeysWithValues: configurations.map { ($0.agentID, $0.communication) })
        let externalSources: Set<String> = ["user", "phone.microphone", "phone.camera", "runtime"]
        var topics = Set<String>()
        var subscribers: [String: Int] = [:]
        for declaration in agents.values {
            try declaration.validate()
            topics.formUnion(declaration.publications)
            for sub in declaration.subscriptions {
                topics.insert(sub.topic)
                subscribers[sub.topic, default: 0] += 1
                if !externalSources.contains(sub.source) {
                    guard agents[AgentID(rawValue: sub.source)]?.publications.contains(sub.contract) == true else {
                        throw CommunicationError.unauthorized
                    }
                }
            }
            for send in declaration.sends {
                guard
                    agents[AgentID(rawValue: send.target)]?.inputs.contains(where: { $0.contract == send.contract })
                        == true
                else {
                    throw CommunicationError.unknownTarget
                }
            }
        }
        guard topics.count <= 64, subscribers.values.allSatisfy({ $0 <= 16 }) else {
            throw CommunicationError.capacityExceeded
        }
    }
    public func destinations(for input: AgentInput) -> [AgentID] {
        agents.compactMap { id, declaration in
            declaration.subscriptions.contains {
                $0.contract == input.metadata.contract && $0.topic == input.metadata.topic
                    && $0.source == input.metadata.source
            } ? id : nil
        }.sorted { $0.rawValue < $1.rawValue }
    }
    public func accepts(_ input: AgentInput, target: AgentID) -> Bool {
        agents[target]?.inputs.contains {
            $0.contract == input.metadata.contract && $0.version == input.metadata.version
                && $0.kind == input.payload.kind
        } == true
    }
}

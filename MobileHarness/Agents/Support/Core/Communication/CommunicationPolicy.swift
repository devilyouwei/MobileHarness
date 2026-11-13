import Foundation

public enum CommunicationError: Error, Equatable, Sendable {
    case unauthorized, unsupportedContract, invalidPayload, unknownTarget, unavailableTarget, noRecipients
    case capacityExceeded, expired, scopeClosed, staleIncarnation, outOfOrder, hopLimitExceeded
}

/// Registered schema and admission policy. Domain names and validators come from composition.
public struct CommunicationContract: Sendable {
    public let name: String
    public let kind: InputKind
    public let topic: String
    public let maximumBytes: Int
    public let startsNewWork: Bool
    fileprivate let validateMessage: (@Sendable (AgentMessage) throws -> Void)?
    public init(
        name: String, kind: InputKind, topic: String? = nil, maximumBytes: Int = 16_384,
        startsNewWork: Bool = false, validateMessage: (@Sendable (AgentMessage) throws -> Void)? = nil
    ) {
        self.name = name
        self.kind = kind
        self.topic = topic ?? name
        self.maximumBytes = maximumBytes
        self.startsNewWork = startsNewWork
        self.validateMessage = validateMessage
    }
}

/// Immutable capacity-128 schema registry; duplicates and invalid policy reject assembly.
public struct CommunicationContracts: Sendable {
    private let entries: [String: CommunicationContract]
    public static let standard = CommunicationContracts(standard: [
        CommunicationContract(name: "runtime.message.receipt", kind: .communicationReceipt),
        CommunicationContract(name: "runtime.tool.result", kind: .toolResult),
        CommunicationContract(name: "runtime.action.result", kind: .actionResult),
        CommunicationContract(name: "runtime.round.result", kind: .roundResult),
        CommunicationContract(name: "activity.event", kind: .activityEvent),
    ])
    private init(standard: [CommunicationContract]) {
        entries = Dictionary(uniqueKeysWithValues: standard.map { ($0.name, $0) })
    }
    public init(additional: [CommunicationContract]) throws {
        guard additional.count + Self.standard.entries.count <= 128 else {
            throw CommunicationError.capacityExceeded
        }
        var entries = Self.standard.entries
        for contract in additional {
            guard !contract.name.isEmpty, contract.name.utf8.count <= 64,
                contract.name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                    CapabilityRegistry.validName(String($0))
                }),
                !contract.topic.isEmpty, contract.topic.utf8.count <= 64,
                contract.topic.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                    CapabilityRegistry.validName(String($0))
                }),
                (1...262_144).contains(contract.maximumBytes),
                contract.kind == .observation, contract.validateMessage != nil,
                entries[contract.name] == nil
            else { throw CommunicationError.invalidPayload }
            entries[contract.name] = contract
        }
        self.entries = entries
    }
    public subscript(_ name: String) -> CommunicationContract? { entries[name] }
    public func validatedSize(_ message: AgentMessage) throws -> Int {
        guard let contract = entries[message.contract], contract.kind == .observation,
            let validate = contract.validateMessage
        else { throw CommunicationError.unsupportedContract }
        try validate(message)
        let size = try message.validatedSize()
        guard size <= contract.maximumBytes else { throw CommunicationError.invalidPayload }
        return size
    }
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

    public var inputKinds: Set<InputKind> {
        var kinds = Set(inputs.map(\.kind))
        if !subscriptions.isEmpty { kinds.insert(.observation) }
        return kinds
    }

    public func validate(contracts: CommunicationContracts = .standard) throws {
        guard inputs.count <= 32, subscriptions.count <= 16, publications.count <= 64, sends.count <= 64,
            Set(inputs).count == inputs.count, Set(subscriptions).count == subscriptions.count,
            Set(publications).count == publications.count, Set(sends).count == sends.count,
            inputs.allSatisfy({ $0.version == 1 && contracts[$0.contract]?.kind == $0.kind }),
            publications.allSatisfy({ contracts[$0]?.kind == .observation }),
            subscriptions.allSatisfy({ sub in
                contracts[sub.contract]?.kind == .observation && contracts[sub.contract]?.topic == sub.topic
                    && CapabilityRegistry.validName(sub.source)
            }),
            sends.allSatisfy({ contracts[$0.contract]?.kind == .observation && CapabilityRegistry.validName($0.target) }
            )
        else { throw AgentConfigurationError.invalidField("communication") }
    }
}

public struct CommunicationPolicy: Sendable {
    public let agents: [AgentID: CommunicationDeclaration]
    public let contracts: CommunicationContracts
    public init(
        contracts: CommunicationContracts = .standard,
        configurations: [AgentConfiguration]
    ) throws {
        self.contracts = contracts
        guard configurations.count <= 64, Set(configurations.map(\.agentID)).count == configurations.count else {
            throw CommunicationError.capacityExceeded
        }
        agents = Dictionary(uniqueKeysWithValues: configurations.map { ($0.agentID, $0.communication) })
        var topics = Set<String>()
        var subscribers: [String: Int] = [:]
        for declaration in agents.values {
            try declaration.validate(contracts: contracts)
            topics.formUnion(declaration.publications.compactMap { contracts[$0]?.topic })
            for sub in declaration.subscriptions {
                topics.insert(sub.topic)
                subscribers[sub.topic, default: 0] += 1
                guard agents[AgentID(rawValue: sub.source)]?.publications.contains(sub.contract) == true else {
                    throw CommunicationError.unauthorized
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
        agents.keys.filter { acceptsPublication(input, target: $0) }.sorted { $0.rawValue < $1.rawValue }
    }
    public func acceptsPublication(_ input: AgentInput, target: AgentID) -> Bool {
        guard let contract = contracts[input.metadata.contract], contract.kind == .observation,
            contract.kind == input.payload.kind, input.metadata.version == 1, contract.topic == input.metadata.topic
        else { return false }
        return agents[target]?.subscriptions.contains {
            $0.contract == input.metadata.contract && $0.topic == input.metadata.topic
                && $0.source == input.metadata.source
        } == true
    }
    public func accepts(_ input: AgentInput, target: AgentID) -> Bool {
        agents[target]?.inputs.contains {
            $0.contract == input.metadata.contract && $0.version == input.metadata.version
                && $0.kind == input.payload.kind
        } == true
    }
}

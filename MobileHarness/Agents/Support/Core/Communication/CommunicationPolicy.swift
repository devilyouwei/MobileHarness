import Foundation

public enum CommunicationError: Error, Equatable, Sendable {
    case unauthorized, unsupportedContract, invalidPayload, unknownTarget, unavailableTarget, noRecipients
    case capacityExceeded, expired, scopeClosed, staleIncarnation, outOfOrder, hopLimitExceeded
}

public enum SignalIdentifier {
    public static func channel(_ value: String) -> Bool { valid(value, versioned: false) }
    public static func `protocol`(_ value: String) -> Bool { valid(value, versioned: true) }
    private static func valid(_ value: String, versioned: Bool) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let semantic = versioned ? Array(parts.dropLast()) : Array(parts)
        guard value.utf8.count <= 64, (2...5).contains(semantic.count),
            semantic.allSatisfy({ part in
                guard let first = part.utf8.first, (97...122).contains(first) else { return false }
                return part.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }
            })
        else { return false }
        guard let last = parts.last else { return false }
        let version = last.dropFirst()
        let isVersion =
            last.first == "v" && !version.isEmpty && version.first != "0"
            && version.utf8.allSatisfy { (48...57).contains($0) }
        return versioned ? isVersion : !isVersion
    }
}

/// Code-owned schema. channel is explicit and only present for events.
public struct CommunicationContract: Sendable {
    public let name: String
    public let kind: InputKind
    public let channel: String?
    public let events: Set<String>
    public let maximumBytes: Int
    public let startsNewWork: Bool
    fileprivate let validateMessage: (@Sendable (AgentMessage) throws -> Void)?
    public init(
        name: String, kind: InputKind, channel: String? = nil, events: Set<String> = [], maximumBytes: Int = 16_384,
        startsNewWork: Bool = false,
        validateMessage: (@Sendable (AgentMessage) throws -> Void)? = nil
    ) {
        self.name = name
        self.kind = kind
        self.channel = channel
        self.events = events
        self.maximumBytes = maximumBytes
        self.startsNewWork = startsNewWork
        self.validateMessage = validateMessage
    }
}

public struct CommunicationContracts: Sendable {
    private let entries: [String: CommunicationContract]
    public static let standard = CommunicationContracts(standard: [
        .init(name: "action.result.v1", kind: .actionResult),
        .init(name: "agent.round.result.v1", kind: .roundResult),
    ])
    private init(standard: [CommunicationContract]) {
        entries = Dictionary(uniqueKeysWithValues: standard.map { ($0.name, $0) })
    }
    public init(additional: [CommunicationContract]) throws {
        guard additional.count + Self.standard.entries.count <= 128 else { throw CommunicationError.capacityExceeded }
        var entries = Self.standard.entries
        var channels: [String: String] = [:]
        for contract in additional {
            guard SignalIdentifier.protocol(contract.name), (1...262_144).contains(contract.maximumBytes),
                contract.kind == .observation, contract.validateMessage != nil, entries[contract.name] == nil,
                contract.channel.map(SignalIdentifier.channel) ?? contract.events.isEmpty,
                contract.events.allSatisfy({ CapabilityRegistry.validName($0) })
            else { throw CommunicationError.invalidPayload }
            if let channel = contract.channel {
                guard channels[channel] == nil || channels[channel] == contract.name else {
                    throw CommunicationError.invalidPayload
                }
                channels[channel] = contract.name
            }
            entries[contract.name] = contract
        }
        self.entries = entries
    }
    public var registered: [CommunicationContract] { entries.values.sorted { $0.name < $1.name } }
    public subscript(_ name: String) -> CommunicationContract? { entries[name] }
    public func validatedSize(_ message: AgentMessage) throws -> Int {
        guard let contract = entries[message.contract], contract.kind == .observation,
            let validate = contract.validateMessage, message.event.map({ contract.events.contains($0) }) ?? true
        else { throw CommunicationError.unsupportedContract }
        try validate(message)
        let size = try message.validatedSize()
        guard size <= contract.maximumBytes else { throw CommunicationError.invalidPayload }
        return size
    }
}

/// Only inbound protocol enablement and static event relations live in configuration.
public struct CommunicationDeclaration: Codable, Sendable {
    public struct Publication: Codable, Hashable, Sendable {
        public let channel: String
        public let `protocol`: String
        public init(channel: String, protocol: String) {
            self.channel = channel
            self.protocol = `protocol`
        }
    }
    public struct Subscription: Codable, Hashable, Sendable {
        public let channel: String
        public let `protocol`: String
        public let sources: [String]
        public let events: [String]?
        public init(channel: String, protocol: String, sources: [String], events: [String]? = nil) {
            self.channel = channel
            self.protocol = `protocol`
            self.sources = sources
            self.events = events
        }
    }
    public let requests: [String]
    public let feedback: [String]
    public let publications: [Publication]
    public let subscriptions: [Subscription]
    public init(requests: [String], feedback: [String], publications: [Publication], subscriptions: [Subscription]) {
        self.requests = requests
        self.feedback = feedback
        self.publications = publications
        self.subscriptions = subscriptions
    }
    public static let empty = CommunicationDeclaration(requests: [], feedback: [], publications: [], subscriptions: [])
    public var inputKinds: Set<InputKind> {
        // Every role has the unified entry for authenticated dynamic Task observations.
        var kinds: Set<InputKind> = [.observation]
        if feedback.contains("action.result.v1") { kinds.formUnion([.actionResult, .toolResult]) }
        if feedback.contains("agent.round.result.v1") { kinds.insert(.roundResult) }
        return kinds
    }
    public func validate(contracts: CommunicationContracts = .standard, agentID: AgentID = .init(rawValue: "unbound"))
        throws
    {
        for (index, protocolID) in requests.enumerated() where contracts[protocolID] == nil {
            throw AgentProtocolStartupError(
                agentID: agentID, field: "signals.requests[\(index)]", protocolID: protocolID, reason: .unknownProtocol)
        }
        for (index, protocolID) in feedback.enumerated() where contracts[protocolID] == nil {
            throw AgentProtocolStartupError(
                agentID: agentID, field: "signals.feedback[\(index)]", protocolID: protocolID, reason: .unknownProtocol)
        }
        guard requests.count <= 32, feedback.count <= 16, publications.count <= 64, subscriptions.count <= 16,
            Set(requests).count == requests.count, Set(feedback).count == feedback.count,
            Set(publications).count == publications.count, Set(subscriptions).count == subscriptions.count,
            requests.allSatisfy({
                SignalIdentifier.protocol($0) && contracts[$0]?.kind == .observation && contracts[$0]?.channel == nil
            }),
            feedback.allSatisfy({ ["action.result.v1", "agent.round.result.v1"].contains($0) && contracts[$0] != nil }),
            publications.allSatisfy({
                SignalIdentifier.channel($0.channel) && contracts[$0.protocol]?.channel == $0.channel
            }),
            subscriptions.allSatisfy({ sub in
                SignalIdentifier.channel(sub.channel) && contracts[sub.protocol]?.channel == sub.channel
                    && !sub.sources.isEmpty && sub.sources.count <= 16 && Set(sub.sources).count == sub.sources.count
                    && sub.sources.allSatisfy(CapabilityRegistry.validName)
                    && (sub.events.map {
                        !$0.isEmpty && Set($0).count == $0.count
                            && Set($0).isSubset(of: contracts[sub.protocol]?.events ?? [])
                    } ?? true)
            })
        else { throw AgentConfigurationError.invalidField("signals") }
        for (index, sub) in subscriptions.enumerated() {
            guard
                !subscriptions[..<index].contains(where: {
                    $0.channel == sub.channel && !Set($0.sources).isDisjoint(with: sub.sources)
                })
            else { throw AgentConfigurationError.invalidField("signals.subscriptions.overlap") }
        }
    }
}

public struct CommunicationPolicy: Sendable {
    public let agents: [AgentID: CommunicationDeclaration]
    public let contracts: CommunicationContracts
    public init(contracts: CommunicationContracts = .standard, configurations: [AgentConfiguration]) throws {
        self.contracts = contracts
        guard configurations.count <= 64, Set(configurations.map(\.agentID)).count == configurations.count else {
            throw CommunicationError.capacityExceeded
        }
        agents = Dictionary(uniqueKeysWithValues: configurations.map { ($0.agentID, $0.communication) })
        var channels = Set<String>()
        var subscribers: [String: Int] = [:]
        for declaration in agents.values {
            try declaration.validate(contracts: contracts)
            channels.formUnion(declaration.publications.map(\.channel))
            for sub in declaration.subscriptions {
                channels.insert(sub.channel)
                subscribers[sub.channel, default: 0] += 1
                for source in sub.sources {
                    guard
                        agents[AgentID(rawValue: source)]?.publications.contains(where: {
                            $0.channel == sub.channel && $0.protocol == sub.protocol
                        }) == true
                    else { throw CommunicationError.unauthorized }
                }
            }
        }
        guard channels.count <= 64, subscribers.values.allSatisfy({ $0 <= 16 }) else {
            throw CommunicationError.capacityExceeded
        }
    }
    public func destinations(for input: AgentInput) -> [AgentID] {
        agents.keys.filter { acceptsPublication(input, target: $0) }.sorted { $0.rawValue < $1.rawValue }
    }
    public func acceptsPublication(_ input: AgentInput, target: AgentID) -> Bool {
        guard let contract = contracts[input.metadata.contract], contract.kind == .observation,
            input.payload.kind == .observation, input.metadata.version == 1, contract.channel == input.metadata.topic,
            case .observation(let message) = input.payload
        else { return false }
        return agents[target]?.subscriptions.contains {
            $0.protocol == input.metadata.contract && $0.channel == input.metadata.topic
                && $0.sources.contains(input.metadata.source)
                && ($0.events.map { events in message.event.map(events.contains) ?? false } ?? true)
        } == true
    }
    public func accepts(_ input: AgentInput, target: AgentID) -> Bool {
        guard input.metadata.version == 1, let declaration = agents[target] else { return false }
        switch input.payload.kind {
        case .actionResult, .toolResult: return declaration.feedback.contains("action.result.v1")
        case .roundResult: return declaration.feedback.contains("agent.round.result.v1")
        case .activityEvent: return input.metadata.origin == .runtime
        case .observation:
            // Host feedback is authenticated by its execution-owner delivery port.
            // Agent publications use broker subscriptions, independently of request admission.
            return input.metadata.origin == .runtime || declaration.requests.contains(input.metadata.contract)
        default: return false
        }
    }
}

private struct SignalFieldKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func checkSignalFields(_ decoder: any Decoder, required: Set<String>, optional: Set<String> = []) throws {
    let actual = Set(try decoder.container(keyedBy: SignalFieldKey.self).allKeys.map(\.stringValue))
    guard required.isSubset(of: actual), actual.isSubset(of: required.union(optional)) else {
        throw AgentConfigurationError.invalidField("signals.fields")
    }
}
extension CommunicationDeclaration {
    public init(from decoder: any Decoder) throws {
        try checkSignalFields(decoder, required: ["requests", "feedback", "publications", "subscriptions"])
        struct Fields: Decodable {
            let requests: [String]
            let feedback: [String]
            let publications: [Publication]
            let subscriptions: [Subscription]
        }
        let fields = try Fields(from: decoder)
        self.init(
            requests: fields.requests, feedback: fields.feedback, publications: fields.publications,
            subscriptions: fields.subscriptions)
    }
}
extension CommunicationDeclaration.Publication {
    public init(from decoder: any Decoder) throws {
        try checkSignalFields(decoder, required: ["channel", "protocol"])
        struct Fields: Decodable {
            let channel: String
            let `protocol`: String
        }
        let fields = try Fields(from: decoder)
        self.init(channel: fields.channel, protocol: fields.protocol)
    }
}
extension CommunicationDeclaration.Subscription {
    public init(from decoder: any Decoder) throws {
        try checkSignalFields(decoder, required: ["channel", "protocol", "sources"], optional: ["events"])
        struct Fields: Decodable {
            let channel: String
            let `protocol`: String
            let sources: [String]
            let events: [String]?
        }
        let fields = try Fields(from: decoder)
        self.init(channel: fields.channel, protocol: fields.protocol, sources: fields.sources, events: fields.events)
    }
}

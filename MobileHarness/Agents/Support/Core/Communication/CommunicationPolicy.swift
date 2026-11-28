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

/// Code owns signal schemas. Transport names are assigned by role configuration.
public struct CommunicationContract: Sendable {
    public let name: String
    public let kind: InputKind
    public let isPublication: Bool
    public let events: Set<String>
    public let maximumBytes: Int
    public let startsNewWork: Bool
    fileprivate let validateMessage: (@Sendable (AgentMessage) throws -> Void)?
    public init(
        name: String, kind: InputKind, isPublication: Bool = false, events: Set<String> = [],
        maximumBytes: Int = 16_384,
        startsNewWork: Bool = false,
        validateMessage: (@Sendable (AgentMessage) throws -> Void)? = nil
    ) {
        self.name = name
        self.kind = kind
        self.isPublication = isPublication
        self.events = events
        self.maximumBytes = maximumBytes
        self.startsNewWork = startsNewWork
        self.validateMessage = validateMessage
    }
}

public struct CommunicationContracts: Sendable {
    private let entries: [String: CommunicationContract]
    public static let runtimeDelivery = "runtime.delivery.v1"
    public static let standard = CommunicationContracts(standard: [
        .init(name: runtimeDelivery, kind: .event),
        .init(name: ExecutionFeedback.actionResultContract, kind: .actionResult),
        .init(name: ExecutionFeedback.toolResultContract, kind: .toolResult),
        .init(name: ExecutionFeedback.controlResultContract, kind: .executionFeedback),
        .init(name: ExecutionFeedback.contract, kind: .executionFeedback),
    ])
    private init(standard: [CommunicationContract]) {
        entries = Dictionary(uniqueKeysWithValues: standard.map { ($0.name, $0) })
    }
    public init(additional: [CommunicationContract]) throws {
        guard additional.count + Self.standard.entries.count <= 128 else { throw CommunicationError.capacityExceeded }
        var entries = Self.standard.entries
        for contract in additional {
            guard SignalIdentifier.protocol(contract.name), (1...262_144).contains(contract.maximumBytes),
                contract.kind == .observation, contract.validateMessage != nil, entries[contract.name] == nil,
                contract.isPublication || contract.events.isEmpty,
                contract.events.allSatisfy({ CapabilityRegistry.validName($0) })
            else { throw CommunicationError.invalidPayload }
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

/// The dictionary key identifies the signal schema; name selects the transport channel.
public struct AgentChannelBinding: Decodable, Sendable {
    public enum Kind: String, Decodable, Sendable { case send, pubSub }
    public let type: Kind
    public let name: String
    let receive: Bool?
    let publish: Bool?
    let sources: [String]?
    let events: [String]?
    enum CodingKeys: String, CodingKey { case type, name, receive, publish, sources, events }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        type = try fields.decode(Kind.self, forKey: .type)
        try checkSignalFields(
            decoder, required: ["type", "name"],
            optional: type == .send ? ["receive"] : ["publish", "sources", "events"])
        name = try fields.decode(String.self, forKey: .name)
        receive = try fields.decodeIfPresent(Bool.self, forKey: .receive)
        publish = try fields.decodeIfPresent(Bool.self, forKey: .publish)
        sources = try fields.decodeIfPresent([String].self, forKey: .sources)
        events = try fields.decodeIfPresent([String].self, forKey: .events)
        guard SignalIdentifier.channel(name), events == nil || sources != nil else {
            throw AgentConfigurationError.invalidField("channels")
        }
    }
}

/// Only inbound protocol enablement and static event relations live in configuration.
public struct CommunicationDeclaration: Decodable, Sendable {
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
    public let eventChannels: [String: String]
    public let sendChannels: [String: String]
    public var publicationChannels: [String: String] {
        Dictionary(publications.map { ($0.protocol, $0.channel) }, uniquingKeysWith: { first, _ in first })
    }
    public let requests: [String]
    public let feedback: [String]
    public let publications: [Publication]
    public let subscriptions: [Subscription]
    public init(
        requests: [String], feedback: [String], publications: [Publication], subscriptions: [Subscription],
        sendChannels: [String: String]? = nil, eventChannels: [String: String]? = nil
    ) {
        self.eventChannels =
            eventChannels
            ?? Dictionary(
                publications.map { ($0.protocol, $0.channel) } + subscriptions.map { ($0.protocol, $0.channel) },
                uniquingKeysWith: { first, _ in first })
        self.sendChannels =
            sendChannels ?? Dictionary(requests.map { ($0, $0) }, uniquingKeysWith: { first, _ in first })
        self.requests = requests
        self.feedback = feedback
        self.publications = publications
        self.subscriptions = subscriptions
    }
    public init(channels: [String: AgentChannelBinding], feedback: [String], contracts: CommunicationContracts) throws {
        var sends: [String: String] = [:]
        var requests: [String] = []
        var publications: [Publication] = []
        var subscriptions: [Subscription] = []
        for (key, binding) in channels.sorted(by: { $0.key < $1.key }) {
            guard let contract = contracts[key],
                contract.kind == .observation || key == CommunicationContracts.runtimeDelivery,
                contract.isPublication == (binding.type == .pubSub)
            else {
                throw AgentConfigurationError.invalidField("channels." + key)
            }
            switch binding.type {
            case .send:
                sends[key] = binding.name
                if key == CommunicationContracts.runtimeDelivery {
                    guard binding.receive == true else { throw AgentConfigurationError.invalidField("channels." + key) }
                } else if binding.receive == true {
                    requests.append(key)
                }
            case .pubSub:
                if binding.publish == true { publications.append(.init(channel: binding.name, protocol: key)) }
                if let sources = binding.sources {
                    subscriptions.append(
                        .init(channel: binding.name, protocol: key, sources: sources, events: binding.events))
                }
            }
        }
        self.init(
            requests: requests, feedback: feedback, publications: publications,
            subscriptions: subscriptions, sendChannels: sends,
            eventChannels: channels.filter { $0.value.type == .pubSub }.mapValues(\.name))
    }
    public static let empty = CommunicationDeclaration(requests: [], feedback: [], publications: [], subscriptions: [])
    public var inputKinds: Set<InputKind> {
        // Every role has the unified entry for authenticated dynamic Task observations.
        var kinds: Set<InputKind> = [.observation]
        if feedback.contains(ExecutionFeedback.actionResultContract) {
            kinds.insert(.actionResult)
        }
        if feedback.contains(ExecutionFeedback.toolResultContract) { kinds.insert(.toolResult) }
        if feedback.contains(ExecutionFeedback.contract) || feedback.contains(ExecutionFeedback.controlResultContract) {
            kinds.insert(.executionFeedback)
        }
        return kinds
    }
    public func validate(contracts: CommunicationContracts = .standard, agentID: AgentID = .init(rawValue: "unbound"))
        throws
    {
        for protocolID in requests where contracts[protocolID] == nil {
            throw AgentProtocolStartupError(
                agentID: agentID, field: "channels." + protocolID, protocolID: protocolID, reason: .unknownProtocol)
        }
        for (index, protocolID) in feedback.enumerated() where contracts[protocolID] == nil {
            throw AgentProtocolStartupError(
                agentID: agentID, field: "feedback[\(index)]", protocolID: protocolID, reason: .unknownProtocol)
        }
        guard requests.count <= 32, feedback.count <= 16, publications.count <= 64, subscriptions.count <= 16,
            Set(requests).count == requests.count, Set(feedback).count == feedback.count,
            Set(publications).count == publications.count, Set(subscriptions).count == subscriptions.count,
            requests.allSatisfy({
                SignalIdentifier.protocol($0) && contracts[$0]?.kind == .observation
                    && contracts[$0]?.isPublication == false
            }),
            feedback.allSatisfy({
                [
                    ExecutionFeedback.actionResultContract, ExecutionFeedback.toolResultContract,
                    ExecutionFeedback.controlResultContract, ExecutionFeedback.contract,
                ].contains($0) && contracts[$0] != nil
            }),
            publications.allSatisfy({
                SignalIdentifier.channel($0.channel) && contracts[$0.protocol]?.isPublication == true
            }),
            subscriptions.allSatisfy({ sub in
                SignalIdentifier.channel(sub.channel) && contracts[sub.protocol]?.isPublication == true
                    && !sub.sources.isEmpty && sub.sources.count <= 16 && Set(sub.sources).count == sub.sources.count
                    && sub.sources.allSatisfy(CapabilityRegistry.validName)
                    && (sub.events.map {
                        !$0.isEmpty && Set($0).count == $0.count
                            && Set($0).isSubset(of: contracts[sub.protocol]?.events ?? [])
                    } ?? true)
            })
        else { throw AgentConfigurationError.invalidField("channels") }
        for (index, sub) in subscriptions.enumerated() {
            guard
                !subscriptions[..<index].contains(where: {
                    $0.channel == sub.channel && !Set($0.sources).isDisjoint(with: sub.sources)
                })
            else { throw AgentConfigurationError.invalidField("channels.sources.overlap") }
        }
    }
}

public struct CommunicationPolicy: Sendable {
    public let agents: [AgentID: CommunicationDeclaration]
    public let contracts: CommunicationContracts
    private let legacyRoles: Set<AgentID>
    public init(contracts: CommunicationContracts = .standard, configurations: [AgentConfiguration]) throws {
        self.contracts = contracts
        legacyRoles = Set(configurations.filter { $0.version == 9 }.map(\.agentID))
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
    public func runtimeChannel(for target: AgentID) -> String? {
        if legacyRoles.contains(target) { return CommunicationContracts.runtimeDelivery }
        return agents[target]?.sendChannels[CommunicationContracts.runtimeDelivery]
    }

    /// Older compiled callers selected the receiving endpoint by protocol alone.
    public func sendChannel(for key: String, from source: AgentID, to target: AgentID) -> String? {
        if let channel = agents[source]?.sendChannels[key] { return channel }
        return legacyRoles.contains(source) ? agents[target]?.sendChannels[key] : nil
    }
    public func permitsScopedSubscription(_ filter: AgentEventFilter, consumer: AgentID) -> Bool {
        guard legacyRoles.contains(consumer) || agents[consumer]?.eventChannels[filter.protocolID] == filter.channel
        else {
            return false
        }
        return filter.sources.allSatisfy { source in
            agents[source]?.publications.contains { $0.protocol == filter.protocolID && $0.channel == filter.channel }
                == true
        }
    }

    public func destinations(for input: AgentInput) -> [AgentID] {
        agents.keys.filter { acceptsPublication(input, target: $0) }.sorted { $0.rawValue < $1.rawValue }
    }
    public func acceptsPublication(_ input: AgentInput, target: AgentID) -> Bool {
        guard let contract = contracts[input.metadata.contract], contract.kind == .observation,
            input.payload.kind == .observation, input.metadata.version == 1, contract.isPublication,
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
        case .actionResult: return declaration.feedback.contains(ExecutionFeedback.actionResultContract)
        case .toolResult: return declaration.feedback.contains(ExecutionFeedback.toolResultContract)
        case .executionFeedback: return declaration.feedback.contains(input.metadata.contract)
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
        throw AgentConfigurationError.invalidField(
            (decoder.codingPath.map(\.stringValue) + ["fields"]).joined(separator: "."))
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

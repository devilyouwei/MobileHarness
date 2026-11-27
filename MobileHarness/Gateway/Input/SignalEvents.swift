import Foundation

/// Event addresses are separate from execution Channels and never imply a protocol or prefix route.
public struct EventChannel: Sendable, Hashable {
    public let id: String
    public init(_ id: String) throws {
        guard SignalEventNames.channel(id) else { throw SignalTransportError.invalidEnvelope }
        self.id = id
    }
}
private enum SignalEventNames {
    static func channel(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard value.utf8.count <= 64, (2...5).contains(parts.count) else { return false }
        return parts.allSatisfy { part in
            guard let first = part.utf8.first, (97...122).contains(first) else { return false }
            return part.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }
        }
            && !(parts.last.map { $0.first == "v" && !$0.dropFirst().isEmpty && $0.dropFirst().allSatisfy(\.isNumber) }
                ?? false)
    }
    static func protocolID(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard let version = parts.last, version.first == "v", version.dropFirst().first != "0",
            !version.dropFirst().isEmpty, version.dropFirst().utf8.allSatisfy({ (48...57).contains($0) })
        else { return false }
        return value.utf8.count <= 64 && channel(parts.dropLast().joined(separator: "."))
    }
}
public struct SignalEventProtocol<Event: Sendable>: Sendable {
    public let id: String
    public let variants: Set<String>
    public let maximumBytes: Int
    let measure: @Sendable (Event) throws -> Int
    let variant: @Sendable (Event) -> String?
    public init(
        id: String, variants: Set<String> = [], maximumBytes: Int,
        measure: @escaping @Sendable (Event) throws -> Int,
        variant: @escaping @Sendable (Event) -> String? = { _ in nil }
    ) throws {
        guard SignalEventNames.protocolID(id), (1...4_194_304).contains(maximumBytes), variants.count <= 32,
            variants.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 })
        else { throw SignalTransportError.invalidEnvelope }
        self.id = id
        self.variants = variants
        self.maximumBytes = maximumBytes
        self.measure = measure
        self.variant = variant
    }
}
public struct SignalEventConfiguration: Sendable {
    public let publications: Int
    public let branches: Int
    public let bytes: Int
    public let branchCapacity: Int
    public let controlSlots: Int
    public let controlBytes: Int
    public let observers: Int
    public static let standard = Self(
        publications: 128, branches: 256, bytes: 8 * 1024 * 1024,
        branchCapacity: 16, controlSlots: 16, controlBytes: 256 * 1024, observers: 8, validated: true)
    private init(
        publications: Int, branches: Int, bytes: Int, branchCapacity: Int, controlSlots: Int, controlBytes: Int,
        observers: Int, validated: Bool
    ) {
        self.publications = publications
        self.branches = branches
        self.bytes = bytes
        self.branchCapacity = branchCapacity
        self.controlSlots = controlSlots
        self.controlBytes = controlBytes
        self.observers = observers
    }
    public init(
        publications: Int, branches: Int, bytes: Int, branchCapacity: Int, controlSlots: Int, controlBytes: Int,
        observers: Int
    ) throws {
        guard (1...1024).contains(publications), (1...4096).contains(branches), (1024...67_108_864).contains(bytes),
            (1...256).contains(branchCapacity), (0..<min(publications, branches)).contains(controlSlots),
            (0..<bytes).contains(controlBytes), (0...16).contains(observers)
        else { throw SignalTransportError.invalidEnvelope }
        self.init(
            publications: publications, branches: branches, bytes: bytes, branchCapacity: branchCapacity,
            controlSlots: controlSlots, controlBytes: controlBytes, observers: observers, validated: true)
    }
}
public struct SignalEventPublisher<Event: Sendable>: Sendable {
    fileprivate let id: UUID
    public let endpoint: SignalEndpoint
    public let channel: EventChannel
    public let protocolID: String
}
public struct SignalEventSubscription: Sendable, Hashable { fileprivate let id: UUID }
public struct SignalPublication: Sendable { fileprivate let id: UUID }
public struct SignalEventBranchResult: Sendable {
    public enum Status: String, Sendable { case accepted, rejected, closed }
    public let target: String
    public let status: Status
    public let reason: String?
}
private enum EventDispatchOwnership { @TaskLocal static var current: UUID? }

/// Internal Signal (Agent–Agent pub/sub): neutral event delivery. Owners bind identities and schemas; this actor never interprets Agent or Task payloads.
public actor SignalEventTransport {
    private struct Definition: Equatable {
        let protocolID: String
        let type: ObjectIdentifier
        let variants: Set<String>
        let maximumBytes: Int
    }
    private struct Producer {
        let endpoint: SignalEndpoint
        let channel: EventChannel
        let definition: Definition
        let measure: @Sendable (any Sendable) throws -> Int
        let variant: @Sendable (any Sendable) -> String?
    }
    private struct Subscriber {
        let endpoint: SignalEndpoint
        let channel: EventChannel
        let definition: Definition
        let sources: Set<String>
        let variants: Set<String>?
        let scope: String?
        let sessionID: String?
    }
    private struct Publication {
        let source: SignalEndpoint
        let targets: Set<SignalEndpoint>
        let cleanup: Bool
        let task: Task<[SignalEventBranchResult], Never>
        let branches: [UUID: (SignalEndpoint, Task<SignalEventBranchResult, Never>)]
    }
    private struct BranchKey: Hashable {
        let channel: EventChannel
        let target: SignalEndpoint
    }
    private weak var transport: SignalTransport?
    private let configuration: SignalEventConfiguration
    private let admission: GatewayAdmission?
    private var definitions: [EventChannel: Definition] = [:]
    private var producers: [UUID: Producer] = [:]
    private var subscribers: [UUID: Subscriber] = [:]
    private var publications: [UUID: Publication] = [:]
    private var history: [(UUID, [SignalEventBranchResult])] = []
    private var tails: [BranchKey: (UUID, Task<SignalEventBranchResult, Never>)] = [:]
    private var depths: [BranchKey: Int] = [:]
    private var branches = 0
    private var bytes = 0
    private var observers = 0
    private var closed = false
    init(transport: SignalTransport, admission: GatewayAdmission?, configuration: SignalEventConfiguration) {
        self.transport = transport
        self.admission = admission
        self.configuration = configuration
    }
    private func bind<Event>(_ channel: EventChannel, descriptor: SignalEventProtocol<Event>) throws -> Definition {
        guard !closed else { throw SignalTransportError.closed }
        let definition = Definition(
            protocolID: descriptor.id, type: ObjectIdentifier(Event.self), variants: descriptor.variants,
            maximumBytes: descriptor.maximumBytes)
        if let existing = definitions[channel] {
            guard existing == definition else { throw SignalTransportError.schemaMismatch }
        } else {
            guard definitions.count < 64 else { throw SignalTransportError.capacityExceeded }
            definitions[channel] = definition
        }
        return definition
    }
    public func registerProducer<Event>(
        endpoint: SignalEndpoint, channel: EventChannel, using descriptor: SignalEventProtocol<Event>
    ) async throws -> SignalEventPublisher<Event> {
        guard let transport else { throw SignalTransportError.closed }
        try await transport.validateRequestEndpoint(endpoint)
        let definition = try bind(channel, descriptor: descriptor)
        producers = producers.filter { $0.value.endpoint.address != endpoint.address || $0.value.endpoint == endpoint }
        if let existing = producers.first(where: { $0.value.endpoint == endpoint && $0.value.channel == channel }) {
            return .init(id: existing.key, endpoint: endpoint, channel: channel, protocolID: descriptor.id)
        }
        guard producers.count < 256 else { throw SignalTransportError.capacityExceeded }
        let id = UUID()
        producers[id] = Producer(
            endpoint: endpoint, channel: channel, definition: definition,
            measure: { value in
                guard let value = value as? Event else { throw SignalTransportError.schemaMismatch }
                return try descriptor.measure(value)
            }, variant: { value in (value as? Event).flatMap(descriptor.variant) })
        return .init(id: id, endpoint: endpoint, channel: channel, protocolID: descriptor.id)
    }
    public func subscribe<Event>(
        endpoint: SignalEndpoint, channel: EventChannel, using descriptor: SignalEventProtocol<Event>,
        sources: Set<String>, variants: Set<String>? = nil, scope: String? = nil, sessionID: String? = nil
    ) async throws -> SignalEventSubscription {
        guard let transport else { throw SignalTransportError.closed }
        try await transport.validateRequestEndpoint(endpoint)
        let definition = try bind(channel, descriptor: descriptor)
        guard !sources.isEmpty, sources.count <= 16, sources.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }),
            variants.map({ !$0.isEmpty && $0.isSubset(of: descriptor.variants) }) ?? true,
            scope.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true,
            sessionID.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true
        else { throw SignalTransportError.invalidEnvelope }
        subscribers = subscribers.filter {
            $0.value.endpoint.address != endpoint.address || $0.value.endpoint == endpoint
        }
        if let existing = subscribers.first(where: {
            $0.value.endpoint == endpoint && $0.value.channel == channel && $0.value.sources == sources
                && $0.value.variants == variants && $0.value.scope == scope && $0.value.sessionID == sessionID
        }) {
            return .init(id: existing.key)
        }
        guard subscribers.count < 512,
            subscribers.values.filter({ $0.channel == channel && $0.scope == scope }).count < 16
        else {
            throw SignalTransportError.capacityExceeded
        }
        guard
            !subscribers.values.contains(where: {
                $0.endpoint == endpoint && $0.channel == channel
                    && ($0.scope == nil || scope == nil || $0.scope == scope)
                    && ($0.sessionID == nil || sessionID == nil || $0.sessionID == sessionID)
                    && !$0.sources.isDisjoint(with: sources)
            })
        else {
            throw SignalTransportError.duplicateProtocol
        }
        let id = UUID()
        subscribers[id] = Subscriber(
            endpoint: endpoint, channel: channel, definition: definition, sources: sources, variants: variants,
            scope: scope, sessionID: sessionID)
        return .init(id: id)
    }
    public func cancel(_ subscription: SignalEventSubscription) async {
        subscribers[subscription.id] = nil
        let pending = publications.compactMap { id, value in
            id == EventDispatchOwnership.current ? nil : value.branches[subscription.id]?.1
        }
        for task in pending { task.cancel() }
        for task in pending where EventDispatchOwnership.current == nil { _ = await task.value }
    }
    public func publish<Event>(
        _ event: Event, from publisher: SignalEventPublisher<Event>, envelope: SignalEnvelope, scope: String? = nil,
        audience: Set<String>? = nil,
        observer: (@Sendable () async throws -> Void)? = nil,
        settled: @escaping @Sendable ([SignalEventBranchResult]) async -> Void = { _ in }
    ) async throws -> SignalPublication {
        guard !closed, let transport else { throw SignalTransportError.closed }
        if !envelope.cleanup { try admission?.check() }
        try Task.checkCancellation()
        try await transport.validateRequestEndpoint(publisher.endpoint)
        try await transport.validateEnvelope(envelope)
        guard let producer = producers[publisher.id], producer.endpoint == publisher.endpoint,
            producer.channel == publisher.channel, producer.definition.protocolID == envelope.contract,
            let definition = definitions[producer.channel], definition.type == ObjectIdentifier(Event.self),
            scope.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true
        else { throw SignalTransportError.staleEndpoint }
        let measured = try producer.measure(event)
        guard measured == envelope.payloadBytes else { throw SignalTransportError.invalidEnvelope }
        let variant = producer.variant(event)
        guard definition.variants.isEmpty || variant.map(definition.variants.contains) == true else {
            throw SignalTransportError.invalidEnvelope
        }
        let matched = subscribers.filter { _, subscriber in
            subscriber.channel == producer.channel && subscriber.definition == definition
                && subscriber.sources.contains(publisher.endpoint.address)
                && (subscriber.scope == nil || subscriber.scope == scope)
                && (subscriber.sessionID == nil || subscriber.sessionID == envelope.sessionID)
                && (audience.map { $0.contains(subscriber.endpoint.address) } ?? true)
                && (subscriber.variants.map { variants in variant.map(variants.contains) ?? false } ?? true)
        }
        // A full subscriber queue rejects only its own branch and must not consume shared budget.
        let targets = matched.values.map(\.endpoint).filter {
            (depths[BranchKey(channel: producer.channel, target: $0)] ?? 0)
                < configuration.branchCapacity
        }
        guard envelope.payloadBytes >= 0, envelope.payloadBytes <= definition.maximumBytes else {
            throw SignalTransportError.invalidEnvelope
        }
        let useObserver = observer != nil && observers < configuration.observers
        let count = targets.count + (useObserver ? 1 : 0)
        let privileged = envelope.cleanup || envelope.control
        let slotLimit = configuration.publications - (privileged ? 0 : configuration.controlSlots)
        let branchLimit = configuration.branches - (privileged ? 0 : configuration.controlSlots)
        let byteLimit = configuration.bytes - (privileged ? 0 : configuration.controlBytes)
        guard publications.count < slotLimit, branches + count <= branchLimit,
            envelope.payloadBytes <= configuration.bytes, envelope.payloadBytes * count <= byteLimit - bytes
        else {
            throw SignalTransportError.capacityExceeded
        }
        let retained = envelope.payloadBytes * count
        branches += count
        bytes += retained
        if useObserver { observers += 1 }
        let id = UUID()
        var pending: [(BranchKey, UUID, Task<SignalEventBranchResult, Never>)] = []
        var branchTasks: [UUID: (SignalEndpoint, Task<SignalEventBranchResult, Never>)] = [:]
        var initialResults: [SignalEventBranchResult] = []
        let deliveryEnvelope = SignalEnvelope(
            id: envelope.id, sessionID: envelope.sessionID, contract: envelope.contract, channel: producer.channel.id,
            version: envelope.version, hops: envelope.hops, payloadBytes: envelope.payloadBytes,
            expiresAt: envelope.expiresAt, cleanup: envelope.cleanup, control: envelope.control)
        // Reserve each branch tail in admission order, before any publication task can suspend.
        for (subscriptionID, subscriber) in matched {
            let target = subscriber.endpoint
            let key = BranchKey(channel: producer.channel, target: target)
            if (depths[key] ?? 0) >= configuration.branchCapacity {
                initialResults.append(.init(target: target.address, status: .rejected, reason: "capacityExceeded"))
                continue
            }
            let previous = tails[key]?.1
            let branchID = UUID()
            let branch = Task {
                await EventDispatchOwnership.$current.withValue(id) {
                    _ = await previous?.value
                    do {
                        try Task.checkCancellation()
                        try await transport.deliverEvent(
                            source: publisher.endpoint, target: target, envelope: deliveryEnvelope, payload: event)
                        return SignalEventBranchResult(target: target.address, status: .accepted, reason: nil)
                    } catch {
                        return SignalEventBranchResult(
                            target: target.address, status: error is CancellationError ? .closed : .rejected,
                            reason: String(describing: error))
                    }
                }
            }
            depths[key, default: 0] += 1
            tails[key] = (branchID, branch)
            pending.append((key, branchID, branch))
            branchTasks[subscriptionID] = (target, branch)
        }
        let acceptedBranches = pending
        let rejectedBranches = initialResults
        let task = Task {
            await EventDispatchOwnership.$current.withValue(id) {
                var results = await withTaskGroup(of: SignalEventBranchResult.self) { group in
                    for (key, branchID, branch) in acceptedBranches {
                        group.addTask {
                            let result = await withTaskCancellationHandler {
                                await branch.value
                            } onCancel: {
                                branch.cancel()
                            }
                            await self.finishBranch(key, id: branchID)
                            return result
                        }
                    }
                    if useObserver, let observer {
                        group.addTask {
                            do {
                                try await observer()
                                return .init(target: "@observer", status: .accepted, reason: nil)
                            } catch {
                                return .init(target: "@observer", status: .rejected, reason: String(describing: error))
                            }
                        }
                    }
                    var results = rejectedBranches
                    for await result in group { results.append(result) }
                    return results
                }
                if observer != nil && !useObserver {
                    results.append(.init(target: "@observer", status: .rejected, reason: "capacityExceeded"))
                }
                branches -= count
                bytes -= retained
                if useObserver { observers -= 1 }
                history.append((id, results))
                if history.count > 128 { history.removeFirst() }
                await settled(results)
                publications[id] = nil
                return results
            }
        }
        publications[id] = .init(
            source: publisher.endpoint, targets: Set(targets), cleanup: envelope.cleanup, task: task,
            branches: branchTasks)
        return .init(id: id)
    }
    func pendingBranches(to endpoint: SignalEndpoint) -> Int {
        depths.filter { $0.key.target == endpoint }.values.reduce(0, +)
    }
    func runtimeCounts() -> [String: GatewayStateSnapshot.Value] {
        [
            "eventPublications": .count(publications.count), "eventProducers": .count(producers.count),
            "eventSubscriptions": .count(subscribers.count), "eventBranches": .count(branches),
            "eventBytes": .count(bytes), "eventObservers": .count(observers),
        ]
    }
    private func finishBranch(_ key: BranchKey, id: UUID) {
        let remaining = (depths[key] ?? 1) - 1
        depths[key] = remaining == 0 ? nil : remaining
        if tails[key]?.0 == id { tails[key] = nil }
    }
    public func wait(_ publication: SignalPublication) async throws -> [SignalEventBranchResult] {
        if let task = publications[publication.id]?.task { return await task.value }
        guard let result = history.first(where: { $0.0 == publication.id })?.1 else {
            throw SignalTransportError.closed
        }
        return result
    }
    public func flush() async {
        for entry in Array(publications.values) where EventDispatchOwnership.current == nil {
            _ = await entry.task.value
        }
    }
    func unregister(_ endpoint: SignalEndpoint) async {
        producers = producers.filter { $0.value.endpoint != endpoint }
        subscribers = subscribers.filter { $0.value.endpoint != endpoint }
        let originating = publications.filter { $0.value.source == endpoint }
        let receiving = publications.values.flatMap { $0.branches.values.filter { $0.0 == endpoint }.map(\.1) }
        for entry in originating.values { entry.task.cancel() }
        for task in receiving { task.cancel() }
        for entry in originating.values where EventDispatchOwnership.current == nil { _ = await entry.task.value }
        for task in receiving where EventDispatchOwnership.current == nil { _ = await task.value }
    }
    public func cancelPublications(sources: Set<SignalEndpoint>, includeCleanup: Bool = false) async {
        let pending = publications.filter { sources.contains($0.value.source) && (includeCleanup || !$0.value.cleanup) }
        for entry in pending.values { entry.task.cancel() }
        for entry in pending.values where EventDispatchOwnership.current == nil { _ = await entry.task.value }
    }
    func suspend() async {
        let pending = publications.filter { !$0.value.cleanup }
        for entry in pending.values { entry.task.cancel() }
        for entry in pending.values where EventDispatchOwnership.current == nil { _ = await entry.task.value }
    }
    func shutdown() async {
        closed = true
        let pending = publications
        for entry in pending.values { entry.task.cancel() }
        for entry in pending.values where EventDispatchOwnership.current == nil { _ = await entry.task.value }
        producers.removeAll()
        subscribers.removeAll()
        definitions.removeAll()
    }
}

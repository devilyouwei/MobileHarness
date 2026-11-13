import Foundation
import FunctionContracts
import Synchronization

/// Shared by cached ports. Closing admission does not assert native completion.
public final class GatewayAdmission: Sendable {
    private let available = Mutex(false)
    private let parent: GatewayAdmission?
    public init() { parent = nil }
    init(parent: GatewayAdmission) { self.parent = parent }
    public var isOpen: Bool { available.withLock { $0 } && parent?.isOpen != false }
    func setOpen(_ value: Bool) { available.withLock { $0 = value } }
    public func check() throws { guard isOpen else { throw GatewayContainerError.unavailable } }
}

/// Neutral application-supplied configuration; contains no concrete business owners.
public struct GatewayConfiguration: Sendable {
    public let executor: ActionsExecutionPort
    public let resources: [ResourceDefinition]
    public let deliverResult: @Sendable (ExecutionResult) async -> ActionResultDelivery
    public init(
        executor: ActionsExecutionPort, resources: [ResourceDefinition] = [],
        deliverResult: @escaping @Sendable (ExecutionResult) async -> ActionResultDelivery = { _ in .closed }
    ) {
        self.executor = executor
        self.resources = resources
        self.deliverResult = deliverResult
    }
}
public struct GatewayCapabilities: Sendable {
    public let admission: GatewayAdmission
    public let signals: SignalTransport
    public let actions: ChannelScheduler
    public let direct: DirectExecutionDispatcher
    public let resources: ResourceCoordinator
}
public struct GatewayObservationSession: Sendable {
    fileprivate let id: UUID
    public let capabilities: GatewayCapabilities
}
public struct GatewayObservationAccess: Sendable {
    fileprivate weak var root: GatewayContainer?
    @MainActor public func open(configuration: GatewayConfiguration) throws -> GatewayObservationSession {
        guard let root else { throw GatewayContainerError.stopped }
        return try root.openObservationSession(configuration)
    }
    @MainActor public func close(_ session: GatewayObservationSession) async throws {
        guard let root else { throw GatewayContainerError.stopped }
        try await root.closeObservationSession(session)
    }
}

/// App-scoped root. Configuration constructs facilities; only start opens admission.
@MainActor public final class GatewayContainer {
    public enum State: String, CaseIterable, Sendable {
        case cold, configured, running, suspended, stopping, stopped, failed
    }
    public private(set) var state: State = .cold
    public func stateSnapshot() async throws -> GatewayStateSnapshot {
        try Task.checkCancellation()
        var children: [GatewayStateSnapshot.Reference] = [.init(path: "gateway.signals")]
        if configured != nil {
            children += ["gateway.scheduler", "gateway.direct", "gateway.resources"].map { .init(path: $0) }
        }
        return GatewayStateSnapshot(
            path: "gateway",
            runtime: [
                "phase": .text(state.rawValue), "available": .flag(isAvailable),
                "observationScopes": .count(observationScopes.count),
            ], health: state == .failed ? .fault : .unknown,
            issues: state == .failed ? [.init(code: "lifecycleFailed", impact: "coordinationUnavailable")] : [],
            children: children, stateValues: ["runtime.phase": State.allCases.map(\.rawValue)])
    }
    public func stateReaders() async throws -> [String: GatewayStateSnapshot.Reader] {
        var readers: [String: GatewayStateSnapshot.Reader] = [
            "gateway": GatewayStateSnapshot.reader(of: self) { try await $0.stateSnapshot() },
            "gateway.signals": GatewayStateSnapshot.reader(of: signals) { try await $0.stateSnapshot() },
        ]
        if let configured {
            readers["gateway.scheduler"] = GatewayStateSnapshot.reader(of: configured.actions) {
                try await $0.stateSnapshot()
            }
            readers["gateway.direct"] = GatewayStateSnapshot.reader(of: configured.direct) {
                try await $0.stateSnapshot()
            }
            readers["gateway.resources"] = GatewayStateSnapshot.reader(of: configured.resources) {
                try await $0.stateSnapshot()
            }
        }
        return readers
    }

    public var isAvailable: Bool { admission.isOpen }
    public var observations: GatewayObservationAccess { GatewayObservationAccess(root: self) }
    private let admission: GatewayAdmission
    public nonisolated let signals: SignalTransport
    public var admissionPort: GatewayAdmission { admission }
    private var configured: GatewayCapabilities?
    private struct ObservationScope {
        let capabilities: GatewayCapabilities
        let admission: GatewayAdmission
        var closing: Task<Void, any Error>?
    }
    private var observationScopes: [UUID: ObservationScope] = [:]
    private var suspension: Task<Void, any Error>?
    private var shutdown: Task<Void, any Error>?
    private var suspensionFailure: (any Error)?
    private var desiredForeground = true
    private var revision: UInt64 = 0
    private let onFailure: @Sendable (GatewayFailure) -> Void
    public init(onFailure: @escaping @Sendable (GatewayFailure) -> Void = { _ in }) {
        let admission = GatewayAdmission()
        self.admission = admission
        self.signals = SignalTransport(admission: admission)
        self.onFailure = onFailure
    }
    public var capabilities: GatewayCapabilities {
        get throws(GatewayFailure) {
            guard state != .stopped, state != .stopping, state != .failed, let configured else {
                throw failure("capabilities", GatewayContainerError.unavailable, code: .unavailable)
            }
            return configured
        }
    }
    @discardableResult public func configureExecution(
        _ configuration: GatewayConfiguration,
        onExecutionSnapshot: (@Sendable (ActionExecutionSnapshot) -> Void)? = nil
    ) throws(GatewayFailure) -> GatewayCapabilities {
        do {
            guard state == .cold else { throw GatewayContainerError.alreadyConfigured }
            let capabilities = try assemble(configuration, onExecutionSnapshot: onExecutionSnapshot)
            configured = capabilities
            state = .configured
            return capabilities
        } catch {
            if state == .cold { state = .failed }
            throw failure("configureExecution", error, code: error is GatewayContainerError ? .conflict : nil)
        }
    }
    private func assemble(
        _ configuration: GatewayConfiguration, admission supplied: GatewayAdmission? = nil,
        onExecutionSnapshot: (@Sendable (ActionExecutionSnapshot) -> Void)? = nil
    ) throws -> GatewayCapabilities {
        let admission = supplied ?? self.admission
        let signals = supplied == nil ? self.signals : SignalTransport(admission: admission)
        let validateScope: @Sendable (FunctionInvocation, ExecutionOwner?) async throws -> Void = {
            try await signals.validateExecution($0, owner: $1)
        }
        let resources = try ResourceCoordinator(definitions: configuration.resources, admission: admission)
        let actions = ChannelScheduler(
            executor: configuration.executor, resources: resources,
            admission: admission, validateScope: validateScope, deliverResult: configuration.deliverResult,
            onExecutionSnapshot: onExecutionSnapshot)
        return GatewayCapabilities(
            admission: admission, signals: signals, actions: actions,
            direct: DirectExecutionDispatcher(
                executor: configuration.executor, resources: resources, admission: admission,
                validateScope: validateScope), resources: resources)
    }
    fileprivate func openObservationSession(_ configuration: GatewayConfiguration) throws -> GatewayObservationSession {
        try admission.check()
        guard observationScopes.isEmpty else { throw SignalTransportError.capacityExceeded }
        let scopeAdmission = GatewayAdmission(parent: admission)
        let ports = try assemble(configuration, admission: scopeAdmission)
        let id = UUID()
        scopeAdmission.setOpen(true)
        observationScopes[id] = ObservationScope(capabilities: ports, admission: scopeAdmission)
        return GatewayObservationSession(id: id, capabilities: ports)
    }
    fileprivate func closeObservationSession(_ session: GatewayObservationSession) async throws {
        if state == .stopping || state == .stopped || state == .failed {
            try await shutdown?.value
            return
        }
        guard var scope = observationScopes[session.id] else { return }
        scope.admission.setOpen(false)
        let task: Task<Void, any Error>
        if let closing = scope.closing {
            task = closing
        } else {
            let capabilities = scope.capabilities
            task = Task { try await Self.finish(capabilities) }
            scope.closing = task
            observationScopes[session.id] = scope
        }
        do {
            try await task.value
            observationScopes[session.id] = nil
        } catch { throw failure("closeObservationSession", error) }
    }
    public func start() async throws(GatewayFailure) {
        do {
            try Task.checkCancellation()
            guard state == .configured || state == .running else {
                throw state == .cold ? GatewayContainerError.unavailable : GatewayContainerError.stopped
            }
            state = .running
            desiredForeground = true
            admission.setOpen(true)
        } catch {
            if error is CancellationError {
                var cleanup: [any Error] = []
                do { try await stop() } catch { cleanup.append(error) }
                throw failure("start", GatewayFailure(operation: "start", underlying: error, cleanupErrors: cleanup))
            }
            throw failure("start", error)
        }
    }
    public func invalidate() {
        guard state == .running || state == .suspended else { return }
        admission.setOpen(false)
        desiredForeground = false
        revision &+= 1
        state = .suspended
        guard suspension == nil, let configured else { return }
        let scopes = observationScopes.values.map(\.capabilities)
        suspension = Task {
            var errors: [any Error] = []
            for ports in [configured] + scopes {
                do { try await Self.pause(ports) } catch { errors.append(error) }
            }
            if let primary = errors.first {
                throw GatewayFailure(
                    operation: "suspend", underlying: primary,
                    cleanupErrors: Array(errors.dropFirst()), code: .cleanupFailed)
            }
        }
    }
    public func setForeground(_ active: Bool) async throws(GatewayFailure) {
        do {
            guard state == .running || state == .suspended else { throw GatewayContainerError.stopped }
            if !active { invalidate() }
            desiredForeground = active
            revision &+= 1
            let current = revision
            do { try await suspension?.value } catch {
                suspensionFailure = error
                throw error
            }
            if let suspensionFailure { throw suspensionFailure }
            guard state != .stopping, state != .stopped, current == revision else { return }
            if active, desiredForeground {
                suspension = nil
                state = .running
                admission.setOpen(true)
            }
        } catch { throw failure("setForeground", error) }
    }
    public func stop() async throws(GatewayFailure) {
        admission.setOpen(false)
        if shutdown != nil {
            do { try await shutdown?.value } catch { throw failure("stop", error) }
            return
        }
        state = .stopping
        revision &+= 1
        desiredForeground = false
        let configured = configured
        let suspension = suspension
        let scopes = Array(observationScopes.values)
        let task = Task {
            var errors: [any Error] = []
            do { try await suspension?.value } catch { errors.append(error) }
            for scope in scopes {
                do {
                    if let closing = scope.closing {
                        try await closing.value
                    } else {
                        try await Self.finish(scope.capabilities)
                    }
                } catch { errors.append(error) }
            }
            if let configured {
                do { try await Self.finish(configured) } catch { errors.append(error) }
            }
            if let primary = errors.first {
                throw GatewayFailure(
                    operation: "stop", underlying: primary, cleanupErrors: Array(errors.dropFirst()),
                    code: .cleanupFailed)
            }
        }
        shutdown = task
        do {
            try await task.value
            observationScopes.removeAll()
            self.configured = nil
            state = .stopped
        } catch {
            observationScopes.removeAll()
            self.configured = nil
            state = .failed
            throw failure("stop", error)
        }
    }
    private nonisolated static func finish(_ ports: GatewayCapabilities) async throws {
        var errors: [any Error] = []
        do { try await pause(ports) } catch { errors.append(error) }
        await ports.actions.shutdown()
        await ports.direct.shutdown()
        await ports.signals.shutdown()
        do { try await ports.resources.closeLifecycle(permanently: true) } catch { errors.append(error) }
        if let primary = errors.first {
            throw GatewayFailure(
                operation: "stop", underlying: primary,
                cleanupErrors: Array(errors.dropFirst()), code: .cleanupFailed)
        }
    }
    private nonisolated static func pause(_ capabilities: GatewayCapabilities) async throws {
        async let signals: Void = capabilities.signals.suspend()
        async let output: Void = capabilities.actions.suspend()
        async let direct: Void = capabilities.direct.suspend()
        var failure: (any Error)?
        do { try await capabilities.resources.closeLifecycle(permanently: false) } catch { failure = error }
        _ = await (output, direct, signals)
        if let failure { throw failure }
    }
    private func failure(_ operation: String, _ error: any Error, code: GatewayFailure.Code? = nil) -> GatewayFailure {
        let value: GatewayFailure
        if let original = error as? GatewayFailure {
            value = original
        } else {
            let classified: GatewayFailure.Code? =
                switch error as? GatewayContainerError {
                case .unavailable: .unavailable
                case .stopped: .stopped
                case .alreadyConfigured: .conflict
                case nil: code
                }
            value = GatewayFailure(operation: operation, underlying: error, code: classified)
        }
        onFailure(value)
        return value
    }
}

/// Module-local, explicitly projected facts. This type never inspects private storage.
public struct GatewayStateSnapshot: Codable, Sendable {
    public struct Reference: Codable, Sendable, Hashable {
        public let path: String
        public init(path: String) { self.path = path }
    }
    public enum ReadError: Error, Sendable { case ownerReleased }
    public typealias Reader = @Sendable () async throws -> GatewayStateSnapshot
    /// Runtime capability only. Serialization carries Reference indices, never owner objects.
    public static func reader<Owner: AnyObject & Sendable>(
        of owner: Owner, read: @escaping @Sendable (Owner) async throws -> GatewayStateSnapshot
    ) -> Reader {
        { [weak owner] in
            try Task.checkCancellation()
            guard let owner else { throw ReadError.ownerReleased }
            return try await read(owner)
        }
    }
    public indirect enum Value: Codable, Sendable, Equatable {
        case text(String)
        case flag(Bool)
        case count(Int)
        case unsigned(UInt64)
        case number(Double)
        case integers([Int])
        case texts([String])
        case object([String: Value])
        case array([Value])
        case unknown
        public init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() {
                self = .unknown
            } else if let flag = try? value.decode(Bool.self) {
                self = .flag(flag)
            } else if let count = try? value.decode(Int.self) {
                self = .count(count)
            } else if let unsigned = try? value.decode(UInt64.self) {
                self = .unsigned(unsigned)
            } else if let number = try? value.decode(Double.self) {
                self = .number(number)
            } else if let integers = try? value.decode([Int].self) {
                self = .integers(integers)
            } else if let texts = try? value.decode([String].self) {
                self = .texts(texts)
            } else if let object = try? value.decode([String: Value].self) {
                self = .object(object)
            } else if let array = try? value.decode([Value].self) {
                self = .array(array)
            } else {
                self = .text(try value.decode(String.self))
            }
        }
        public func encode(to encoder: any Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .text(let item): try value.encode(item)
            case .flag(let item): try value.encode(item)
            case .count(let item): try value.encode(item)
            case .unsigned(let item): try value.encode(item)
            case .number(let item): try value.encode(item)
            case .integers(let item): try value.encode(item)
            case .texts(let item): try value.encode(item)
            case .object(let item): try value.encode(item)
            case .array(let item): try value.encode(item)
            case .unknown: try value.encodeNil()
            }
        }
    }
    public enum Health: String, Codable, Sendable { case healthy, limited, fault, unknown }
    public struct Issue: Codable, Sendable {
        public let code: String
        public let impact: String
        public init(code: String, impact: String) {
            self.code = code
            self.impact = impact
        }
    }
    public struct Descriptor: Codable, Sendable {
        public let path: String
        public let business: [String]
        public let runtime: [String]
        public let children: [Reference]
        public let meanings: [String: String]
        public let units: [String: String]
        public let stateValues: [String: [String]]
    }
    public let path: String
    public let business: [String: Value]
    public let runtime: [String: Value]
    public let health: Health
    public let issues: [Issue]
    public let children: [Reference]
    /// Collection time only; measurement age belongs to the owning business fact.
    public let collectedAt: Date
    public let meanings: [String: String]
    public let units: [String: String]
    public let stateValues: [String: [String]]
    public var stateDescriptor: Descriptor {
        Descriptor(
            path: path, business: business.keys.sorted(), runtime: runtime.keys.sorted(),
            children: children, meanings: meanings, units: units,
            stateValues: stateValues.merging(["health": ["healthy", "limited", "fault", "unknown"]]) { current, _ in
                current
            })
    }
    public init(
        path: String, business: [String: Value] = [:], runtime: [String: Value] = [:],
        health: Health = .unknown, issues: [Issue] = [], children: [Reference] = [],
        meanings: [String: String] = [:], units: [String: String] = [:], stateValues: [String: [String]] = [:]
    ) {
        self.path = path
        self.meanings = meanings
        self.units = units
        self.stateValues = stateValues
        self.business = business
        self.runtime = runtime
        self.health = health
        self.issues = issues
        self.children = children
        collectedAt = Date()
    }
}

import CallRuntime
import ExecutionRuntime
import Foundation
@_exported import FunctionContracts

/// The single module root. Domains, modules and functions are composable library values.
@MainActor public final class ActionsContainer {
    public enum State: String, CaseIterable, Sendable {
        case cold, configured, running, suspended, stopping, stopped, failed
    }
    public private(set) var state: State = .cold
    public func stateSnapshot() async throws -> ActionsStateSnapshot {
        try Task.checkCancellation()
        var children: [ActionsStateSnapshot.Reference] = []
        #if os(iOS)
            if #available(iOS 27, *), businessOwner is ActionsBusinessAssembly {
                children = [.init(path: "actions.camera"), .init(path: "actions.robot")]
            }
        #endif
        return ActionsStateSnapshot(
            path: "actions",
            runtime: [
                "prepared": .count(prepared.count), "executing": .count(active.count), "phase": .text(state.rawValue),
                "workers": .count(runningWorkers.count),
            ],
            health: state == .failed ? .fault : .unknown,
            issues: state == .failed ? [.init(code: "lifecycleFailed", impact: "executionUnavailable")] : [],
            children: children, stateValues: ["runtime.phase": State.allCases.map(\.rawValue)])
    }
    public func stateReaders() async throws -> [String: ActionsStateSnapshot.Reader] {
        var readers: [String: ActionsStateSnapshot.Reader] = [
            "actions": ActionsStateSnapshot.reader(of: self) { try await $0.stateSnapshot() }
        ]
        #if os(iOS)
            if #available(iOS 27, *), let owner = businessOwner as? ActionsBusinessAssembly {
                readers.merge(try await owner.stateReaders()) { _, new in new }
            }
        #endif
        return readers
    }
    public var isShutdownRequested: Bool { shutdown != nil }
    private struct Preparation {
        let invocation: FunctionInvocation
        let definition: ActionFunction
        let resources: Set<ResourceID>
    }
    var businessOwner: AnyObject?
    private var definitions: [ActionIdentifier: [ActionBinding]] = [:]
    private var snapshot: ActionCatalogSnapshot?
    private var prepared: [UUID: Preparation] = [:]
    private var active: [UUID: Task<ActionCompletion, any Error>] = [:]
    private var cleanup: [@MainActor @Sendable () async throws -> Void] = []
    private var workers: [@Sendable () async -> Void] = []
    private var runningWorkers: [Task<Void, Never>] = []
    private var invalidateNative: @MainActor @Sendable () -> Void = {}
    private var nativeForeground: @MainActor @Sendable (Bool) async throws -> Void = { _ in }
    private var shutdown: Task<Void, any Error>?
    private var suspension: Task<Void, any Error>?
    private var revision: UInt64 = 0
    private let onFailure: @Sendable (ActionsFailure) -> Void
    public init(onFailure: @escaping @Sendable (ActionsFailure) -> Void = { _ in }) { self.onFailure = onFailure }

    public var execution: ActionsExecutionPort {
        ActionsExecutionPort(
            catalog: { [weak self] in
                guard let self else { throw ActionsContainerError.stopped }
                return try await self.catalog()
            },
            prepare: { [weak self] input, callProtocol in
                guard let self else { throw ActionsContainerError.stopped }
                return try await self.prepare(input, callProtocol: callProtocol)
            },
            execute: { [weak self] ticket in
                guard let self else { throw ActionsContainerError.stopped }
                return try await self.execute(ticket)
            },
            discard: { [weak self] ticket in await self?.discard(ticket) })
    }
    public func configure(
        _ assembly: BehaviorAssembly, cleanup: [@MainActor @Sendable () async throws -> Void] = [],
        workers: [@Sendable () async -> Void] = [], invalidateNative: @escaping @MainActor @Sendable () -> Void = {},
        nativeForeground: @escaping @MainActor @Sendable (Bool) async throws -> Void = { _ in }
    ) throws {
        guard state == .cold else { throw ActionsContainerError.alreadyConfigured }
        do {
            guard workers.count <= 8, cleanup.count <= 32 - self.cleanup.count else {
                throw ActionsContainerError.capacityExceeded
            }
            self.cleanup.append(contentsOf: cleanup)
            self.workers = workers
            self.nativeForeground = nativeForeground
            self.invalidateNative = invalidateNative
            var grouped: [ActionIdentifier: [ActionBinding]] = [:]
            for binding in assembly.bindings {
                try binding.validate()
                let existing = grouped[binding.path, default: []]
                guard existing.allSatisfy({ $0.protocols.isDisjoint(with: binding.protocols) }) else {
                    throw ActionExecutionError.duplicateDefinition(binding.path)
                }
                grouped[binding.path, default: []].append(binding)
            }
            guard grouped.count <= 256 else { throw ActionsContainerError.capacityExceeded }
            definitions = grouped
            snapshot = ActionCatalogSnapshot(
                revision: UUID(), entries: grouped.values.flatMap { $0.map(Self.descriptor) })
            state = .configured
        } catch {
            state = .failed
            throw failure("configure", error)
        }
    }
    public func catalog() throws -> ActionCatalogSnapshot {
        guard state == .configured || state == .running || state == .suspended, let snapshot else {
            throw ActionsContainerError.unavailable
        }
        return snapshot
    }
    public func start() throws {
        try Task.checkCancellation()
        guard state == .configured || state == .running else { throw ActionsContainerError.unavailable }
        if state == .running { return }
        state = .running
        runningWorkers = workers.map { work in Task { await work() } }
    }
    public func addCleanup(_ operation: @escaping @MainActor @Sendable () async throws -> Void) throws {
        guard state == .configured || state == .running else { throw ActionsContainerError.unavailable }
        guard cleanup.count < 32 else { throw ActionsContainerError.capacityExceeded }
        cleanup.append(operation)
    }
    private func prepare(_ invocation: FunctionInvocation, callProtocol: ActionExecutionDescriptor.CallProtocol) throws
        -> PreparedAction
    {
        try Task.checkCancellation()
        guard state == .running, let snapshot else { throw ActionsContainerError.unavailable }
        guard prepared.count < 1024 else { throw ActionsContainerError.capacityExceeded }
        guard
            let binding = definitions[invocation.call.actionPath]?.first(where: { $0.protocols.contains(callProtocol) })
        else {
            throw ActionExecutionError.missingHandler(invocation.call.actionPath)
        }
        try binding.function.validateInput(invocation)
        let resources = Set(
            try binding.requiredResources(for: invocation.call).map { ResourceID(rawValue: $0.rawValue) })
        let budget = try binding.function.executionBudget(for: invocation.call)
        let id = UUID()
        prepared[id] = Preparation(invocation: invocation, definition: binding.function, resources: resources)
        return PreparedAction(
            id: id, revision: snapshot.revision, descriptor: Self.descriptor(binding), resources: resources,
            budget: budget)
    }
    private func discard(_ ticket: PreparedAction) {
        guard ticket.revision == snapshot?.revision else { return }
        prepared[ticket.id] = nil
    }
    private func execute(_ ticket: PreparedAction) async throws -> ActionCompletion {
        try Task.checkCancellation()
        guard state == .running else { throw ActionsContainerError.unavailable }
        guard ticket.revision == snapshot?.revision, let pending = prepared.removeValue(forKey: ticket.id) else {
            throw ActionsContainerError.invalidPreparation
        }
        guard active.count < 256 else { throw ActionsContainerError.capacityExceeded }
        let task = Task {
            if !pending.resources.isEmpty {
                guard let permit = ResourceExecutionContext.permit else { throw ActionsContainerError.missingBinding }
                try await permit.validate(pending.resources)
            }
            try Task.checkCancellation()
            guard self.state == .running else { throw ActionsContainerError.unavailable }
            return try await FunctionExecutor.perform(pending.invocation, definition: pending.definition)
        }
        active[ticket.id] = task
        defer { active[ticket.id] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
    public func invalidate() {
        guard state == .running || state == .suspended else { return }
        state = .suspended
        invalidateNative()
        revision &+= 1
        prepared.removeAll()
        let selected = Array(active.values)
        for task in selected { task.cancel() }
        if suspension == nil {
            let nativeForeground = nativeForeground
            suspension = Task {
                for task in selected { _ = await task.result }
                try await nativeForeground(false)
            }
        }
    }
    public func setForeground(_ active: Bool) async throws {
        guard state == .running || state == .suspended else { throw ActionsContainerError.stopped }
        if !active { invalidate() }
        revision &+= 1
        let current = revision
        try await suspension?.value
        guard current == revision, state != .stopping, state != .stopped, state != .failed else { return }
        if active {
            try await nativeForeground(true)
            guard current == revision, state != .stopping, state != .stopped, state != .failed else { return }
            suspension = nil
            state = .running
        }
    }
    public func stop() async throws {
        if let shutdown {
            try await shutdown.value
            return
        }
        state = .stopping
        revision &+= 1
        prepared.removeAll()
        let selected = Array(active.values)
        for task in selected { task.cancel() }
        invalidateNative()
        let nativeWorkers = runningWorkers
        for worker in nativeWorkers { worker.cancel() }
        let cleanup = self.cleanup
        let suspension = suspension
        let task = Task {
            var errors: [any Error] = []
            do { try await suspension?.value } catch { errors.append(error) }
            for task in selected { _ = await task.result }
            for close in cleanup.reversed() { do { try await close() } catch { errors.append(error) } }
            for worker in nativeWorkers { await worker.value }
            if let first = errors.first {
                throw ActionsFailure(
                    operation: "stop", underlying: first, cleanupErrors: Array(errors.dropFirst()), code: .cleanupFailed
                )
            }
        }
        shutdown = task
        do {
            try await task.value
            definitions.removeAll()
            snapshot = nil
            self.cleanup.removeAll()
            businessOwner = nil
            state = .stopped
        } catch {
            state = .failed
            throw failure("stop", error)
        }
    }
    private nonisolated static func descriptor(_ binding: ActionBinding) -> ActionExecutionDescriptor {
        ActionExecutionDescriptor(
            path: binding.path, declaration: binding.function.declaration,
            displayName: binding.displayName, kind: binding.kind, protocols: binding.protocols,
            executionPolicy: binding.executionPolicy, directResultPolicy: binding.directResultPolicy)
    }
    private func failure(_ operation: String, _ error: any Error) -> ActionsFailure {
        let value = (error as? ActionsFailure) ?? ActionsFailure(operation: operation, underlying: error)
        onFailure(value)
        return value
    }
}

/// Module-local, explicitly projected facts. This type never inspects private storage.
public struct ActionsStateSnapshot: Codable, Sendable {
    public struct Reference: Codable, Sendable, Hashable {
        public let path: String
        public init(path: String) { self.path = path }
    }
    public enum ReadError: Error, Sendable { case ownerReleased }
    public typealias Reader = @Sendable () async throws -> ActionsStateSnapshot
    /// Runtime capability only. Serialization carries Reference indices, never owner objects.
    public static func reader<Owner: AnyObject & Sendable>(
        of owner: Owner, read: @escaping @Sendable (Owner) async throws -> ActionsStateSnapshot
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

#if os(iOS)
    @available(iOS 27, *)
    extension ActionsContainer {
        public static func makeBusiness(
            dependencies: ActionsDependencies,
            onFailure: @escaping @Sendable (ActionsFailure) -> Void = { _ in }
        ) -> (container: ActionsContainer, capabilities: ActionsHostCapabilities) {
            let root = ActionsContainer(onFailure: onFailure)
            let bluetooth = BluetoothWorkflow(
                state: dependencies.ui.devices.presentation,
                link: dependencies.platform.connectivity.bluetooth, makeDeviceRepository: dependencies.devices)
            let photos = CameraStorageFactory.make(
                repository: dependencies.media,
                files: { try dependencies.files.file(dependencies.files.photos) })
            let assembly = ActionsBusinessAssembly(
                actions: root, files: dependencies.files,
                model: dependencies.model, platform: dependencies.platform, ui: dependencies.ui,
                photos: photos, bluetooth: bluetooth, previewHistory: dependencies.previewHistory,
                makeCameraRuntime: dependencies.makeCameraRuntime, connectVision: dependencies.connectVision)
            root.businessOwner = assembly
            root.cleanup = [
                { try await assembly.camera.shutdown() },
                { try await assembly.bluetooth.shutdown() }, { await assembly.stopInteractions() },
            ]
            return (
                root,
                ActionsHostCapabilities(
                    camera: ActionsCameraHost(assembly.camera),
                    device: ActionsDeviceHost(bluetooth: bluetooth, device: assembly.device), facades: assembly.facades)
            )
        }
    }
#endif

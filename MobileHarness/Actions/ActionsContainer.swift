import CallRuntime
import ExecutionRuntime
import Foundation
@_exported import FunctionContracts

/// The single module root. Domains, modules and functions are composable library values.
@MainActor public final class ActionsContainer {
    public enum State: Sendable { case cold, configured, running, suspended, stopping, stopped, failed }
    public private(set) var state: State = .cold
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
        workers: [@Sendable () async -> Void] = [], invalidateNative: @escaping @MainActor @Sendable () -> Void = {}
    ) throws {
        guard state == .cold else { throw ActionsContainerError.alreadyConfigured }
        do {
            guard workers.count <= 8, cleanup.count <= 32 - self.cleanup.count else {
                throw ActionsContainerError.capacityExceeded
            }
            self.cleanup.append(contentsOf: cleanup)
            self.workers = workers
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
    func registerPreparationCleanup(_ operation: @escaping @MainActor @Sendable () async throws -> Void) throws {
        guard state == .cold, cleanup.count < 32 else { throw ActionsContainerError.capacityExceeded }
        cleanup.append(operation)
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
            suspension = Task { for task in selected { _ = await task.result } }
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

import Foundation
import FunctionContracts

/// Direct calls share Actions validation/execution while bypassing Channel ordering.
public actor DirectExecutionDispatcher {
    private let validateScope: @Sendable (FunctionInvocation, ExecutionOwner?) async throws -> Void
    private let executor: ActionsExecutionPort
    private let resources: ResourceCoordinator
    private let admission: GatewayAdmission
    public func stateSnapshot() async throws -> GatewayStateSnapshot {
        try Task.checkCancellation()
        return GatewayStateSnapshot(
            path: "gateway.direct", runtime: ["executing": .count(work.count), "closed": .flag(closed)])
    }
    private var work: [UUID: Task<ActionCompletion, any Error>] = [:]
    private var closed = false
    init(
        executor: ActionsExecutionPort, resources: ResourceCoordinator, admission: GatewayAdmission,
        validateScope: @escaping @Sendable (FunctionInvocation, ExecutionOwner?) async throws -> Void = { _, _ in }
    ) {
        self.validateScope = validateScope
        self.executor = executor
        self.resources = resources
        self.admission = admission
    }
    public func execute(_ input: FunctionInvocation, owner: ExecutionOwner) async throws -> ActionCompletion {
        guard !closed else { throw SignalTransportError.closed }
        try admission.check()
        guard work.count < 128 else { throw SignalTransportError.capacityExceeded }
        let id = UUID()
        let executor = executor
        let resources = resources
        let admission = admission
        let validateScope = validateScope
        let task = Task {
            try await validateScope(input, owner)
            let prepared = try await executor.prepare(input, .tool)
            do {
                try Task.checkCancellation()
                try admission.check()
                try await validateScope(input, owner)
                let lease = await resources.lease(for: owner, resources: prepared.resources)
                let value = try await resources.run(resources: prepared.resources, owner: owner, lease: lease) {
                    try await executor.execute(prepared)
                }
                await executor.discard(prepared)
                return value
            } catch {
                await executor.discard(prepared)
                throw error
            }
        }
        work[id] = task
        defer { work[id] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
    func suspend() async {
        let selected = Array(work.values)
        for task in selected { task.cancel() }
        for task in selected { _ = await task.result }
    }
    func shutdown() async {
        closed = true
        await suspend()
    }
}

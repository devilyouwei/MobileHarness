import AgentCore
import Foundation

/// One ordered output reader admits Actions immediately; each sealed round joins its own tools and effects.
actor AssistantGenerationTransport {
    private let dispatch: @Sendable (OutputEnvelope) async throws -> Void
    private nonisolated let failures: AsyncStream<any Error>
    private let failureContinuation: AsyncStream<any Error>.Continuation
    private var tools: [String: [String: Task<Void, Error>]] = [:]
    private var seals: [String: Task<Void, Error>] = [:]
    private var lanes: [Task<Void, Error>?] = Array(repeating: nil, count: 4)
    private var ordinal = 0
    private var closed = false
    private var failure: (any Error)?
    init(dispatch: @escaping @Sendable (OutputEnvelope) async throws -> Void) {
        self.dispatch = dispatch
        (failures, failureContinuation) = AsyncStream<any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
    }
    static func consume(
        _ outputs: AsyncStream<OutputEnvelope>,
        dispatch: @escaping @Sendable (OutputEnvelope) async throws -> Void
    ) async throws {
        let transport = AssistantGenerationTransport(dispatch: dispatch)
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await output in outputs {
                        try Task.checkCancellation()
                        try await transport.submit(output)
                    }
                    try Task.checkCancellation()
                    try await transport.finish()
                }
                group.addTask {
                    for await failure in transport.failures { throw failure }
                }
                do {
                    _ = try await group.next()
                    group.cancelAll()
                } catch {
                    group.cancelAll()
                    await transport.cancel()
                    throw error
                }
            }
        } onCancel: {
            Task { await transport.cancel() }
        }
    }
    private func submit(_ envelope: OutputEnvelope) async throws {
        guard !closed else { throw CancellationError() }
        if let failure { throw failure }
        let native: Bool
        switch envelope.output {
        case .toolCall: native = envelope.roundID != nil
        case .rejectedCall(let rejection): native = rejection.kind == .tool && envelope.roundID != nil
        default: native = false
        }
        let dispatch = dispatch
        if native, let round = envelope.roundID {
            guard tools.values.reduce(0, { $0 + $1.count }) < 128 else { throw HarnessError.queueFull }
            let lane = ordinal % 4
            ordinal = (ordinal + 1) % 4
            let previous = lanes[lane]
            let task = Task {
                if let previous { _ = await previous.result }
                try Task.checkCancellation()
                try await dispatch(envelope)
            }
            tools[round, default: [:]][UUID().uuidString] = task
            lanes[lane] = task
        } else if case .roundFinished(let round) = envelope.output {
            guard seals[round] == nil, seals.count < 32 else { throw HarnessError.queueFull }
            let pending = Array(tools[round, default: [:]].values)
            seals[round] = Task {
                do {
                    for task in pending { try await task.value }
                    try Task.checkCancellation()
                    try await dispatch(envelope)
                } catch is CancellationError {
                    // The host cancels the round and closes its paired outcomes separately.
                } catch {
                    self.failure = error
                    self.failureContinuation.yield(error)
                }
                self.tools[round] = nil
                self.seals[round] = nil
            }
        } else {
            try await dispatch(envelope)
        }
    }
    private func finish() async throws {
        closed = true
        for task in Array(seals.values) { try await task.value }
        for task in tools.values.flatMap({ $0.values }) { try await task.value }
        if let failure { throw failure }
    }
    private func cancel() async {
        closed = true
        let pending = Array(seals.values) + tools.values.flatMap { Array($0.values) }
        for task in pending { task.cancel() }
        for task in pending { _ = await task.result }
        seals.removeAll()
        tools.removeAll()
        lanes = Array(repeating: nil, count: 4)
        failureContinuation.finish()
    }
}

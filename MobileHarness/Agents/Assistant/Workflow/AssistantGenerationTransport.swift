import AgentCore
import Foundation
import Gateway

/// One ordered output reader admits Actions immediately; each sealed round joins its own tools and effects.
actor AssistantGenerationTransport {
    private let signalDispatcher: SignalChannelDispatcher<OutputEnvelope>?
    private let contracts: CommunicationContracts?
    private let dispatch: @Sendable (OutputEnvelope) async throws -> Void
    private nonisolated let failures: AsyncStream<any Error>
    private let failureContinuation: AsyncStream<any Error>.Continuation
    private var tools: [String: [String: Task<Void, Error>]] = [:]
    private var toolSeals: [String: Task<Void, Error>] = [:]
    private var seals: [String: Task<Void, Error>] = [:]
    private let toolRequests = SignalWorkPool()
    private nonisolated let directSignals = AsyncStream<OutputEnvelope>.makeStream(
        bufferingPolicy: .bufferingOldest(128))
    private var closed = false
    private var failure: (any Error)?
    init(contracts: CommunicationContracts?, dispatch: @escaping @Sendable (OutputEnvelope) async throws -> Void) {
        self.contracts = contracts
        if let contracts {
            let channels = contracts.registered.compactMap(\.channel) + [GatewayExecution.actionCallChannel]
            signalDispatcher = SignalChannelDispatcher(
                channels: Set(channels), capacities: [GatewayExecution.actionCallChannel: 256])
        } else {
            signalDispatcher = nil
        }
        self.dispatch = dispatch
        (failures, failureContinuation) = AsyncStream<any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
    }
    static func consume(
        _ outputs: AsyncStream<OutputEnvelope>, contracts: CommunicationContracts? = nil,
        dispatch: @escaping @Sendable (OutputEnvelope) async throws -> Void
    ) async throws {
        let transport = AssistantGenerationTransport(contracts: contracts, dispatch: dispatch)
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withThrowingTaskGroup(of: Void.self) { work in
                        if let signalDispatcher = transport.signalDispatcher {
                            work.addTask {
                                try await signalDispatcher.dispatch { envelope in
                                    if case .roundFinished(let round) = envelope.output {
                                        try await dispatch(envelope.replacingOutput(.roundBranchSealed(.action, round)))
                                        try await transport.seal(round, envelope: envelope)
                                    } else {
                                        try await dispatch(envelope)
                                    }
                                }
                            }
                        }
                        work.addTask {
                            try await IndependentOutputWorkflow.consumeDirectSignals(
                                transport.directSignals.stream, dispatch: dispatch)
                        }
                        work.addTask {
                            defer {
                                transport.signalDispatcher?.finish()
                                transport.directSignals.continuation.finish()
                            }
                            for await output in outputs {
                                try Task.checkCancellation()
                                try await transport.submit(output)
                            }
                            try Task.checkCancellation()
                        }
                        while try await work.next() != nil {}
                    }
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
        if let signalDispatcher {
            let channel: String?
            switch envelope.output {
            case .communication(let action):
                channel = contracts?[action.message.contract]?.channel
                if channel == nil {
                    try submitDirect(envelope)
                    return
                }
            case .actionControl:
                try submitDirect(envelope)
                return
            case .actionCall, .roundFinished, .control("assistant.finished"), .control("agent.finished"):
                channel = GatewayExecution.actionCallChannel
            case .rejectedCall(let rejection) where rejection.kind == .action:
                channel = GatewayExecution.actionCallChannel
            default:
                channel = nil
            }
            if let channel {
                if case .roundFinished(let round) = envelope.output {
                    guard toolSeals[round] == nil, toolSeals.count < 32 else { throw HarnessError.queueFull }
                    let pending = Array(tools[round, default: [:]].values)
                    toolSeals[round] = Task {
                        for task in pending { try await task.value }
                        try Task.checkCancellation()
                        try await dispatch(envelope.replacingOutput(.roundBranchSealed(.tool, round)))
                    }
                }
                try signalDispatcher.enqueue(envelope, channel: channel)
                return
            }
        }
        let isTool: Bool
        switch envelope.output {
        case .toolCall: isTool = true
        case .rejectedCall(let rejection): isTool = rejection.kind == .tool
        default: isTool = false
        }
        let dispatch = dispatch
        if isTool, let round = envelope.roundID {
            guard tools.values.reduce(0, { $0 + $1.count }) < 128 else { throw HarnessError.queueFull }
            let task = try await toolRequests.submit {
                try await dispatch(envelope)
            }
            tools[round, default: [:]][UUID().uuidString] = task
        } else if case .roundFinished(let round) = envelope.output {
            try seal(round, envelope: envelope)
        } else {
            try await dispatch(envelope)
        }
    }
    private func submitDirect(_ envelope: OutputEnvelope) throws {
        guard case .enqueued = directSignals.continuation.yield(envelope) else { throw HarnessError.queueFull }
    }

    private func seal(_ round: String, envelope: OutputEnvelope) throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard seals[round] == nil, seals.count < 32 else { throw HarnessError.queueFull }
        let pending = toolSeals[round].map { [$0] } ?? Array(tools[round, default: [:]].values)
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
            self.toolSeals[round] = nil
            self.tools[round] = nil
            self.seals[round] = nil
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
        let pending = Array(seals.values) + Array(toolSeals.values) + tools.values.flatMap { Array($0.values) }
        for task in pending { task.cancel() }
        for task in pending { _ = await task.result }
        toolSeals.removeAll()
        seals.removeAll()
        tools.removeAll()
        failureContinuation.finish()
    }
}

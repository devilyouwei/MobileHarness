import AgentCore
import Foundation
import FunctionContracts
import Gateway

/// One output reader admits calls; a round joins only its own tools and effects.
actor AssistantGenerationTransport {
    private let signalDispatcher: SignalChannelDispatcher<OutputEnvelope>?
    private let publicationChannels: [String: String]?
    private let dispatch: @Sendable (OutputEnvelope) async throws -> Void
    private nonisolated let failures: AsyncStream<any Error>
    private let failureContinuation: AsyncStream<any Error>.Continuation
    private var tools: [String: [String: Task<Void, Error>]] = [:]
    private var independentTools: [String: Task<Void, Error>] = [:]
    private var toolSeals: [String: Task<Void, Error>] = [:]
    private var seals: [String: Task<Void, Error>] = [:]
    private var volumeTail: (id: String, task: Task<Void, Error>)?
    private var activeToolCount = 0
    private nonisolated let directSignals = AsyncStream<OutputEnvelope>.makeStream(
        bufferingPolicy: .bufferingOldest(128))
    private var closed = false
    private var failure: (any Error)?
    init(publicationChannels: [String: String]?, dispatch: @escaping @Sendable (OutputEnvelope) async throws -> Void) {
        self.publicationChannels = publicationChannels
        if let publicationChannels {
            let channels = Array(publicationChannels.values) + [ActionCallSignal.channel]
            signalDispatcher = SignalChannelDispatcher(
                channels: Set(channels), capacities: [ActionCallSignal.channel: 256])
        } else {
            signalDispatcher = nil
        }
        self.dispatch = dispatch
        (failures, failureContinuation) = AsyncStream<any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
    }
    static func consume(
        _ outputs: AsyncStream<OutputEnvelope>, publicationChannels: [String: String]? = nil,
        dispatch: @escaping @Sendable (OutputEnvelope) async throws -> Void
    ) async throws {
        let transport = AssistantGenerationTransport(publicationChannels: publicationChannels, dispatch: dispatch)
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
                channel = publicationChannels?[action.message.contract]
                if channel == nil {
                    try submitDirect(envelope)
                    return
                }
            case .actionControl:
                try submitDirect(envelope)
                return
            case .actionCall, .roundFinished, .control("assistant.finished"), .control("agent.finished"):
                channel = ActionCallSignal.channel
            case .rejectedCall(let rejection) where rejection.kind == .action:
                channel = ActionCallSignal.channel
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
        if isTool {
            let id = UUID().uuidString
            let round = envelope.roundID
            guard activeToolCount < 128 else { throw HarnessError.queueFull }
            if round != nil, tools.values.reduce(0, { $0 + $1.count }) >= 128 {
                throw HarnessError.queueFull
            }
            let setsVolume: Bool
            if case .toolCall(let call) = envelope.output {
                setsVolume = call.toolPath == AssistantAgent.playbackVolume.path
            } else {
                setsVolume = false
            }
            let precedingVolume = setsVolume ? volumeTail?.task : nil
            activeToolCount += 1
            let task = Task {
                defer {
                    if volumeTail?.id == id { volumeTail = nil }
                    activeToolCount -= 1
                    if round == nil { independentTools[id] = nil }
                }
                do {
                    if let precedingVolume { _ = await precedingVolume.result }
                    try Task.checkCancellation()
                    try await dispatch(envelope)
                } catch {
                    if round == nil, !closed || !(error is CancellationError) {
                        failure = error
                        failureContinuation.yield(error)
                    }
                    throw error
                }
            }
            if setsVolume { volumeTail = (id, task) }
            if let round {
                tools[round, default: [:]][id] = task
            } else {
                independentTools[id] = task
            }
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
        for task in Array(independentTools.values) { try await task.value }
        if let failure { throw failure }
    }
    private func cancel() async {
        closed = true
        let pending =
            Array(seals.values) + Array(toolSeals.values) + tools.values.flatMap { Array($0.values) }
            + Array(independentTools.values)
        for task in pending { task.cancel() }
        for task in pending { _ = await task.result }
        toolSeals.removeAll()
        seals.removeAll()
        tools.removeAll()
        independentTools.removeAll()
        failureContinuation.finish()
    }
}

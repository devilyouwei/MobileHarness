import AgentCore
import Foundation

/// Consume an optional subscriber independently; failures are reported, never silently discarded.
public enum IndependentOutputWorkflow {
    /// Independent protocol consumers; only a round/input boundary joins both branches.
    public static func consumeGeneration(
        _ outputs: AsyncStream<OutputEnvelope>,
        dispatch: @escaping @Sendable (OutputEnvelope) async throws -> Void
    ) async throws {
        let reader = OutputStreamReader(outputs)
        while true {
            let tools = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(128))
            let communications = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(16))
            let actions = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(256))
            let boundary = try await withThrowingTaskGroup(
                of: BranchCompletion.self, returning: OutputEnvelope?.self
            ) { group in
                group.addTask {
                    try await consumeTools(tools.stream, dispatch: dispatch)
                    return .drained
                }
                group.addTask {
                    try await consumeTools(communications.stream, dispatch: dispatch)
                    return .drained
                }
                group.addTask {
                    for await envelope in actions.stream {
                        try Task.checkCancellation()
                        try await dispatch(envelope)
                    }
                    try Task.checkCancellation()
                    return .drained
                }
                group.addTask {
                    let boundary = try await reader.routeRound(
                        tools: tools.continuation, actions: actions.continuation,
                        communications: communications.continuation)
                    return .boundary(boundary)
                }
                defer {
                    group.cancelAll()
                    communications.continuation.finish()
                    tools.continuation.finish()
                    actions.continuation.finish()
                }
                var boundary: OutputEnvelope?
                var cancelling = false
                while !group.isEmpty {
                    do {
                        guard let completion = try await group.next() else { break }
                        if case .boundary(let envelope) = completion {
                            boundary = envelope
                            cancelling = envelope.map { isFailure($0.output) } ?? true
                            if cancelling { group.cancelAll() }
                            communications.continuation.finish()
                            tools.continuation.finish()
                            actions.continuation.finish()
                        }
                    } catch is CancellationError {
                        if !cancelling { throw CancellationError() }
                    }
                }
                try Task.checkCancellation()
                return boundary
            }
            guard let boundary else { return }
            try await dispatch(boundary)
        }
    }

    private enum BranchCompletion: Sendable {
        case drained
        case boundary(OutputEnvelope?)
    }

    fileprivate static func isFailure(_ output: AgentOutput) -> Bool {
        guard case .control(let value) = output else { return false }
        return value == "agent.cancelled" || value.hasPrefix("assistant.error:") || value.hasPrefix("agent.error:")
    }

    private enum ToolCompletion: Sendable {
        case next(OutputEnvelope?)
        case executed
    }

    private static func consumeTools(
        _ outputs: AsyncStream<OutputEnvelope>,
        dispatch: @escaping @Sendable (OutputEnvelope) async throws -> Void
    ) async throws {
        let reader = OutputStreamReader(outputs)
        try await withThrowingTaskGroup(of: ToolCompletion.self) { group in
            var active = 0
            var reading = true
            var closed = false
            group.addTask { .next(try await reader.next()) }
            defer { group.cancelAll() }
            while let completion = try await group.next() {
                switch completion {
                case .next(let envelope):
                    reading = false
                    if let envelope {
                        active += 1
                        group.addTask {
                            try Task.checkCancellation()
                            try await dispatch(envelope)
                            return .executed
                        }
                    } else {
                        closed = true
                    }
                case .executed:
                    active -= 1
                }
                if !closed, !reading, active < 4 {
                    reading = true
                    group.addTask { .next(try await reader.next()) }
                }
            }
            try Task.checkCancellation()
        }
    }

    /// Streaming/deterministic producers have independent communication delivery and ordered function output.
    public static func consumeSignals(
        _ outputs: AsyncStream<OutputEnvelope>,
        dispatch: @escaping @Sendable (OutputEnvelope) async throws -> Void
    ) async throws {
        let actions = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let communications = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(16))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await consumeTools(communications.stream, dispatch: dispatch) }
            group.addTask {
                for await envelope in actions.stream {
                    try Task.checkCancellation()
                    try await dispatch(envelope)
                }
            }
            group.addTask {
                for await envelope in outputs {
                    try Task.checkCancellation()
                    let destination: AsyncStream<OutputEnvelope>.Continuation
                    if case .communication = envelope.output {
                        destination = communications.continuation
                    } else {
                        destination = actions.continuation
                    }
                    guard case .enqueued = destination.yield(envelope) else { throw HarnessError.queueFull }
                }
                communications.continuation.finish()
                actions.continuation.finish()
            }
            defer {
                group.cancelAll()
                communications.continuation.finish()
                actions.continuation.finish()
            }
            try await group.waitForAll()
            try Task.checkCancellation()
        }
    }

    public static func consume(
        _ outputs: AsyncStream<OutputEnvelope>,
        dispatch: @escaping @Sendable (OutputEnvelope) async throws -> Void,
        rejected: @escaping @Sendable (OutputEnvelope, any Error) async -> Void
    ) async throws {
        for await envelope in outputs {
            try Task.checkCancellation()
            do {
                try await dispatch(envelope)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await rejected(envelope, error)
            }
        }
        try Task.checkCancellation()
    }
}

/// One transport reader only demultiplexes; protocol consumers never wait on each other's slots.
private actor OutputStreamReader {
    private var iterator: AsyncStream<OutputEnvelope>.Iterator?
    private var inputID: String?

    init(_ outputs: AsyncStream<OutputEnvelope>) { iterator = outputs.makeAsyncIterator() }

    func next() async throws -> OutputEnvelope? {
        guard var iterator = self.iterator else { throw HarnessError.invalidTransition }
        self.iterator = nil
        defer { self.iterator = iterator }
        let envelope = await iterator.next(isolation: self)
        try Task.checkCancellation()
        return envelope
    }

    func routeRound(
        tools: AsyncStream<OutputEnvelope>.Continuation,
        actions: AsyncStream<OutputEnvelope>.Continuation,
        communications: AsyncStream<OutputEnvelope>.Continuation
    ) async throws -> OutputEnvelope? {
        while let envelope = try await next() {
            try Task.checkCancellation()
            if envelope.roundID != nil {
                if let inputID {
                    guard inputID == envelope.inputID else { throw HarnessError.invalidTransition }
                } else {
                    inputID = envelope.inputID
                }
            }
            let terminal: Bool
            if case .control(let value) = envelope.output {
                terminal =
                    IndependentOutputWorkflow.isFailure(envelope.output)
                    || value == "assistant.finished" || value == "agent.finished"
            } else {
                terminal = false
            }
            if terminal, inputID == nil || inputID == envelope.inputID {
                inputID = nil
                return envelope
            }
            if case .roundFinished = envelope.output {
                inputID = nil
                return envelope
            }
            let native: Bool
            switch envelope.output {
            case .toolCall: native = envelope.roundID != nil
            case .rejectedCall(let rejection): native = rejection.kind == .tool && envelope.roundID != nil
            default: native = false
            }
            let destination: AsyncStream<OutputEnvelope>.Continuation
            if case .communication = envelope.output {
                destination = communications
            } else {
                destination = native ? tools : actions
            }
            switch destination.yield(envelope) {
            case .enqueued: break
            case .dropped, .terminated: throw HarnessError.queueFull
            @unknown default: throw HarnessError.queueFull
            }
        }
        try Task.checkCancellation()
        return nil
    }
}

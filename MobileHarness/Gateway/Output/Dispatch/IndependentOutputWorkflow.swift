import AgentCore
import Foundation
import OSLog

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

    public struct QueueFailure: Error, Sendable, CustomStringConvertible {
        public let queue: String
        public let capacity: Int
        public let source: String
        public let sessionID: String
        public let sequence: UInt64
        public let output: String
        public let reason: String
        init(queue: String, capacity: Int, envelope: OutputEnvelope, reason: String) {
            self.queue = queue
            self.capacity = capacity
            source = envelope.source.rawValue
            sessionID = envelope.sessionID
            sequence = envelope.sequence
            self.reason = reason
            switch envelope.output {
            case .toolCall(let call): output = call.toolPath
            case .communication(let action): output = action.message.contract
            case .actionCall(let action): output = action.actionPath.description
            default: output = "control"
            }
        }
        public var description: String {
            "queueFull(queue=\(queue), capacity=\(capacity), source=\(source), session=\(sessionID), sequence=\(sequence), output=\(output), reason=\(reason))"
        }
    }

    /// Latest-state policy comes from the producer; discrete commands retain FIFO admission.
    public static func consumeSignals(
        _ outputs: AsyncStream<OutputEnvelope>,
        replacementKey: @escaping @Sendable (OutputEnvelope) -> String? = { _ in nil },
        onMediaExpired: @escaping @Sendable (OutputEnvelope) async -> Void = { _ in },
        dispatch: @escaping @Sendable (OutputEnvelope) async throws -> Void
    ) async throws {
        let media = AgentOutputMailbox(capacity: 1)
        let latestTools = AgentOutputMailbox(capacity: 16)
        let latestCommunications = AgentOutputMailbox(capacity: 16)
        let actions = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let communications = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(16))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await consumeTools(communications.stream, dispatch: dispatch) }
            group.addTask {
                for await envelope in latestCommunications.stream {
                    try Task.checkCancellation()
                    if envelope.inputMetadata.expired { continue }
                    try await dispatch(envelope)
                }
            }
            group.addTask {
                for await envelope in latestTools.stream {
                    try Task.checkCancellation()
                    if envelope.inputMetadata.expired { continue }
                    try await dispatch(envelope)
                }
            }
            group.addTask {
                for await envelope in media.stream {
                    try Task.checkCancellation()
                    if expiredMedia(envelope) {
                        recordExpiredMedia(envelope)
                        await onMediaExpired(envelope)
                        continue
                    }
                    do {
                        try await dispatch(envelope)
                    } catch CommunicationError.expired where expiredMedia(envelope) {
                        recordExpiredMedia(envelope)
                        await onMediaExpired(envelope)
                    }
                }
            }
            group.addTask {
                for await envelope in actions.stream {
                    try Task.checkCancellation()
                    try await dispatch(envelope)
                }
            }
            group.addTask {
                for await envelope in outputs {
                    try Task.checkCancellation()
                    let key = try scopedStateKey(replacementKey(envelope), envelope: envelope)
                    if envelope.media != nil {
                        try admitState(envelope, key: "media", mailbox: media, queue: "media", capacity: 1)
                    } else if let key {
                        if case .communication = envelope.output {
                            try admitState(
                                envelope, key: key, mailbox: latestCommunications,
                                queue: "latestCommunications", capacity: 16)
                        } else {
                            try admitState(envelope, key: key, mailbox: latestTools, queue: "latestTools", capacity: 16)
                        }
                    } else {
                        let communication: Bool
                        if case .communication = envelope.output { communication = true } else { communication = false }
                        let destination = communication ? communications.continuation : actions.continuation
                        switch destination.yield(envelope) {
                        case .enqueued: break
                        case .dropped:
                            throw QueueFailure(
                                queue: communication ? "communications" : "actions",
                                capacity: communication ? 16 : 256, envelope: envelope, reason: "full")
                        case .terminated:
                            try Task.checkCancellation()
                            throw QueueFailure(
                                queue: communication ? "communications" : "actions",
                                capacity: communication ? 16 : 256, envelope: envelope, reason: "closed")
                        @unknown default: throw HarnessError.queueFull
                        }
                    }
                }
                media.close(discardingState: false)
                latestTools.close(discardingState: false)
                latestCommunications.close(discardingState: false)
                communications.continuation.finish()
                actions.continuation.finish()
            }
            defer {
                group.cancelAll()
                media.close()
                latestTools.close()
                latestCommunications.close()
                communications.continuation.finish()
                actions.continuation.finish()
            }
            // React to the first failing branch, then join cancellation in the scope cleanup.
            while (try await group.next()) != nil {}
            try Task.checkCancellation()
        }
    }

    private static func scopedStateKey(_ key: String?, envelope: OutputEnvelope) throws -> String? {
        guard let key else { return nil }
        guard !key.isEmpty, key.utf8.count <= 64, envelope.roundID == nil else {
            throw CommunicationError.invalidPayload
        }
        switch envelope.output {
        case .toolCall: break
        case .communication(let action) where action.target == nil: break
        default: throw CommunicationError.invalidPayload
        }
        return "\(envelope.source.rawValue)|\(envelope.sessionID)|\(envelope.taskScope?.id ?? "")|\(key)"
    }
    private static func admitState(
        _ envelope: OutputEnvelope, key: String, mailbox: AgentOutputMailbox,
        queue: String, capacity: Int
    ) throws {
        do { try mailbox.admit(envelope, replacing: key) } catch {
            try Task.checkCancellation()
            throw QueueFailure(
                queue: queue, capacity: capacity, envelope: envelope,
                reason: error as? CommunicationError == .capacityExceeded ? "full" : "closed")
        }
    }

    private static func expiredMedia(_ envelope: OutputEnvelope) -> Bool {
        guard let image = envelope.media else { return false }
        if envelope.inputMetadata.expired { return true }
        guard let capturedAt = image.capturedAt else { return false }
        return capturedAt.duration(to: .now) >= .milliseconds(750)
    }
    private static func recordExpiredMedia(_ envelope: OutputEnvelope) {
        Logger(subsystem: "dev.mobileharness", category: "SignalMedia")
            .notice("Rejected expired media output; sequence=\(envelope.sequence, privacy: .public)")
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

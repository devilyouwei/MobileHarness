import AgentCore
import Foundation
import ModelKit

/// Capability adaptation only. The owning Agent supplies parsing, evidence and business outputs.
public enum AgentChatDriver {
    public struct Consumers: Sendable {
        public let recording: @Sendable (AgentModelRequestRecording.Snapshot) async throws -> Void
        public let timing: @Sendable (ChatTiming.Snapshot) async throws -> Void
        public let text: @Sendable (AsyncThrowingStream<String, any Error>) async throws -> String
        public let native: @Sendable (AsyncThrowingStream<ChatToolCall, any Error>) async throws -> Void
        public let evidence: @Sendable (ChatEvent) async throws -> Void
        public init(
            text: @escaping @Sendable (AsyncThrowingStream<String, any Error>) async throws -> String,
            native: @escaping @Sendable (AsyncThrowingStream<ChatToolCall, any Error>) async throws -> Void,
            evidence: @escaping @Sendable (ChatEvent) async throws -> Void,
            recording: @escaping @Sendable (AgentModelRequestRecording.Snapshot) async throws -> Void = { _ in },
            timing: @escaping @Sendable (ChatTiming.Snapshot) async throws -> Void = { _ in }
        ) {
            self.recording = recording
            self.timing = timing
            self.text = text
            self.native = native
            self.evidence = evidence
        }
    }
    public static func collect(_ request: ChatRequest, using capability: any ChatCapability, consumers: Consumers)
        async throws -> String
    {
        var measured = request
        let timing = ChatTiming()
        measured.timing = timing
        let audit = try AgentModelRequestRecording(measured)
        do {
            let session = try await capability.chat(measured)
            defer { session.cancel() }
            let text = AsyncThrowingStream<String, any Error>.makeStream(bufferingPolicy: .bufferingOldest(8192))
            let native = AsyncThrowingStream<ChatToolCall, any Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
            let answer = try await session.withCleanup {
                return try await withTaskCancellationHandler {
                    try await withThrowingTaskGroup(of: String.self) { group in
                        group.addTask { try await consumers.text(text.stream) }
                        group.addTask {
                            try await consumers.native(native.stream)
                            return ""
                        }
                        group.addTask {
                            var finished = false
                            var recordedTiming = false
                            var bytes = 0
                            var fragments = 0
                            for try await event in session.events {
                                audit.record(event)
                                try Task.checkCancellation()
                                guard !finished else {
                                    throw CapabilityError.invalidRequest("Events after chat completion")
                                }
                                if !recordedTiming, let snapshot = timing.snapshot {
                                    let terminal: Bool
                                    if case .finished = event { terminal = true } else { terminal = false }
                                    if snapshot.firstTokenAt != nil || terminal {
                                        try await consumers.timing(snapshot)
                                        recordedTiming = true
                                    }
                                }
                                try await consumers.evidence(event)
                                switch event {
                                case .text(let delta):
                                    bytes += delta.utf8.count
                                    fragments += 1
                                    guard bytes <= 65_536, fragments <= 8192 else {
                                        throw GenerationError.limitExceeded
                                    }
                                    guard case .enqueued = text.continuation.yield(delta) else {
                                        throw GenerationError.limitExceeded
                                    }
                                case .toolCall(let call):
                                    guard case .enqueued = native.continuation.yield(call) else {
                                        throw GenerationError.limitExceeded
                                    }
                                case .usage: break
                                case .finished: finished = true
                                }
                            }
                            guard finished else {
                                throw CapabilityError.unavailable("Chat returned no completed answer")
                            }
                            text.continuation.finish()
                            native.continuation.finish()
                            return ""
                        }
                        defer {
                            group.cancelAll()
                            session.cancel()
                            text.continuation.finish(throwing: CancellationError())
                            native.continuation.finish(throwing: CancellationError())
                        }
                        var answer = ""
                        for try await value in group where !value.isEmpty { answer = value }
                        return answer
                    }
                } onCancel: {
                    session.cancel()
                    text.continuation.finish(throwing: CancellationError())
                    native.continuation.finish(throwing: CancellationError())
                }
            }
            try await consumers.recording(try audit.snapshot())
            return answer
        } catch {
            let primary = error
            do { try await Task { try await consumers.recording(try audit.snapshot()) }.value } catch {
                throw ChatEvidenceFailure(primary: primary, persistence: error)
            }
            throw primary
        }
    }
}

private struct ChatEvidenceFailure: Error {
    let primary: any Error
    let persistence: any Error
}

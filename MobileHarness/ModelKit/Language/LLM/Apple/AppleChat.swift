import Foundation
import FoundationModels
import ModelKit

/// System-managed on-device inference; consumers retain only the neutral ChatCapability.
@available(iOS 27, macOS 27, *)
public actor AppleChat: ChatCapability {
    private let resource: ModelResource<Void>

    public init(context: ModelContext) throws {
        resource = try context.resource { () }
    }

    public var availability: CapabilityAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: .available
        case .unavailable(let reason): .unavailable(reason: "Apple system language model unavailable: \(reason)")
        }
    }

    public func chat(_ request: ChatRequest) async throws -> InferenceSession<ChatEvent> {
        let prepared = try AppleChatInput(request)
        try Task.checkCancellation()
        if case .unavailable(let reason) = availability { throw CapabilityError.unavailable(reason) }
        let lease = try await resource.acquire()
        do {
            let control = InferenceTaskControl()
            let pair = InferenceSession<ChatEvent>.make(
                context: request.context, limits: try StreamLimits(capacity: 128, maximumEventBytes: 4128),
                estimatedBytes: { $0.estimatedBytes },
                onTermination: { reason in
                    if case .finished = reason { return }
                    control.cancel()
                }, waitForCompletion: { await control.waitForCompletion() })
            let resource = resource
            let emitter = pair.emitter
            let task = Task {
                defer { control.finish() }
                do {
                    let reason = try await AppleChatEngine.generate(prepared, request: request, emitter: emitter)
                    try Task.checkCancellation()
                    await resource.release(lease.id)
                    try emitter.yield(.finished(reason))
                    emitter.finish()
                } catch {
                    await resource.release(lease.id)
                    emitter.fail(error)
                }
            }
            try control.install(task)
            await resource.setCancellation(lease.id) { [weak session = pair.session] in session?.cancel() }
            return pair.session
        } catch {
            await resource.release(lease.id)
            throw error
        }
    }
}

@available(iOS 27, macOS 27, *)
struct AppleChatInput: Sendable {
    let transcript: Transcript
    let prompt: String

    init(_ request: ChatRequest) throws {
        guard request.tools.isEmpty, request.toolChoice == .automatic,
            request.messages.allSatisfy({
                $0.role != .tool && $0.toolCalls.isEmpty && ($0.images?.isEmpty ?? true)
            })
        else { throw CapabilityError.invalidRequest("Apple chat does not support tools, tool history or images") }
        guard let current = request.messages.last, current.role == .user,
            !current.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw CapabilityError.invalidRequest("Apple chat requires a nonempty final user message") }
        var entries: [Transcript.Entry] = []
        var instructions: [Transcript.Segment] = []
        var conversationStarted = false
        for message in request.messages.dropLast() {
            let segment = Transcript.Segment.text(.init(content: message.content))
            switch message.role {
            case .system:
                guard !conversationStarted else {
                    throw CapabilityError.invalidRequest(
                        "Apple chat requires system messages before conversation history")
                }
                instructions.append(segment)
            case .user:
                conversationStarted = true
                entries.append(.prompt(.init(segments: [segment])))
            case .assistant:
                guard conversationStarted else {
                    throw CapabilityError.invalidRequest("Apple chat history must begin with user input")
                }
                entries.append(.response(.init(assetIDs: [], segments: [segment])))
            case .tool:
                throw CapabilityError.invalidRequest("Apple chat does not support tool history")
            }
        }
        if !instructions.isEmpty {
            entries.insert(.instructions(.init(segments: instructions, toolDefinitions: [])), at: 0)
        }
        transcript = Transcript(entries: entries)
        prompt = current.content
    }
}

/// Native snapshots are cumulative. Never silently rewrite text already delivered to consumers.
struct AppleChatText {
    private(set) var text = ""
    static let maximumBytes = 262_144

    mutating func append(_ snapshot: String) throws -> [String] {
        guard snapshot.utf8.count <= Self.maximumBytes else {
            throw CapabilityError.invalidRequest("Apple chat output exceeds 256 KiB")
        }
        guard snapshot.unicodeScalars.starts(with: text.unicodeScalars) else {
            throw CapabilityError.invalidRequest("Apple chat revised previously emitted text")
        }
        let suffix = snapshot.unicodeScalars.dropFirst(text.unicodeScalars.count)
        var chunks: [String] = []
        var chunk = String.UnicodeScalarView()
        for scalar in suffix {
            chunk.append(scalar)
            if chunk.count == 1024 {
                chunks.append(String(chunk))
                chunk = String.UnicodeScalarView()
            }
        }
        if !chunk.isEmpty { chunks.append(String(chunk)) }
        text = snapshot
        return chunks
    }
}

@available(iOS 27, macOS 27, *)
@MainActor
private enum AppleChatEngine {
    static func generate(
        _ input: AppleChatInput, request: ChatRequest, emitter: InferenceEmitter<ChatEvent>
    ) async throws -> ChatEvent.FinishReason {
        try Task.checkCancellation()
        let session = LanguageModelSession(model: SystemLanguageModel.default, transcript: input.transcript)
        do {
            try await request.onDispatch?()
            try Task.checkCancellation()
            request.timing?.start()
            let options = GenerationOptions(
                temperature: request.temperature, maximumResponseTokens: request.maximumOutputTokens)
            var text = AppleChatText()
            for try await snapshot in session.streamResponse(to: input.prompt, options: options) {
                try Task.checkCancellation()
                for delta in try text.append(snapshot.content) {
                    request.timing?.recordText(delta)
                    try emitter.yield(.text(delta))
                }
            }
        } catch {
            // Stream cancellation may precede native retirement. Do not release admission early.
            await waitUntilIdle(session)
            throw error
        }
        await waitUntilIdle(session)
        try Task.checkCancellation()
        let usage = session.usage
        let inputTokens = usage.input.totalTokenCount
        let outputTokens = usage.output.totalTokenCount
        let (total, overflow) = inputTokens.addingReportingOverflow(outputTokens)
        guard !overflow else { throw CapabilityError.invalidRequest("Apple chat token usage overflow") }
        try emitter.yield(
            .usage(
                try ChatTokenUsage(
                    input: inputTokens, generated: outputTokens, total: total,
                    cachedInput: usage.input.cachedTokenCount)))
        // The high-level stream has no EOS reason; conservatively mark an exhausted explicit budget.
        return request.maximumOutputTokens.map { outputTokens >= $0 } == true ? .lengthLimit : .stop
    }

    private static func waitUntilIdle(_ session: LanguageModelSession) async {
        // An unstructured cleanup task is not cancelled with the generation worker.
        await Task { @MainActor in
            while session.isResponding { try? await Task.sleep(for: .milliseconds(10)) }
        }.value
    }
}

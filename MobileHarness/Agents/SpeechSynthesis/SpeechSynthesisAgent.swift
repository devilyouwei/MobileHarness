import AgentCore
import Foundation
import ModelKit
import StorageAudio

/// Shared directed synthesis service. One FIFO worker, independent of playback Channels.
public actor SpeechSynthesisAgent: Agent {
    public nonisolated let descriptor: AgentDescriptor
    public nonisolated let outputs: AsyncStream<OutputEnvelope>
    private let continuation: AsyncStream<OutputEnvelope>.Continuation
    private let synthesis: any SpeechSynthesisCapability
    private let store: SpeechAudioStore
    private let executionTimeout: Duration
    private var lifecycle: AgentLifecycle = .registered
    private var queue: [(SpeechSynthesisInput, AgentInput)] = []
    private var admitting = 0
    private var worker: Task<Void, Never>?
    private var active: UUID?
    private var processed = 0
    public init(
        synthesis: any SpeechSynthesisCapability, store: SpeechAudioStore,
        executionTimeout: Duration = .seconds(60), configuration: AgentConfiguration? = nil
    ) throws {
        precondition(executionTimeout > .zero)
        let config = try configuration ?? AgentConfigurations.load(named: "SpeechSynthesis")
        guard config.agentID.rawValue == "speechSynthesis" else { throw AgentConfigurationError.identityMismatch }
        descriptor = AgentDescriptor(
            id: config.agentID, name: "Speech Synthesis",
            inputs: Set(config.communication.inputs.map(\.kind)), outputs: [], capabilities: config.capabilities)
        self.synthesis = synthesis
        self.store = store
        self.executionTimeout = executionTimeout
        let stream = AsyncStream<OutputEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(1))
        outputs = stream.stream
        continuation = stream.continuation
    }
    public func start() throws {
        guard lifecycle == .registered else { throw HarnessError.invalidTransition }
        lifecycle = .running
    }
    public func pause() throws {
        guard lifecycle == .running else { throw HarnessError.invalidTransition }
        lifecycle = .paused
    }
    public func resume() throws {
        guard lifecycle == .paused else { throw HarnessError.invalidTransition }
        lifecycle = .running
        drain()
    }
    public func status() -> AgentStatus {
        AgentStatus(lifecycle: lifecycle, queuedInputs: queue.count, processedInputs: processed)
    }
    public func receive(_ input: AgentInput) async throws {
        guard lifecycle == .running || lifecycle == .paused else { throw HarnessError.notRunning }
        guard !input.metadata.expired else { throw CommunicationError.expired }
        let owner = SpeechAudioStore.Owner(
            source: AgentID(rawValue: input.metadata.source),
            session: input.sessionID, input: input.metadata.parentID ?? input.id)
        if case .observation(.cancelSpeech(let id)) = input.payload {
            try await store.cancel(id, owner: owner)
            return
        }
        guard case .observation(.speechSynthesis(let request)) = input.payload else {
            throw HarnessError.unsupportedInput
        }
        try request.validate()
        guard queue.count + admitting < 32 else { throw HarnessError.queueFull }
        admitting += 1
        defer { admitting -= 1 }
        try await store.register(request.audioID, owner: owner) { [weak self] in
            await self?.cancelJob(request.audioID)
        }
        guard !Task.isCancelled, lifecycle == .running || lifecycle == .paused else {
            await store.fail(request.audioID, error: CancellationError())
            throw CancellationError()
        }
        queue.append((request, input))
        drain()
    }
    private func cancelJob(_ id: UUID) {
        queue.removeAll { $0.0.audioID == id }
        if active == id { worker?.cancel() }
    }
    public func stop() async {
        lifecycle = .stopped
        let ids = queue.map { $0.0.audioID } + (active.map { [$0] } ?? [])
        queue.removeAll()
        let pending = worker
        pending?.cancel()
        for id in ids { await store.fail(id, error: CancellationError()) }
        await pending?.value
        continuation.finish()
    }
    private func drain() {
        guard lifecycle == .running, worker == nil, !queue.isEmpty else { return }
        let (request, input) = queue.removeFirst()
        active = request.audioID
        worker = Task { await produce(request, input: input) }
    }
    private func produce(_ request: SpeechSynthesisInput, input: AgentInput) async {
        defer {
            worker = nil
            active = nil
            processed += 1
            drain()
        }
        let deadline = Task {
            do { try await Task.sleep(for: executionTimeout) } catch { return }
            await store.fail(request.audioID, error: SpeechAudioError.synthesisTimedOut)
        }
        defer { deadline.cancel() }
        do {
            let audio = try await store.begin(request.audioID)
            try Task.checkCancellation()
            let context = InferenceContext(requestID: request.audioID, conversationID: input.sessionID)
            let session = try await synthesis.synthesize(
                SpeechSynthesisRequest(text: request.text, locale: request.locale, context: context))
            defer { session.cancel() }
            guard session.context == context else { throw SpeechAudioError.invalidAudio }
            var finished = false
            var bytes = 0
            var format: AudioFormat?
            var sequence: UInt64?
            try await withTaskCancellationHandler {
                for try await event in session.events {
                    try Task.checkCancellation()
                    guard !finished else { throw SpeechAudioError.invalidAudio }
                    switch event {
                    case .audio(let frame):
                        guard frame.format.channels == 1, frame.format.encoding == .float32,
                            format == nil || format == frame.format,
                            sequence.map({ frame.sequence > $0 }) ?? true,
                            frame.data.count <= 8_388_608 - bytes
                        else { throw SpeechAudioError.invalidAudio }
                        format = frame.format
                        sequence = frame.sequence
                        bytes += frame.data.count
                        try await audio.append(frame)
                    case .finished: finished = true
                    }
                }
            } onCancel: {
                session.cancel()
            }
            guard finished, bytes > 0 else { throw SpeechAudioError.invalidAudio }
            await store.complete(request.audioID)
        } catch { await store.fail(request.audioID, error: error) }
    }
}
